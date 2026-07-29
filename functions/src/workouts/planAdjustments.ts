import { randomUUID } from "node:crypto";
import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { z } from "zod";
import {
  CoachMemoryFact,
  PlanAdjustmentCategory,
  PlanAdjustmentProposal,
  PlanAdjustmentScope,
  PlannedExercise,
  PlannedWorkoutDay,
  RiskLevel,
} from "../contracts/coach-agent.js";
import { retrieveResearchCorpus } from "../corpus/researchCorpus.js";
import { safeLogger } from "../logging/safeLogger.js";
import {
  coachFollowUpPath,
  coachFollowUpsCollectionPath,
  memoryFactPath,
  planAdjustmentProposalPath,
  planAdjustmentProposalsCollectionPath,
  profilePath,
  trainingProgramPath,
  workoutPlanPath,
} from "../paths.js";
import { ensureTrainingProgram, parseTrainingProgramDocument, type TrainingProgramType } from "./program.js";

export const AcceptPlanAdjustmentProposalRequest = z.object({
  proposalId: z.string().min(1),
  decidedAt: z.string().datetime().optional(),
  // Chosen at accept time by the iOS proposal card (or, for an LLM-driven
  // proposal, may already be set on the proposal itself — see
  // `appliesTo.scope`). Falls back to the proposal's own scope, then to
  // the pre-scope legacy behavior when neither is set.
  scope: PlanAdjustmentScope.optional(),
  // The client's local calendar date (YYYY-MM-DD). "Today" for a user in
  // Tokyo and "today" on a server pinned to America/New_York disagree for
  // hours every day — a today-scope override keyed to the wrong date is
  // invisible to the user who just accepted it. When present this wins;
  // the ET server date is only the fallback for older clients.
  clientDate: z.string().date().optional(),
});

const WorkoutPlanAdjustmentStructuredAnswer = z
  .object({
    kind: z.literal("workout_plan_adjustment"),
    dayKey: z.string().min(1).optional(),
    exerciseName: z.string().min(1).optional(),
  })
  .passthrough();

type AdjustmentCategory = z.infer<typeof PlanAdjustmentCategory>;
type AdjustmentRiskLevel = z.infer<typeof RiskLevel>;
type AdjustmentScope = z.infer<typeof PlanAdjustmentScope>;
type PlannedWorkoutDayType = z.infer<typeof PlannedWorkoutDay>;
type PlannedExerciseType = z.infer<typeof PlannedExercise>;
type ProposedPlanPatch = z.infer<typeof PlanAdjustmentProposal>["proposedPlanPatch"];

export async function maybeCreatePlanAdjustmentProposal(input: {
  db: Firestore;
  userId: string;
  content: string;
  structuredAnswer?: unknown;
}) {
  const trimmed = input.content.trim();
  if (!trimmed) return null;

  const structured = WorkoutPlanAdjustmentStructuredAnswer.safeParse(input.structuredAnswer);
  const category = classifyPlanAdjustment(trimmed, structured.success);
  if (!category) return null;

  const riskLevel = riskForCategory(category, trimmed);
  let requiresFollowUp = needsFollowUp(category, riskLevel);
  const appliesTo = {
    planId: "current",
    ...resolveAppliesToDayKey(category, structured.success ? structured.data.dayKey : undefined),
    ...(structured.success && structured.data.exerciseName
      ? { exerciseName: structured.data.exerciseName }
      : {}),
  };

  // Categories that patch the plan automatically (requiresFollowUp === false)
  // need the target day's real exercises to build a concrete patch — a
  // keyword classifier alone can't invent exercise names. Loaded once here
  // so patchForCategory can stay a pure function of its inputs.
  let targetDay: PlannedWorkoutDayType | undefined;
  if (!requiresFollowUp && appliesTo.dayKey) {
    targetDay = await loadPlanDay(input.db, input.userId, appliesTo.dayKey);
    if (category === "time_limit" && (targetDay?.exercises.length ?? 0) < 2) {
      // Not enough exercises to safely trim automatically — fall back to
      // asking rather than emitting a patch with nothing real to cut.
      requiresFollowUp = true;
    }
  }

  return persistPlanAdjustmentProposal({
    db: input.db,
    userId: input.userId,
    source: structured.success ? "workout_detail" : "coach_chat",
    category,
    riskLevel,
    requiresFollowUp,
    originalUserText: trimmed,
    appliesTo,
    targetDay,
    structuredAnswer: structured.success ? structured.data : undefined,
  });
}

// The LLM tool-calling path (functions/src/coach/toolRegistry.ts) funnels
// through here rather than duplicating proposal construction — same
// collection, same risk/follow-up rules, same patch builder as the
// deterministic keyword classifier above. `reason` (a fixed enum the model
// fills in) maps onto the same PlanAdjustmentCategory taxonomy so both
// paths share summaries, rationale, and safety notes.
const ADAPT_PLAN_REASON_TO_CATEGORY: Record<
  | "too_hard"
  | "too_easy"
  | "pain_or_discomfort"
  | "time_constraint"
  | "equipment_unavailable"
  | "schedule_change"
  | "missed_session"
  | "returning_from_layoff",
  AdjustmentCategory
> = {
  too_hard: "other",
  too_easy: "other",
  pain_or_discomfort: "injury_pain",
  time_constraint: "time_limit",
  equipment_unavailable: "equipment_limit",
  schedule_change: "skip_or_reschedule",
  missed_session: "skip_or_reschedule",
  // Deliberately NOT skip_or_reschedule: that category resolves to a single
  // target day (resolveAppliesToDayKey) and patches it to "Rest · Skipped",
  // which is the right answer for one missed session and the wrong answer
  // for a layoff. readiness_low carries the "reduce, don't cancel" meaning
  // a graded return needs.
  returning_from_layoff: "readiness_low",
};

export type ToolDayPatch = {
  dayKey: string;
  dayName: string;
  replacementExercises: { name: string; sets: number; reps: number; weight: number }[];
};

export type PainTriage = {
  redFlagsAsked: true;
  userReportsSevere: boolean;
  description: string;
};

export type ReentryRampWeekInput = { intensityPct: number; note: string };

// A re-entry ramp is only safe-by-construction if it actually ramps: every
// week at or below the user's own baseline, never stepping DOWN as it goes,
// and finishing at 100% so the plan genuinely returns to normal. A ramp that
// ends at 70% is a permanent downgrade wearing a temporary label — and
// because accept writes dated overrides that simply stop, the user would
// silently snap back to full load on an arbitrary date instead of arriving
// there. Rejected here rather than clamped: the model should re-author the
// ramp, not have the server invent the missing final week.
export function validateReentryRamp(
  rampWeeks: ReentryRampWeekInput[] | undefined,
): { ok: true } | { ok: false; error: string } {
  if (!rampWeeks?.length) return { ok: false, error: "ramp_weeks_missing" };
  if (rampWeeks.length < 2) return { ok: false, error: "ramp_needs_at_least_two_weeks" };
  const last = rampWeeks[rampWeeks.length - 1];
  if (last.intensityPct !== 100) return { ok: false, error: "ramp_must_end_at_full_intensity" };
  for (let index = 1; index < rampWeeks.length; index += 1) {
    if (rampWeeks[index].intensityPct < rampWeeks[index - 1].intensityPct) {
      return { ok: false, error: "ramp_intensity_must_not_decrease" };
    }
  }
  // A ramp whose first week is already 100% writes nothing at all — an
  // accept that changes nothing while reporting success is the exact
  // failure mode computePatchedDay guards against for empty diff patches.
  if (rampWeeks[0].intensityPct === 100) {
    return { ok: false, error: "ramp_first_week_must_be_reduced" };
  }
  return { ok: true };
}

const INJURY_SAFETY_NOTES = [
  "Stop immediately if pain sharpens, radiates, or changes character.",
  "This is training guidance, not medical advice — see a clinician if pain persists or worsens.",
];

export async function createPlanAdjustmentProposalFromTool(input: {
  db: Firestore;
  userId: string;
  reason: keyof typeof ADAPT_PLAN_REASON_TO_CATEGORY;
  userNote?: string;
  dayKey?: string;
  exerciseName?: string;
  scope?: AdjustmentScope;
  dayPatches?: ToolDayPatch[];
  painTriage?: PainTriage;
  recoveryDays?: number;
  rampWeeks?: ReentryRampWeekInput[];
  // The RAW user turn that triggered this call, straight from the message
  // doc — never model-authored. The severe screen and category coercion run
  // over this text so a model paraphrase ("leg discomfort" for "shooting
  // pain down my leg") or a mislabeled reason can't route around the gate.
  rawUserText?: string;
  clientDate?: string;
}) {
  const rawText = input.rawUserText ?? "";
  // Category coercion: if the user's own words classify as injury (or trip
  // the severe screen), the proposal IS an injury proposal no matter what
  // reason the model picked — schedule_change can't smuggle a pain request
  // past the triage gate.
  // Coerce to whatever HIGH-RISK category the user's own words describe, not
  // just injury. classifyPlanAdjustment checks pregnancy BEFORE injury, so an
  // injury-only coercion let "I'm 6 weeks postpartum, ease me back in" keep
  // the model's benign reason and skip the high-risk hold entirely. Driving
  // the test off riskForCategory means a category added later can't quietly
  // fall through this gate the same way.
  const rawCategory = rawText.length > 0 ? classifyPlanAdjustment(rawText, false) : null;
  const rawSaysHighRisk = rawCategory !== null && riskForCategory(rawCategory, "") === "high";
  const category = rawSaysHighRisk
    ? rawCategory
    : rawText.length > 0 && hasSevereMarkers(rawText)
      ? "injury_pain"
      : ADAPT_PLAN_REASON_TO_CATEGORY[input.reason];
  const originalUserText = input.userNote?.trim() || `User requested a plan change (${input.reason}) via chat.`;

  // Risk resolution. For pain: the deterministic severe screen runs over
  // the user note, the triage description, AND the raw user turn — and is
  // absolute. Only when it comes back clean can a completed triage (red
  // flags asked, user reports non-severe) lower injury risk to appliable.
  // Joined with ". " (not spaces) so the negation mask in hasSevereMarkers
  // cannot bleed across utterance boundaries — a triage description ending
  // in a denial must not mask a severe phrase at the start of the raw turn.
  const severeText = [originalUserText, input.painTriage?.description ?? "", rawText].join(". ");
  let riskLevel = riskForCategory(category, severeText);
  let requiresFollowUp = needsFollowUp(
    category,
    riskLevel,
    (input.dayPatches?.length ?? 0) > 0,
  );
  let triageCleared = false;
  if (
    category === "injury_pain" &&
    !hasSevereMarkers(severeText) &&
    input.painTriage?.redFlagsAsked === true &&
    input.painTriage.userReportsSevere === false &&
    (input.dayPatches?.length ?? 0) > 0
  ) {
    // Triage-cleared, with a concrete modification to review: appliable.
    riskLevel = "low";
    requiresFollowUp = false;
    triageCleared = true;
  }

  // Re-entry ramp routing. A valid ramp only ever scales the user's OWN
  // baseline down and restores itself to 100% on a date they can see before
  // approving — so the medium-risk default that readiness_low carries (which
  // exists to catch "I feel run down") would block the single safest
  // adjustment the coach can make.
  //
  // Two hard limits on that downgrade, both learned the hard way:
  //   - it never applies to an inherently high-risk CATEGORY (injury,
  //     pregnancy/postpartum). riskForCategory is the authority, so this
  //     can't drift as categories are added.
  //   - the severe screen stays absolute. Real red flags hold the proposal
  //     at high risk for human review no matter how gentle the ramp looks.
  const isReentryRamp = (input.rampWeeks?.length ?? 0) > 0;
  let rampWeeks: ReentryRampWeekInput[] | undefined;
  if (input.reason === "returning_from_layoff" && !isReentryRamp) {
    // Otherwise this falls through to the generic readiness_low path and
    // persists a medium-risk card the user can't apply and the model isn't
    // told how to fix — a dead end with no error and no hint.
    return {
      proposalId: null,
      category,
      riskLevel,
      requiresFollowUp,
      dayKey: undefined,
      needsScopeConfirmation: false,
      error: "ramp_weeks_missing",
    };
  }
  if (isReentryRamp) {
    // Still acutely unwell. Returning to training while symptomatic from a
    // febrile illness is a genuine clinical caution, not a programming
    // question — and the ramp is the one adjustment that skips human review,
    // so this has to be a SERVER gate. The prompt says the same thing, but
    // this codebase's own history records prompt-level nudges failing twice
    // on live E2E; the gate is what actually holds.
    if (hasActiveIllnessMarkers(severeText)) {
      return {
        proposalId: null,
        category,
        riskLevel,
        requiresFollowUp,
        dayKey: undefined,
        needsScopeConfirmation: false,
        error: "ramp_not_valid_while_unwell",
      };
    }
    // A ramp scales the existing plan; it cannot route AROUND a movement.
    // Proposing one for pain would put the user's own aggravating exercise
    // back on the bar at 60% under a card that never mentions the pain —
    // and it would skip the injury safety notes and the recovery re-check
    // that the dayPatches path attaches.
    //
    // Driven off riskForCategory rather than a hardcoded pair so a high-risk
    // category added later can't slip through here and land as a persisted
    // card with no error and no hint — the dead end this guard exists to
    // prevent.
    if (riskForCategory(category, "") === "high") {
      return {
        proposalId: null,
        category,
        riskLevel,
        requiresFollowUp,
        dayKey: undefined,
        needsScopeConfirmation: false,
        error: "ramp_not_valid_for_this_category",
      };
    }
    const rampCheck = validateReentryRamp(input.rampWeeks);
    if (!rampCheck.ok) {
      return {
        proposalId: null,
        category,
        riskLevel,
        requiresFollowUp,
        dayKey: undefined,
        needsScopeConfirmation: false,
        error: rampCheck.error,
      };
    }
    rampWeeks = input.rampWeeks;
    if (riskForCategory(category, "") !== "high" && !hasSevereMarkers(severeText)) {
      riskLevel = "low";
      requiresFollowUp = false;
    }
  }
  // A ramp spans whole weeks, so a single target day is meaningless — and a
  // stray dayKey would mislabel the memory fact and the card. Explicitly
  // dropped rather than left to resolveAppliesToDayKey, which defaults
  // readiness_low to today.
  const rampScopeMismatch =
    (isReentryRamp && input.scope !== undefined && input.scope !== "reentry_ramp") ||
    (!isReentryRamp && input.scope === "reentry_ramp");
  if (rampScopeMismatch) {
    return {
      proposalId: null,
      category,
      riskLevel,
      requiresFollowUp,
      dayKey: undefined,
      needsScopeConfirmation: false,
      error: isReentryRamp ? "ramp_requires_reentry_ramp_scope" : "reentry_ramp_scope_requires_ramp_weeks",
    };
  }

  // P1-3a: "today" can only ever mean ONE day. A multi-day patch with
  // scope=today would silently behave like rest_of_week while the card's
  // one-tap button says "that day only" — bounce it back as a scope
  // question instead of mislabeling consent.
  if (input.scope === "today" && (input.dayPatches?.length ?? 0) > 1) {
    return {
      proposalId: null,
      category,
      riskLevel,
      requiresFollowUp,
      dayKey: input.dayPatches?.[0]?.dayKey,
      needsScopeConfirmation: true,
      error: "today_scope_is_single_day",
    };
  }

  const appliesTo = {
    planId: "current",
    // A ramp spans whole weeks; a target day would be a lie on the card and
    // in the plan-change memory fact, so it is never resolved for one.
    ...(isReentryRamp
      ? {}
      : resolveAppliesToDayKey(category, input.dayKey ?? input.dayPatches?.[0]?.dayKey)),
    ...(input.exerciseName ? { exerciseName: input.exerciseName } : {}),
    ...(input.scope ? { scope: input.scope } : {}),
  };

  let targetDay: PlannedWorkoutDayType | undefined;
  if (!requiresFollowUp && appliesTo.dayKey && !input.dayPatches?.length) {
    targetDay = await loadPlanDay(input.db, input.userId, appliesTo.dayKey);
    if (category === "time_limit" && (targetDay?.exercises.length ?? 0) < 2) {
      requiresFollowUp = true;
    }
  }

  const referenceDate = input.clientDate ?? currentDateISO();

  // Re-entry ramp: the proposal stores the SHAPE (percentages + notes), and
  // accept re-derives the sessions from whatever the baseline plan says at
  // that moment. The preview lines below are generated here from the same
  // helper the accept uses, so the card shows real dates and real training
  // days rather than an abstract promise — but if the plan changes between
  // propose and accept, the applied ramp tracks the NEW baseline, which is
  // the answer the user would want either way.
  if (rampWeeks) {
    const planSnapForPreview = await input.db.doc(workoutPlanPath(input.userId, "current")).get();
    const previewDays = isRecord(planSnapForPreview.data()?.days)
      ? (planSnapForPreview.data()!.days as Record<string, unknown>)
      : {};
    const previewExistingOverrides = isRecord(planSnapForPreview.data()?.dailyOverrides)
      ? (planSnapForPreview.data()!.dailyOverrides as Record<string, unknown>)
      : {};
    const previewOverrides = materializeRampOverrides(previewDays, rampWeeks, referenceDate);
    if (Object.keys(previewOverrides).length === 0) {
      // Nothing to reduce — an empty plan, an all-rest template, or a ramp
      // whose reduced weeks have already elapsed. Applying this would report
      // success while changing nothing.
      return {
        proposalId: null,
        category,
        riskLevel,
        requiresFollowUp,
        dayKey: undefined,
        needsScopeConfirmation: false,
        error: "ramp_has_no_training_days_to_scale",
      };
    }
    const persistedRamp = await persistPlanAdjustmentProposal({
      db: input.db,
      userId: input.userId,
      draft: true,
      source: "coach_chat",
      category,
      riskLevel,
      requiresFollowUp,
      originalUserText,
      // Scope is pinned, not asked. The "just today or going forward?"
      // question exists because those two writes are genuinely different
      // and the user's words don't disambiguate them. A ramp has no such
      // fork: the card lists the exact weeks and the exact return date, so
      // approving the card IS the scope decision.
      appliesTo: { ...appliesTo, scope: "reentry_ramp" as const },
      targetDay: undefined,
      patchOverride: {
        type: "reentry_ramp" as const,
        // "Starts when you approve" is load-bearing, not padding. Accept
        // re-anchors the ramp to the day the user says yes, so a card
        // approved three days later shifts every date below. Naming the
        // anchor keeps the preview honest instead of promising a calendar
        // the accept won't necessarily write.
        title: `Easing back in over ${rampWeeks.length} weeks — starts when you approve`,
        changes: [
          ...describeRampWeeks(previewDays, rampWeeks, referenceDate),
          ...describeRampRemovals(previewExistingOverrides, rampWeeks, previewDays, referenceDate),
        ],
        rampWeeks,
        // Every session the accept will write, so the card can render the
        // real exercises rather than a percentage the user can't unpack.
        rampDays: Object.entries(previewOverrides)
          .sort(([a], [b]) => a.localeCompare(b))
          .map(([date, day]) => ({ date, day })),
      },
      summaryOverride: `Work back up to your normal plan over ${rampWeeks.length} weeks (${rampWeeks
        .map((week) => `${week.intensityPct}%`)
        .join(" → ")}).`,
    });
    return {
      ...persistedRamp,
      supersededCount: await countProposalsAwaitingReview(
        input.db,
        input.userId,
        persistedRamp.proposalId,
      ),
      needsScopeConfirmation: false,
    };
  }

  // Model-authored multi-day patch: build the proposal content directly
  // from the (Zod-validated, bounded) replacement days.
  // rest_of_week means THROUGH SUNDAY of the user's current week. Patches
  // whose next occurrence would wrap into next week (Mon/Tue patched on a
  // Wednesday) are dropped — showing them as "this week" would be false.
  const keptDayPatches =
    input.scope === "rest_of_week" && input.dayPatches?.length
      ? input.dayPatches.filter(
          (patch) =>
            nextOccurrenceOfWeekday(patch.dayKey, referenceDate) <=
            endOfWeekSunday(referenceDate),
        )
      : input.dayPatches;
  if (input.dayPatches?.length && !keptDayPatches?.length) {
    return {
      proposalId: null,
      category,
      riskLevel,
      requiresFollowUp,
      dayKey: input.dayPatches[0]?.dayKey,
      needsScopeConfirmation: false,
      error: "no_patched_days_remain_this_week",
    };
  }

  const dayPatchesForProposal = keptDayPatches?.length
    ? keptDayPatches.map((patch) => ({
        dayKey: patch.dayKey,
        replacementDay: {
          name: patch.dayName,
          muscles: [],
          exercises: patch.replacementExercises,
        },
      }))
    : undefined;
  const patchOverride = dayPatchesForProposal
    ? {
        type: "replace_day_focus" as const,
        title: triageCleared
          ? "Adjusted week — works around the reported pain"
          : "Adjusted days",
        changes: dayPatchesForProposal.map(
          (patch) =>
            `${patch.dayKey} ${nextOccurrenceOfWeekday(patch.dayKey, referenceDate)}: ${patch.replacementDay.name} (${patch.replacementDay.exercises.length} exercises)`,
        ),
        dayPatches: dayPatchesForProposal,
      }
    : undefined;
  const summaryOverride = dayPatchesForProposal
    ? `Adjusted plan for ${dayPatchesForProposal.map((patch) => patch.dayKey).join(", ")}${
        triageCleared ? " to work around reported pain" : ""
      }.`
    : undefined;
  const recoveryDays =
    category === "injury_pain" && triageCleared
      ? Math.min(14, Math.max(3, input.recoveryDays ?? 5))
      : undefined;

  // An appliable proposal with no scope yet is a QUESTION, not a proposal —
  // the model is instructed to ask "just today, or going forward?" and call
  // again with the answer. Persisting a doc on the first call would leave an
  // orphaned pending proposal per scope exchange: it inflates
  // pendingProposalCount, surfaces a scope-less duplicate card in iOS, and
  // nothing ever expires it. So: analyze, but don't write.
  const needsScopeConfirmation = !requiresFollowUp && input.scope === undefined;
  if (needsScopeConfirmation) {
    return {
      proposalId: null,
      category,
      riskLevel,
      requiresFollowUp,
      dayKey: appliesTo.dayKey,
      needsScopeConfirmation: true,
    };
  }

  const persisted = await persistPlanAdjustmentProposal({
    db: input.db,
    userId: input.userId,
    draft: true,
    source: "coach_chat",
    category,
    riskLevel,
    requiresFollowUp,
    originalUserText,
    appliesTo,
    targetDay,
    patchOverride,
    summaryOverride,
    extraSafetyNotes: triageCleared ? INJURY_SAFETY_NOTES : undefined,
    recoveryDays,
  });

  // Revise flow ("actually make Friday lighter instead"): cards swap instead
  // of stacking. The swap itself now happens at publish time, atomically —
  // superseding here would strand the user with no card at all if the turn
  // died before this draft could be published.
  return {
    ...persisted,
    supersededCount: await countProposalsAwaitingReview(
      input.db,
      input.userId,
      persisted.proposalId,
    ),
    needsScopeConfirmation: false,
  };
}

// Ramp-back-up proposal ("feeling better — bring the intensity back").
// Accepting deletes all future-dated dailyOverrides so the template shows
// through again. Low risk by construction: it restores the user's own
// baseline plan, never invents new load.
export async function createClearOverridesProposalFromTool(input: {
  db: Firestore;
  userId: string;
  userNote: string;
}) {
  const persisted = await persistPlanAdjustmentProposal({
    db: input.db,
    userId: input.userId,
    draft: true,
    source: "coach_chat",
    category: "other",
    riskLevel: "low",
    requiresFollowUp: false,
    originalUserText: input.userNote.trim() || "Ramp back up to the regular plan.",
    appliesTo: { planId: "current" },
    targetDay: undefined,
    patchOverride: {
      type: "clear_overrides",
      title: "Back to your regular plan",
      changes: ["Remove the temporary adjustments and return to your normal programming."],
      clearOverrides: true,
    },
    summaryOverride: "Restore the regular plan by clearing temporary day adjustments.",
  });
  return {
    ...persisted,
    supersededCount: await countProposalsAwaitingReview(
      input.db,
      input.userId,
      persisted.proposalId,
    ),
  };
}

// The single most recent pending proposal — what the iOS card shows and
// what a chat-level "yes"/"no" refers to. Sorted in memory instead of
// orderBy so no composite index is needed (pending sets are tiny; new
// proposals supersede old ones).
export async function findLatestPendingProposal(db: Firestore, userId: string) {
  const snap = await db
    .collection(planAdjustmentProposalsCollectionPath(userId))
    .where("decision", "==", "pending")
    .get();
  const docs = snap.docs
    .filter((doc) => typeof doc.data().createdAt === "string")
    // ISO-8601 UTC strings sort lexicographically == chronologically;
    // localeCompare gives the comparator a stable 0 on ties. The DOC id is
    // authoritative for later writes — never trust a data().proposalId that
    // could disagree with the path.
    .sort((a, b) => String(b.data().createdAt).localeCompare(String(a.data().createdAt)));
  const first = docs[0];
  if (!first) return null;
  const result: { docId: string } & FirebaseFirestore.DocumentData = {
    docId: first.id,
    ...first.data(),
  };
  return result;
}

// End-of-turn publish. A coach turn may have written several drafts (the
// self-correcting loop re-calls adapt_plan to fix a locked proposal); only
// the newest is real. In ONE transaction: the newest draft becomes
// `pending`, every older draft and every previously-pending proposal becomes
// `superseded`.
//
// Doing this atomically at the END of the turn is what fixes the two-tap
// bug. Before, each adapt_plan published its own card immediately and then
// superseded the previous one, so a user reading card A could tap it in the
// window where the turn had already replaced it with B — the accept found a
// superseded doc and failed, and only the second tap (now on B) worked.
// Nothing is tappable mid-turn now, and what does appear is final.
//
// Safe to call when there are no drafts: it returns without writing.
// How many proposals this new one will replace once the turn publishes.
// Counted rather than written: the actual supersede happens atomically in
// publishDraftProposals, so nothing is destroyed if the turn dies partway.
// Fed back to the model so it can say "this replaces the earlier suggestion".
async function countProposalsAwaitingReview(db: Firestore, userId: string, excludeProposalId: string) {
  const collection = db.collection(planAdjustmentProposalsCollectionPath(userId));
  const [draftSnap, pendingSnap] = await Promise.all([
    collection.where("decision", "==", "draft").get(),
    collection.where("decision", "==", "pending").get(),
  ]);
  return [...draftSnap.docs, ...pendingSnap.docs].filter((doc) => doc.id !== excludeProposalId).length;
}

// `ownDraftIds` scopes this to the CALLING TURN's own proposals, and that
// scoping is load-bearing. Publishing every draft the user has would mean:
//   - a draft orphaned by a turn that died before its publish gets
//     resurrected by some unrelated later turn, killing whatever card the
//     user is actually looking at and replacing it with a proposal from a
//     conversation they never finished;
//   - two turns running concurrently (the user sends a second message while
//     the first is still thinking) publish each other's in-flight drafts —
//     which is exactly the mid-turn card this whole mechanism exists to
//     prevent, reintroduced by the fix for it.
// The ids come straight from this turn's tool results, so no schema field
// and no composite index is needed. An empty list means the turn proposed
// nothing and this is a no-op.
export async function publishDraftProposals(
  db: Firestore,
  userId: string,
  ownDraftIds: string[],
) {
  if (ownDraftIds.length === 0) {
    return { published: null as string | null, superseded: 0 };
  }
  const collection = db.collection(planAdjustmentProposalsCollectionPath(userId));
  const ownIds = new Set(ownDraftIds);
  const now = new Date().toISOString();
  return db.runTransaction(async (transaction) => {
    const [allDraftSnap, pendingSnap] = await Promise.all([
      transaction.get(collection.where("decision", "==", "draft")),
      transaction.get(collection.where("decision", "==", "pending")),
    ]);
    // Other turns' drafts come back from the query (Firestore can't filter on
    // a client-side id set) and are deliberately never touched.
    const ownDrafts = allDraftSnap.docs.filter((doc) => ownIds.has(doc.id));
    if (ownDrafts.length === 0) {
      return { published: null as string | null, superseded: 0 };
    }
    // Same ordering rule as findLatestPendingProposal: ISO-8601 UTC strings
    // sort lexicographically, and sorting in memory keeps this off a
    // composite index. Ties fall back to creation ORDER within the turn —
    // ownDraftIds is append-ordered, so the last tool call wins.
    const drafts = ownDrafts
      .filter((doc) => typeof doc.data().createdAt === "string")
      .sort((a, b) => {
        const byTime = String(b.data().createdAt).localeCompare(String(a.data().createdAt));
        return byTime !== 0 ? byTime : ownDraftIds.indexOf(b.id) - ownDraftIds.indexOf(a.id);
      });
    const winner = drafts[0];
    if (!winner) {
      // Every draft is malformed (no createdAt) — retire them rather than
      // leaving invisible docs to accumulate forever.
      for (const doc of ownDrafts) {
        transaction.set(
          doc.ref,
          { decision: "superseded", decidedAt: now, serverDecidedAt: FieldValue.serverTimestamp() },
          { merge: true },
        );
      }
      return { published: null as string | null, superseded: ownDrafts.length };
    }

    let superseded = 0;
    for (const doc of [...ownDrafts, ...pendingSnap.docs]) {
      if (doc.id === winner.id) continue;
      transaction.set(
        doc.ref,
        { decision: "superseded", decidedAt: now, serverDecidedAt: FieldValue.serverTimestamp() },
        { merge: true },
      );
      superseded += 1;
    }
    transaction.set(
      winner.ref,
      { decision: "pending", serverPublishedAt: FieldValue.serverTimestamp() },
      { merge: true },
    );
    return { published: winner.id, superseded };
  });
}

// A pending proposal is an OFFER, not a standing order. After a week the
// context that produced it (a pain report, a busy day) is stale — accepting
// it would apply a patch the user no longer means, and until then it inflates
// pendingProposalCount and can shadow newer work. This daily sweep flips
// pending docs older than the TTL to the terminal `expired` decision; the
// iOS pending-only listener drops the card automatically. Runs from the same
// daily scheduler as the program rollover (index.ts) — one schedule, two
// sweeps. Requires the (decision ASC, createdAt ASC) COLLECTION_GROUP
// composite index in firestore.indexes.json.
const PENDING_PROPOSAL_TTL_MS = 7 * 86_400_000;
// A draft belongs to ONE coach turn, and a turn is capped at 60s (the
// Firestore trigger's timeoutSeconds). A draft still unpublished an hour
// later means its turn died between writing the draft and reaching the
// publish step — it is orphaned, not in flight. Retiring it keeps an
// invisible proposal from surfacing days later attached to a conversation
// the user has long moved past.
const DRAFT_PROPOSAL_TTL_MS = 3_600_000;
const EXPIRY_SCAN_LIMIT = 200;

export async function expireStalePendingProposals(db: Firestore, nowISO?: string) {
  const now = nowISO ?? new Date().toISOString();
  const cutoff = new Date(Date.parse(now) - PENDING_PROPOSAL_TTL_MS).toISOString();
  const draftCutoff = new Date(Date.parse(now) - DRAFT_PROPOSAL_TTL_MS).toISOString();
  const [pendingStale, draftStale] = await Promise.all([
    db
      .collectionGroup("planAdjustmentProposals")
      .where("decision", "==", "pending")
      .where("createdAt", "<", cutoff)
      .limit(EXPIRY_SCAN_LIMIT)
      .get(),
    db
      .collectionGroup("planAdjustmentProposals")
      .where("decision", "==", "draft")
      .where("createdAt", "<", draftCutoff)
      .limit(EXPIRY_SCAN_LIMIT)
      .get(),
  ]);
  const stale = {
    docs: [...pendingStale.docs, ...draftStale.docs],
    size: pendingStale.size + draftStale.size,
  };

  let expired = 0;
  let failed = 0;
  for (const doc of stale.docs) {
    try {
      // Transactional per-doc flip: only a doc STILL pending (or still an
      // orphaned draft) at the transaction's own read time gets expired — a
      // concurrent card-tap accept, or a slow turn that publishes just now,
      // commits first and wins. Same discipline as supersede/reject.
      const flipped = await db.runTransaction(async (transaction) => {
        const snap = await transaction.get(doc.ref);
        if (!snap.exists) return false;
        const decision = snap.get("decision");
        if (decision !== "pending" && decision !== "draft") return false;
        transaction.set(
          doc.ref,
          { decision: "expired", decidedAt: now, serverDecidedAt: FieldValue.serverTimestamp() },
          { merge: true },
        );
        return true;
      });
      if (flipped) expired += 1;
    } catch (error) {
      // One bad doc must not starve the rest of the sweep.
      failed += 1;
      safeLogger.warn("Plan adjustment proposal expiry failed", {
        event: "plan_adjustment_proposal_expiry_failed",
        proposalId: doc.id,
        errorDetail: error instanceof Error ? error.message.slice(0, 200) : "unknown_error",
      });
    }
  }

  safeLogger.info("Stale pending and orphaned draft proposals expired", {
    event: "plan_adjustment_proposals_expired",
    outcome: `expired_${expired}_failed_${failed}_of_${stale.size}`,
  });
  return { expired, failed, scanned: stale.size };
}

// Error codes the model may see verbatim. Anything else (ZodError dumps,
// Firestore infra errors) is mapped to accept_failed and logged server-side
// only — same values-never-leave-the-server convention as the HTTP handlers.
const KNOWN_ACCEPT_ERRORS = new Set([
  "plan_adjustment_proposal_not_found",
  "workout_plan_not_found",
  "plan_adjustment_user_mismatch",
  "plan_adjustment_not_pending",
  "plan_adjustment_requires_review",
  "plan_adjustment_patch_not_supported",
  "plan_adjustment_patch_removed_all_exercises",
  "plan_adjustment_target_day_not_found",
  "plan_adjustment_ramp_produced_no_days",
  "training_program_not_loaded_for_cascade",
]);

// Chat-driven accept ("yes, update my training"). Resolves the latest
// pending proposal server-side and funnels through the SAME
// acceptPlanAdjustmentProposal gate as the card tap — risk level,
// follow-up, and scope requirements all still apply; this only changes who
// pulls the trigger, not what is allowed to fire.
//
// allowedProposalId is the TURN BOUNDARY: the id of the latest pending
// proposal as of the start of this coach turn (null if none). A proposal
// the model created mid-turn via adapt_plan can never be accepted in the
// same breath — the user must see it (card or reply) and say yes in a
// LATER message. Without this check, propose→accept in one 6-round tool
// loop would mutate the plan with no human in the loop at all.
export async function acceptLatestPlanAdjustmentFromChat(
  db: Firestore,
  userId: string,
  scope: AdjustmentScope | undefined,
  allowedProposalId: string | null,
  clientDate: string | undefined,
) {
  const pending = await findLatestPendingProposal(db, userId);
  if (!pending) {
    return { ok: false as const, error: "no_pending_proposal" };
  }
  const proposalId = pending.docId;
  if (allowedProposalId === null || proposalId !== allowedProposalId) {
    return { ok: false as const, error: "proposal_not_visible_yet", proposalId };
  }
  // Risk gate first: a high-risk or needs-follow-up proposal can never be
  // chat-accepted, so don't waste a round asking about scope for it.
  const riskLevel = RiskLevel.safeParse(pending.riskLevel);
  if (!riskLevel.success || riskLevel.data !== "low" || pending.requiresFollowUp === true) {
    return { ok: false as const, error: "plan_adjustment_requires_review", proposalId };
  }
  const presetScope = PlanAdjustmentScope.safeParse(
    isRecord(pending.appliesTo) ? pending.appliesTo.scope : undefined,
  );
  const effectiveScope = scope ?? (presetScope.success ? presetScope.data : undefined);
  const isClearOverrides =
    isRecord(pending.proposedPlanPatch) && pending.proposedPlanPatch.type === "clear_overrides";
  if (effectiveScope === undefined && !isClearOverrides) {
    // The user hasn't said how far this should reach — the model must ask
    // before accepting, exactly like the card's two-button picker.
    // clear_overrides is scope-free by design (it deletes future overrides).
    return { ok: false as const, error: "scope_required", proposalId };
  }
  try {
    const result = await acceptPlanAdjustmentProposal(db, userId, {
      proposalId,
      scope: effectiveScope,
      ...(clientDate !== undefined ? { clientDate } : {}),
    });
    return { ok: true as const, proposalId: result.proposalId, appliedScope: effectiveScope };
  } catch (error) {
    const raw = error instanceof Error ? error.message : "accept_failed";
    const code = KNOWN_ACCEPT_ERRORS.has(raw) ? raw : "accept_failed";
    if (code === "accept_failed") {
      safeLogger.warn("Chat accept failed with unexpected error", {
        event: "plan_adjustment_chat_accept_error",
        userId,
        proposalId,
        errorDetail: raw.slice(0, 200),
      });
    }
    return { ok: false as const, error: code, proposalId };
  }
}

// Chat-driven reject ("no thanks"). Terminal decision on the latest
// pending proposal; the iOS pending-only listener drops the card.
// Transactional: re-reads the doc so a concurrent card-tap accept that
// commits first wins — an accepted proposal must never be flipped to
// rejected after the plan already mutated.
export async function rejectLatestPlanAdjustmentFromChat(db: Firestore, userId: string) {
  const pending = await findLatestPendingProposal(db, userId);
  if (!pending) {
    return { ok: false as const, error: "no_pending_proposal" };
  }
  const proposalId = pending.docId;
  const ref = db.doc(planAdjustmentProposalPath(userId, proposalId));
  const now = new Date().toISOString();
  const rejected = await db.runTransaction(async (transaction) => {
    const snap = await transaction.get(ref);
    if (!snap.exists || snap.get("decision") !== "pending") {
      return false;
    }
    transaction.set(
      ref,
      { decision: "rejected", decidedAt: now, serverDecidedAt: FieldValue.serverTimestamp() },
      { merge: true },
    );
    return true;
  });
  if (!rejected) {
    return { ok: false as const, error: "plan_adjustment_not_pending", proposalId };
  }
  safeLogger.info("Plan adjustment proposal rejected from chat", {
    event: "plan_adjustment_proposal_rejected",
    userId,
    proposalId,
    outcome: "rejected",
  });
  return { ok: true as const, proposalId };
}

async function persistPlanAdjustmentProposal(input: {
  db: Firestore;
  userId: string;
  // Tool-loop callers write drafts (invisible until the turn ends); the
  // deterministic classifier and the workout-detail sheet write pending
  // directly, because those paths create exactly one proposal per request
  // with no chance of superseding it a moment later.
  draft?: boolean;
  source: "coach_chat" | "workout_detail" | "system";
  category: AdjustmentCategory;
  riskLevel: AdjustmentRiskLevel;
  requiresFollowUp: boolean;
  originalUserText: string;
  appliesTo: { planId: string; dayKey?: string; exerciseName?: string; scope?: AdjustmentScope };
  targetDay: PlannedWorkoutDayType | undefined;
  structuredAnswer?: Record<string, unknown>;
  // Tool-path extensions: model-authored patch content + injury metadata.
  patchOverride?: Record<string, unknown>;
  summaryOverride?: string;
  extraSafetyNotes?: string[];
  recoveryDays?: number;
}) {
  const profileSnap = await input.db.doc(profilePath(input.userId)).get();
  const profile = profileSnap.exists ? profileSnap.data() ?? null : null;
  const retrievedCorpus = retrieveResearchCorpus({
    userContent: input.originalUserText,
    profile,
    maxEntries: 4,
  });

  const now = new Date().toISOString();
  const proposalId = `adjustment_${randomUUID()}`;

  const proposal = PlanAdjustmentProposal.parse({
    userId: input.userId,
    proposalId,
    source: input.source,
    decision: input.draft ? "draft" : "pending",
    category: input.category,
    riskLevel: input.riskLevel,
    originalUserText: input.originalUserText,
    summary: input.summaryOverride ?? summaryForCategory(input.category, input.appliesTo.exerciseName),
    rationale: rationaleForCategory(input.category),
    appliesTo: input.appliesTo,
    proposedPlanPatch:
      input.patchOverride ?? patchForCategory(input.category, input.requiresFollowUp, input.targetDay),
    sourceCorpusEntryIds: retrievedCorpus.map((entry) => entry.entryId),
    safetyNotes: [
      ...(input.extraSafetyNotes ?? []),
      ...safetyNotesForCategory(input.category, retrievedCorpus.flatMap((entry) => entry.safetyBoundaries)),
    ].slice(0, 8),
    requiresFollowUp: input.requiresFollowUp,
    ...(input.recoveryDays !== undefined ? { recoveryDays: input.recoveryDays } : {}),
    ...(input.structuredAnswer ? { structuredAnswer: input.structuredAnswer } : {}),
    createdAt: now,
  });

  await input.db.doc(planAdjustmentProposalPath(input.userId, proposalId)).set({
    ...proposal,
    serverCreatedAt: FieldValue.serverTimestamp(),
  });

  safeLogger.info("Plan adjustment proposal created", {
    event: "plan_adjustment_proposal_created",
    userId: input.userId,
    proposalId,
    outcome: input.category,
  });

  return {
    proposalId,
    category: input.category,
    riskLevel: input.riskLevel,
    requiresFollowUp: input.requiresFollowUp,
    dayKey: input.appliesTo.dayKey,
    sourceCorpusEntryIds: proposal.sourceCorpusEntryIds,
  };
}

export async function acceptPlanAdjustmentProposal(
  db: Firestore,
  userId: string,
  request: z.infer<typeof AcceptPlanAdjustmentProposalRequest>,
) {
  const proposalRef = db.doc(planAdjustmentProposalPath(userId, request.proposalId));
  const planRef = db.doc(workoutPlanPath(userId, "current"));
  const programRef = db.doc(trainingProgramPath(userId));
  const serverDecidedAt = new Date().toISOString();

  // Peek at the requested scope before the transaction so the program
  // backfill only runs when the accept actually needs the program doc.
  // ensureTrainingProgram may itself write (backfill), and Firestore
  // transactions require all reads before any write — so it can't run
  // inside the transaction. Gating it also means a today-scope or legacy
  // accept can never fail on a malformed legacy program backfill.
  const proposalPeek = await proposalRef.get();
  if (!proposalPeek.exists) {
    throw new Error("plan_adjustment_proposal_not_found");
  }
  const rawPeekScope = isRecord(proposalPeek.data()?.appliesTo)
    ? (proposalPeek.data()?.appliesTo as Record<string, unknown>).scope
    : undefined;
  const peekScopeParse = PlanAdjustmentScope.safeParse(rawPeekScope);
  const peekScope = request.scope ?? (peekScopeParse.success ? peekScopeParse.data : undefined);
  const needsProgram = peekScope === "going_forward";
  if (needsProgram) {
    await ensureTrainingProgram(db, userId);
  }

  await db.runTransaction(async (transaction) => {
    const [proposalSnap, planSnap, programSnap] = await Promise.all([
      transaction.get(proposalRef),
      transaction.get(planRef),
      needsProgram ? transaction.get(programRef) : Promise.resolve(null),
    ]);

    if (!proposalSnap.exists) {
      throw new Error("plan_adjustment_proposal_not_found");
    }
    if (!planSnap.exists) {
      throw new Error("workout_plan_not_found");
    }

    const proposal = parsePlanAdjustmentProposalDocument(proposalSnap.data());
    if (proposal.userId !== userId) {
      throw new Error("plan_adjustment_user_mismatch");
    }
    if (proposal.decision !== "pending") {
      throw new Error("plan_adjustment_not_pending");
    }
    if (proposal.riskLevel !== "low" || proposal.requiresFollowUp) {
      throw new Error("plan_adjustment_requires_review");
    }

    // Ramping back up (clear_overrides) means the user just told us they're
    // better — any still-scheduled recovery check-in ("feeling better?") is
    // now noise, so cancel it. The query read happens HERE, inside the
    // transaction and before any write (Firestore requires all transaction
    // reads before the first write); the cancels join the same commit below,
    // so a delivery sweep racing this accept forces a retry rather than
    // sending a check-in the user already answered.
    let scheduledFollowUpRefs: FirebaseFirestore.DocumentReference[] = [];
    if (proposal.proposedPlanPatch.type === "clear_overrides") {
      const scheduledSnap = await transaction.get(
        db.collection(coachFollowUpsCollectionPath(userId)).where("status", "==", "scheduled"),
      );
      scheduledFollowUpRefs = scheduledSnap.docs.map((docSnap) => docSnap.ref);
    }

    // clear_overrides is scope-free: recording whatever button an old
    // client sent would write a false label into appliesTo and the memory
    // fact ("for that day only" on a full restore).
    const scope =
      proposal.proposedPlanPatch.type === "clear_overrides"
        ? undefined
        : (request.scope ?? proposal.appliesTo.scope);
    const program = programSnap?.exists
      ? parseTrainingProgramDocument(programSnap.data())
      : null;
    const { planPatch, programPatch } = planPatchForAcceptedProposal(
      proposal,
      planSnap.data() ?? {},
      program,
      scope,
      request.clientDate,
    );

    transaction.set(
      planRef,
      {
        ...planPatch,
        source: "user_edited",
        updatedAt: serverDecidedAt,
        serverUpdatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    if (programPatch) {
      transaction.set(
        programRef,
        {
          ...programPatch,
          source: "user_edited",
          updatedAt: serverDecidedAt,
          serverUpdatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    }

    transaction.set(
      proposalRef,
      {
        decision: "accepted",
        decidedAt: serverDecidedAt,
        // Firestore rejects `undefined`; only write when the client sent it.
        ...(request.decidedAt !== undefined ? { clientDecidedAt: request.decidedAt } : {}),
        // Record the scope that was actually applied, so later coach turns
        // (and the plan-change memory) know how far this reached. Deep-merge
        // the whole appliesTo map: a dotted "appliesTo.scope" key in set()
        // with merge would write a LITERAL top-level field named
        // "appliesTo.scope" (dots are field paths only in update()).
        ...(scope !== undefined ? { appliesTo: { ...proposal.appliesTo, scope } } : {}),
        serverDecidedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    // The early-recovery cancels read above; clear_overrides proposals never
    // carry recoveryDays, so this can't cancel a follow-up scheduled in the
    // same commit.
    for (const followUpRef of scheduledFollowUpRefs) {
      transaction.set(
        followUpRef,
        {
          status: "cancelled",
          cancelledAt: serverDecidedAt,
          serverUpdatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    }

    // Injury adjustments schedule a recovery re-check: the daily follow-up
    // function turns due docs into a coach message ("been 5 days — feeling
    // better? want to ramp back up?").
    if (proposal.recoveryDays !== undefined) {
      const followUpId = `followup_${proposal.proposalId}`;
      const dueAt = new Date(Date.now() + proposal.recoveryDays * 86_400_000).toISOString();
      transaction.set(db.doc(coachFollowUpPath(userId, followUpId)), {
        userId,
        followUpId,
        kind: "injury_recheck",
        context: proposal.summary.slice(0, 300),
        proposalId: proposal.proposalId,
        dueAt,
        status: "scheduled",
        createdAt: serverDecidedAt,
        serverCreatedAt: FieldValue.serverTimestamp(),
      });
    }

    // Record what changed and why, so a later coach turn can reference it
    // ("since we shortened Tuesday's session...") instead of re-asking.
    // Written `confirmed` (not `proposed`, unlike upsertMemoryFact's default
    // for coach_inferred facts) because the user already explicitly
    // approved this exact change by accepting the proposal.
    // The content is SERVER-GENERATED ONLY (summary/day/scope) — the
    // proposal's originalUserText can be model-authored (adapt_plan tool)
    // and is never shown on the approval card, so echoing it here would
    // launder unreviewed model text into confirmed memory that future
    // prompts trust. The raw text stays on the proposal doc for audit.
    const memoryFactRef = db.doc(memoryFactPath(userId, `plan_change_${proposal.proposalId}`));
    const memoryFact = CoachMemoryFact.parse({
      userId,
      factId: `plan_change_${proposal.proposalId}`,
      category: "plan_change",
      content: planChangeMemoryContent(proposal, scope),
      source: "coach_inferred",
      confidence: 1,
      state: "confirmed",
      lastConfirmedAt: serverDecidedAt,
      createdAt: serverDecidedAt,
      lastReinforcedAt: serverDecidedAt,
      userEditable: true,
    });
    transaction.set(memoryFactRef, memoryFact);
  });

  safeLogger.info("Plan adjustment proposal accepted", {
    event: "plan_adjustment_proposal_accepted",
    userId,
    proposalId: request.proposalId,
    outcome: "accepted",
  });

  return { ok: true, proposalId: request.proposalId, decidedAt: serverDecidedAt };
}

function parsePlanAdjustmentProposalDocument(data: FirebaseFirestore.DocumentData | undefined) {
  const raw = data ?? {};
  return PlanAdjustmentProposal.parse({
    userId: raw.userId,
    proposalId: raw.proposalId,
    source: raw.source,
    decision: raw.decision,
    category: raw.category,
    riskLevel: raw.riskLevel,
    originalUserText: raw.originalUserText,
    summary: raw.summary,
    rationale: raw.rationale,
    appliesTo: raw.appliesTo,
    proposedPlanPatch: raw.proposedPlanPatch,
    sourceCorpusEntryIds: raw.sourceCorpusEntryIds,
    safetyNotes: raw.safetyNotes,
    requiresFollowUp: raw.requiresFollowUp,
    recoveryDays: raw.recoveryDays,
    structuredAnswer: raw.structuredAnswer,
    createdAt: raw.createdAt,
    decidedAt: raw.decidedAt,
  });
}

// Computes the day-content the accepted patch should install, independent
// of scope — scope only decides WHERE that content gets written (see
// planPatchForAcceptedProposal below).
function computePatchedDay(
  patch: ProposedPlanPatch,
  currentDay: PlannedWorkoutDayType | undefined,
): PlannedWorkoutDayType {
  if (patch.type === "reschedule_day") {
    return { name: "Rest · Skipped", muscles: [], exercises: [] };
  }

  if (patch.replacementDay) {
    return patch.replacementDay;
  }

  if (patch.type === "shorten_workout" || patch.type === "modify_exercise" || patch.type === "replace_exercise") {
    if (!currentDay) {
      throw new Error("plan_adjustment_target_day_not_found");
    }
    // A diff-style patch with nothing in it (e.g. a pending pre-deploy
    // proposal doc that predates removeExercises/addExercises) must fail
    // loudly like it did before this patch type existed — an accept that
    // changes nothing while claiming success corrupts the user's mental
    // model AND writes a false plan_change memory fact.
    if (patch.removeExercises.length === 0 && patch.addExercises.length === 0) {
      throw new Error("plan_adjustment_patch_not_supported");
    }
    let exercises = currentDay.exercises;
    if (patch.removeExercises.length > 0) {
      // Remove by occurrence budget, not by name-set: a day with two
      // "Plank" entries and removeExercises=["Plank"] should lose ONE.
      const removeBudget = new Map<string, number>();
      for (const name of patch.removeExercises) {
        const key = normalizeExerciseName(name);
        removeBudget.set(key, (removeBudget.get(key) ?? 0) + 1);
      }
      exercises = exercises.filter((exercise) => {
        const key = normalizeExerciseName(exercise.name);
        const remaining = removeBudget.get(key) ?? 0;
        if (remaining > 0) {
          removeBudget.set(key, remaining - 1);
          return false;
        }
        return true;
      });
    }
    if (patch.addExercises.length > 0) {
      exercises = [...exercises, ...patch.addExercises];
    }
    if (exercises.length === 0) {
      throw new Error("plan_adjustment_patch_removed_all_exercises");
    }
    return { ...currentDay, exercises };
  }

  throw new Error("plan_adjustment_patch_not_supported");
}

// Rebuilds the full `weeks` array with `dayKey` patched from the active
// week onward. Firestore can't merge inside an array element, so the whole
// array has to be reconstructed and written back.
function patchProgramWeeks(
  program: TrainingProgramType,
  dayKey: string,
  patchedDay: PlannedWorkoutDayType,
): { weeks: TrainingProgramType["weeks"] } {
  const weeks = program.weeks.map((week) => {
    if (week.weekIndex < program.activeWeekIndex) return week;
    return { ...week, days: { ...week.days, [dayKey]: patchedDay } };
  });
  return { weeks };
}

function planPatchForAcceptedProposal(
  proposal: z.infer<typeof PlanAdjustmentProposal>,
  plan: Record<string, unknown>,
  program: TrainingProgramType | null,
  scope: AdjustmentScope | undefined,
  clientDate: string | undefined,
): { planPatch: Record<string, unknown>; programPatch?: Record<string, unknown> } {
  const days = isRecord(plan.days) ? plan.days : {};
  const today = clientDate ?? currentDateISO();

  // Ramp-back-up: delete every override dated today or later so the
  // template shows through again. Scope-independent by design.
  if (proposal.proposedPlanPatch.type === "clear_overrides") {
    const existing = isRecord(plan.dailyOverrides) ? plan.dailyOverrides : {};
    const deleteMarkers = Object.fromEntries(
      Object.keys(existing)
        .filter((date) => date >= today)
        .map((date) => [date, FieldValue.delete()]),
    );
    // An EXPLICITLY EMPTY map in set(merge:true) replaces the whole map —
    // when nothing is due for deletion, don't touch the field at all.
    return {
      planPatch: Object.keys(deleteMarkers).length > 0 ? { dailyOverrides: deleteMarkers } : {},
    };
  }

  // Re-entry ramp: dated overrides across the whole ramp window, derived
  // from the LIVE baseline template. Same expiry mechanism as rest_of_week —
  // the overrides simply run out, week by week, and the last ramp week is
  // 100% (validated at proposal time) so the plan lands back on its own
  // programming rather than snapping back from an arbitrary reduction.
  if (proposal.proposedPlanPatch.type === "reentry_ramp") {
    const rampWeeks = proposal.proposedPlanPatch.rampWeeks;
    if (!rampWeeks?.length) {
      throw new Error("plan_adjustment_patch_not_supported");
    }
    const overrides = materializeRampOverrides(days, rampWeeks, today);
    if (Object.keys(overrides).length === 0) {
      // The ramp's reduced weeks have elapsed (a proposal accepted days
      // later) or the plan has no training days left to scale. Fail loudly
      // rather than writing nothing and reporting success — same rule as
      // computePatchedDay's empty-diff guard.
      throw new Error("plan_adjustment_ramp_produced_no_days");
    }
    // Past-dated keys are dead weight, as on every other path. Inside the
    // ramp WINDOW the window is also cleared — otherwise an override left
    // from an earlier adjustment sits on a date the ramp deliberately does
    // not write (a rest day, a 100% "back to normal" week) and keeps
    // overriding it, so the card's promised return to normal never happens.
    //
    // Clearing content the user approved earlier is only legitimate because
    // rampRemovalDates feeds those same dates onto the approval card, spelled
    // out — see describeRampRemovals. Prune and disclosure are computed from
    // one helper precisely so they cannot drift apart.
    const existing = isRecord(plan.dailyOverrides) ? plan.dailyOverrides : {};
    const removalDates = new Set([
      ...Object.keys(existing).filter((date) => date < today),
      ...rampRemovalDates(existing, rampWeeks, days, today),
    ]);
    const pruneMarkers = Object.fromEntries(
      [...removalDates]
        .filter((date) => !(date in overrides))
        .map((date) => [date, FieldValue.delete()]),
    );
    return { planPatch: { dailyOverrides: { ...pruneMarkers, ...overrides } } };
  }

  // Multi-day (model-authored) patches: one dated override per patched
  // day's next occurrence within the coming 7 days. "today" and
  // "rest_of_week" share this shape — a weekday occurs once per 7-day
  // window, so per-day dated overrides ARE the rest-of-week semantics,
  // and they expire by date (next week reverts to the template).
  const contractDayPatches = proposal.proposedPlanPatch.dayPatches;
  if (contractDayPatches && contractDayPatches.length > 0) {
    if (scope === "going_forward") {
      if (!program) {
        throw new Error("training_program_not_loaded_for_cascade");
      }
      let nextDays = { ...days };
      let weeks = program.weeks;
      for (const patch of contractDayPatches) {
        nextDays = { ...nextDays, [patch.dayKey]: patch.replacementDay };
        weeks = patchProgramWeeks({ ...program, weeks }, patch.dayKey, patch.replacementDay).weeks;
      }
      // A permanent change must WIN immediately: prune EVERY still-active
      // override on the patched weekdays, or the Train tab keeps showing old
      // override content after approval. Matching on weekday rather than on
      // each weekday's next occurrence is load-bearing now that a re-entry
      // ramp can write overrides up to six weeks out — the old
      // next-occurrence-only prune cleared one date and left the rest of the
      // ramp shadowing the new permanent plan for weeks.
      const existingOverrides = isRecord(plan.dailyOverrides) ? plan.dailyOverrides : {};
      const patchedWeekdays = new Set(contractDayPatches.map((patch) => patch.dayKey));
      const overridePrune = Object.fromEntries(
        Object.keys(existingOverrides)
          .filter((date) => date >= today && patchedWeekdays.has(weekdayOfISODate(date)))
          .map((date) => [date, FieldValue.delete()]),
      );
      return {
        planPatch: {
          days: nextDays,
          ...(Object.keys(overridePrune).length > 0 ? { dailyOverrides: overridePrune } : {}),
        },
        programPatch: { weeks },
      };
    }
    const existing = isRecord(plan.dailyOverrides) ? plan.dailyOverrides : {};
    const pruneMarkers = Object.fromEntries(
      Object.keys(existing)
        .filter((date) => date < today)
        .map((date) => [date, FieldValue.delete()]),
    );
    const overrides = Object.fromEntries(
      contractDayPatches.map((patch) => [
        nextOccurrenceOfWeekday(patch.dayKey, today),
        patch.replacementDay,
      ]),
    );
    return { planPatch: { dailyOverrides: { ...pruneMarkers, ...overrides } } };
  }

  const dayKey = proposal.appliesTo.dayKey ?? weekdayOfISODate(today);
  const currentDay = isRecord(days[dayKey]) ? (days[dayKey] as PlannedWorkoutDayType) : undefined;
  const patchedDay = computePatchedDay(proposal.proposedPlanPatch, currentDay);

  // Single-day rest_of_week degenerates to the dated-override shape too:
  // the day's next occurrence, expiring naturally.
  if (scope === "rest_of_week") {
    const existing = isRecord(plan.dailyOverrides) ? plan.dailyOverrides : {};
    const pruneMarkers = Object.fromEntries(
      Object.keys(existing)
        .filter((date) => date < today)
        .map((date) => [date, FieldValue.delete()]),
    );
    return {
      planPatch: {
        dailyOverrides: { ...pruneMarkers, [nextOccurrenceOfWeekday(dayKey, today)]: patchedDay },
      },
    };
  }

  if (scope === "today") {
    // Key the override to the date of the proposal's TARGET day — its next
    // occurrence on/after the user's "today" — not blindly to today. A
    // Friday-targeting proposal accepted on Wednesday must land on Friday's
    // date; keying it to Wednesday would put Friday's content on the wrong
    // day and leave Friday untouched. Past-dated overrides are pruned on
    // the same write via FieldValue.delete() sentinels — with merge:true a
    // rewritten map MERGES per-key, so simply omitting stale keys would
    // leave them in place forever.
    const overrideDate = nextOccurrenceOfWeekday(dayKey, today);
    const existing = isRecord(plan.dailyOverrides) ? plan.dailyOverrides : {};
    const pruneMarkers = Object.fromEntries(
      Object.keys(existing)
        .filter((date) => date < today)
        .map((date) => [date, FieldValue.delete()]),
    );
    return {
      planPatch: {
        dailyOverrides: { ...pruneMarkers, [overrideDate]: patchedDay },
      },
    };
  }

  if (scope === "going_forward") {
    if (!program) {
      throw new Error("training_program_not_loaded_for_cascade");
    }
    // Same rule as the multi-day branch above: a permanent change has to
    // clear the temporary overrides shadowing it. This branch pruned nothing
    // at all, so a live ramp override on this weekday kept overriding the
    // new permanent day until it expired.
    const existingOverrides = isRecord(plan.dailyOverrides) ? plan.dailyOverrides : {};
    const overridePrune = Object.fromEntries(
      Object.keys(existingOverrides)
        .filter((date) => date >= today && weekdayOfISODate(date) === dayKey)
        .map((date) => [date, FieldValue.delete()]),
    );
    return {
      planPatch: {
        days: { ...days, [dayKey]: patchedDay },
        ...(Object.keys(overridePrune).length > 0 ? { dailyOverrides: overridePrune } : {}),
      },
      programPatch: patchProgramWeeks(program, dayKey, patchedDay),
    };
  }

  // Legacy/no-scope callers (workout-detail sheet, older clients): keep the
  // pre-scope behavior byte-for-byte — in-place patch on the template day
  // only, no dailyOverrides, no program write.
  return { planPatch: { days: { ...days, [dayKey]: patchedDay } } };
}

// Scales one baseline session to a percentage of normal. SETS carry the
// reduction, load follows, reps are left alone — cutting reps changes what
// the set trains (a 5-rep bench and a 12-rep bench are different exercises),
// while cutting sets is the standard deload lever and keeps every movement
// pattern in the week intact. Both floor at the smallest real dose rather
// than rounding to zero: a 40% week on a 1-set accessory must still be one
// set, or the "ramp" silently deletes the exercise.
export function scaleDayToIntensity(
  day: PlannedWorkoutDayType,
  intensityPct: number,
): PlannedWorkoutDayType {
  const factor = intensityPct / 100;
  return {
    ...day,
    name: `${day.name} · ${intensityPct}%`,
    exercises: day.exercises.map((exercise) => ({
      ...exercise,
      sets: Math.min(exercise.sets, Math.max(1, Math.round(exercise.sets * factor))),
      weight: scaleWeight(exercise.weight, factor),
    })),
  };
}

// Rounded to the nearest 5 because that is what plates come in — a "137.5 lb"
// bench prescription reads as a bug, not a deload — then CLAMPED TO BASELINE.
// The clamp is the load-bearing part: rounding to the nearest 5 rounds UP
// whenever the remainder is ≥ 2.5, so a 95% week on an 8 lb dumbbell produced
// 10 lb, and a small-weight floor turned a 2.5 lb rehab load into 5 lb. That
// hands someone MORE weight on their easiest week — the opposite of a deload,
// and it falsifies the "a ramp only ever reduces" invariant that is the whole
// reason a ramp is allowed to apply without review. Light loads (< 5 lb) keep
// their exact baseline rather than being floored upward.
function scaleWeight(baseline: number, factor: number): number {
  if (baseline <= 0) return 0;
  const rounded = Math.round((baseline * factor) / 5) * 5;
  return Math.min(baseline, Math.max(rounded, Math.min(5, baseline)));
}

// Where the ramp actually begins. Normally that is today, with week 0 running
// today → Sunday: a ramp proposed on a Thursday must not pretend to have
// reduced Monday.
//
// But when the remainder of this week holds NO training day — a Mon/Wed/Fri
// split on a Saturday, the single likeliest moment for "I fell off" — anchoring
// to today burns the gentlest week on an empty stub. A 3-week [50, 75, 100]
// ramp would deliver its first real session at 75%, and a 2-week [50, 100]
// ramp would materialize nothing at all and be refused outright. So the ramp
// SHIFTS to start next Monday instead. Shifting, never truncating: the user
// approved a number of graded steps, and every one of them gets delivered.
export function rampAnchorDate(days: Record<string, unknown>, today: string): string {
  const remainderOfThisWeek = datesBetween(today, endOfWeekSunday(today));
  const hasTrainingDay = remainderOfThisWeek.some((date) => isTrainingDay(days[weekdayOfISODate(date)]));
  if (hasTrainingDay) return today;
  return addDays(endOfWeekSunday(today), 1);
}

function isTrainingDay(baseline: unknown): boolean {
  if (!isRecord(baseline)) return false;
  const day = baseline as PlannedWorkoutDayType;
  return Array.isArray(day.exercises) && day.exercises.length > 0;
}

function addDays(isoDate: string, days: number): string {
  const parsed = Date.parse(`${isoDate}T00:00:00Z`);
  if (Number.isNaN(parsed)) return isoDate;
  return new Date(parsed + days * 86_400_000).toISOString().slice(0, 10);
}

function datesBetween(startISO: string, endISO: string): string[] {
  const start = Date.parse(`${startISO}T00:00:00Z`);
  const end = Date.parse(`${endISO}T00:00:00Z`);
  if (Number.isNaN(start) || Number.isNaN(end)) return [];
  const dates: string[] = [];
  for (let ms = start; ms <= end; ms += 86_400_000) {
    dates.push(new Date(ms).toISOString().slice(0, 10));
  }
  return dates;
}

// The ISO dates covered by ramp week `weekIndex`, counted from `anchor` (see
// rampAnchorDate). Week 0 runs anchor → that week's Sunday; every later week
// is a full Monday–Sunday block after it.
export function rampWeekDates(weekIndex: number, anchor: string): string[] {
  const today = anchor;
  const sundayOfWeekZero = endOfWeekSunday(today);
  const startMs =
    weekIndex === 0
      ? Date.parse(`${today}T00:00:00Z`)
      : Date.parse(`${sundayOfWeekZero}T00:00:00Z`) + (1 + 7 * (weekIndex - 1)) * 86_400_000;
  const endMs =
    weekIndex === 0
      ? Date.parse(`${sundayOfWeekZero}T00:00:00Z`)
      : Date.parse(`${sundayOfWeekZero}T00:00:00Z`) + 7 * weekIndex * 86_400_000;
  if (Number.isNaN(startMs) || Number.isNaN(endMs)) return [];
  const dates: string[] = [];
  for (let ms = startMs; ms <= endMs; ms += 86_400_000) {
    dates.push(new Date(ms).toISOString().slice(0, 10));
  }
  return dates;
}

// Turns a ramp shape + the user's baseline template into the exact
// date-keyed overrides an accept writes. Shared by the proposal preview and
// the accept write so the card can never promise sessions the accept won't
// produce.
//
// Two kinds of day are deliberately skipped:
//   - 100% weeks, because the template ALREADY says that. Writing a
//     redundant override would just add rows that have to expire.
//   - rest days (no exercises), because there is nothing to scale and an
//     override would only rename the user's rest day.
export function materializeRampOverrides(
  days: Record<string, unknown>,
  rampWeeks: ReentryRampWeekInput[],
  today: string,
): Record<string, PlannedWorkoutDayType> {
  const anchor = rampAnchorDate(days, today);
  const overrides: Record<string, PlannedWorkoutDayType> = {};
  rampWeeks.forEach((week, weekIndex) => {
    if (week.intensityPct >= 100) return;
    for (const date of rampWeekDates(weekIndex, anchor)) {
      const baseline = days[weekdayOfISODate(date)];
      if (!isTrainingDay(baseline)) continue;
      overrides[date] = scaleDayToIntensity(baseline as PlannedWorkoutDayType, week.intensityPct);
    }
  });
  return overrides;
}

// Existing future-dated overrides that fall inside the ramp window on dates
// the ramp does NOT itself rewrite. Accepting the ramp clears them, so they
// have to be named on the card: they are content the user approved earlier
// (very often an injury accommodation), and a ramp that silently deleted them
// would put the aggravating movement back on a date nobody re-reviewed.
function rampRemovalDates(
  existingOverrides: Record<string, unknown>,
  rampWeeks: ReentryRampWeekInput[],
  days: Record<string, unknown>,
  today: string,
): string[] {
  const anchor = rampAnchorDate(days, today);
  const windowEnd = rampWeekDates(rampWeeks.length - 1, anchor).at(-1);
  if (!windowEnd) return [];
  const written = materializeRampOverrides(days, rampWeeks, today);
  return Object.keys(existingOverrides)
    .filter((date) => date >= today && date <= windowEnd && !(date in written))
    .sort();
}

function describeRampRemovals(
  existingOverrides: Record<string, unknown>,
  rampWeeks: ReentryRampWeekInput[],
  days: Record<string, unknown>,
  today: string,
): string[] {
  const dates = rampRemovalDates(existingOverrides, rampWeeks, days, today);
  if (dates.length === 0) return [];
  return [
    `Also clears ${dates.length} earlier day adjustment${dates.length === 1 ? "" : "s"} inside this window (${dates.join(", ")}) so the plan can return to normal.`,
  ];
}

// Human-readable, SERVER-GENERATED preview lines for the approval card —
// one per ramp week, naming the real dates and the real sessions. The model
// contributes only the `note`; every number here comes from the user's own
// plan, so the card can show what will actually happen without trusting
// model-authored text.
function describeRampWeeks(
  days: Record<string, unknown>,
  rampWeeks: ReentryRampWeekInput[],
  today: string,
): string[] {
  const anchor = rampAnchorDate(days, today);
  return rampWeeks.map((week, weekIndex) => {
    const dates = rampWeekDates(weekIndex, anchor);
    const span = dates.length > 0 ? `${dates[0]} → ${dates[dates.length - 1]}` : "—";
    if (week.intensityPct >= 100) {
      return `${span}: back to your normal plan — ${week.note}`;
    }
    const sessions = dates
      .filter((date) => isTrainingDay(days[weekdayOfISODate(date)]))
      .map((date) => weekdayOfISODate(date));
    const sessionLabel = sessions.length > 0 ? sessions.join(", ") : "no training days";
    return `${span}: ${week.intensityPct}% of normal (${sessionLabel}) — ${week.note}`;
  });
}

function resolveAppliesToDayKey(category: AdjustmentCategory, dayKey: string | undefined) {
  if (dayKey) return { dayKey };
  if (category === "skip_or_reschedule" || category === "time_limit" || category === "readiness_low") {
    return { dayKey: currentDayKey() };
  }
  return {};
}

function currentDayKey() {
  const weekday = new Intl.DateTimeFormat("en-US", {
    weekday: "short",
    timeZone: "America/New_York",
  }).format(new Date());
  return weekday;
}

// Exported for workouts/rollover.ts, which needs the same "server today"
// definition so a scheduled rollover and a clientDate-less accept agree on
// what date it is.
export function currentDateISO() {
  // en-CA formats as YYYY-MM-DD, matching the ISO date keys dailyOverrides
  // and TrainingProgram.startDate use. Fallback only — clients that send
  // clientDate get their own local date instead.
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York" }).format(new Date());
}

const WEEKDAY_KEYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;

export function weekdayOfISODate(isoDate: string): string {
  const parsed = Date.parse(`${isoDate}T00:00:00Z`);
  if (Number.isNaN(parsed)) return currentDayKey();
  return WEEKDAY_KEYS[new Date(parsed).getUTCDay()];
}

// The ISO date of this week's Sunday (the last day of the user's current
// week), on or after `fromDate`.
export function endOfWeekSunday(fromDate: string): string {
  return nextOccurrenceOfWeekday("Sun", fromDate);
}

// The ISO date of the next occurrence of `dayKey` on or after `fromDate`
// (returns fromDate itself when the weekday matches).
export function nextOccurrenceOfWeekday(dayKey: string, fromDate: string): string {
  const start = Date.parse(`${fromDate}T00:00:00Z`);
  if (Number.isNaN(start)) return fromDate;
  const targetIndex = WEEKDAY_KEYS.indexOf(dayKey as (typeof WEEKDAY_KEYS)[number]);
  if (targetIndex === -1) return fromDate;
  const fromIndex = new Date(start).getUTCDay();
  const daysAhead = (targetIndex - fromIndex + 7) % 7;
  const target = new Date(start + daysAhead * 86_400_000);
  return target.toISOString().slice(0, 10);
}

const SCOPE_LABEL: Record<AdjustmentScope, string> = {
  today: "for that day only",
  rest_of_week: "for the rest of this week",
  going_forward: "going forward",
  reentry_ramp: "as a graded return, stepping back up to normal week by week",
};

// Server-generated text only — deliberately excludes originalUserText,
// which can be model-authored (adapt_plan userNote) and is not shown on
// the approval card. See the laundering note at the accept-time write.
function planChangeMemoryContent(
  proposal: z.infer<typeof PlanAdjustmentProposal>,
  scope: AdjustmentScope | undefined,
): string {
  const dayKey = proposal.appliesTo.dayKey;
  const target = dayKey ? ` (${dayKey})` : "";
  const scopeText = scope ? ` — ${SCOPE_LABEL[scope]}` : "";
  return `Plan change${target}${scopeText} [${proposal.category}]: ${proposal.summary}`;
}

async function loadPlanDay(
  db: Firestore,
  userId: string,
  dayKey: string,
): Promise<PlannedWorkoutDayType | undefined> {
  const planSnap = await db.doc(workoutPlanPath(userId, "current")).get();
  const days = planSnap.exists && isRecord(planSnap.data()?.days) ? (planSnap.data()!.days as Record<string, unknown>) : {};
  const raw = days[dayKey];
  return isRecord(raw) ? (raw as PlannedWorkoutDayType) : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function normalizeExerciseName(value: unknown) {
  return typeof value === "string"
    ? value.trim().toLowerCase().replace(/[^a-z0-9]+/g, " ")
    : "";
}

function classifyPlanAdjustment(content: string, hasWorkoutContext: boolean): AdjustmentCategory | null {
  const text = content.toLowerCase();

  if (matchesAny(text, ["pregnant", "pregnancy", "postpartum", "trimester"])) {
    return "pregnancy_postpartum";
  }
  if (
    matchesAny(text, [
      "hurt",
      "pain",
      "injury",
      "injured",
      "ankle",
      "knee",
      "shoulder",
      "wrist",
      "hip",
      "swollen",
      "sprain",
      // Common injury verbs the list was missing entirely — without them
      // "I strained my back in the gym" had no backstop once the "back"
      // needle was made conditional.
      "strain",
      "tweak",
      "twinge",
      "pulled",
    ]) ||
    mentionsBackAsBodyPart(text)
  ) {
    return "injury_pain";
  }
  if (matchesAny(text, ["hungover", "hangover", "sick", "tired", "fatigue", "exhausted", "sore", "sleep"])) {
    return "readiness_low";
  }
  if (matchesAny(text, ["less time", "shorten", "quick", "only have", "minutes", "minute", "busy"])) {
    return "time_limit";
  }
  if (matchesAny(text, ["skip", "missed", "can't train", "cannot train", "reschedule", "move this", "move it"])) {
    return "skip_or_reschedule";
  }
  if (matchesAny(text, ["travel", "hotel", "airport", "vacation", "on the road"])) {
    return "travel";
  }
  if (matchesAny(text, ["no gym", "no equipment", "dumbbell only", "kettlebell only", "bodyweight", "machine unavailable"])) {
    return "equipment_limit";
  }
  if (matchesAny(text, ["yoga", "pilates", "mobility", "stretch", "conditioning", "cardio", "different style"])) {
    return "style_preference";
  }
  if (matchesAny(text, ["calorie", "protein", "diet", "nutrition", "meal", "cutting", "bulking"])) {
    return "nutrition_context";
  }
  if (hasWorkoutContext && matchesAny(text, ["change", "swap", "adjust", "better", "modify", "replace", "too hard", "too easy"])) {
    return "other";
  }

  return null;
}

// "back" is both a body part and the most natural word for RETURNING to
// training — "get back into it", "easing back into lifting". As a bare
// substring needle it classified every layoff-return message as an injury,
// which locks the proposal at high risk and sends the coach off interrogating
// a pain-free user with red-flag questions.
//
// The disambiguation is deliberately NARROW: only an explicit return VERB
// immediately before "back" counts as the return sense. An earlier attempt
// excused any "back <preposition>" and that silently broke the gate it was
// meant to protect — "I tweaked my back on Monday" and "strained my back in
// the gym" stopped classifying as injuries at all, which would have let a
// genuine back injury through to an auto-appliable ramp.
//
// The asymmetry is the whole point. A false positive costs the user some
// unnecessary triage questions; a false negative puts an injured user's own
// aggravating movement back on the bar. So anything ambiguous stays an
// injury.
// The optional object pronoun is load-bearing. English puts one between the
// verb and "back" constantly — "ease ME back into my routine", "get YOU back
// to lifting" — and without it the phrase that motivated this whole feature
// ("can you ease me back into my normal routine") classified as a BACK INJURY
// and the server refused a perfectly good ramp the model had authored. Caught
// on live staging, not by the unit tests, which only covered the adjacent
// forms. Closed-class list: no real injury report reads "<verb> me back".
const RETURN_IDIOM =
  /\b(?:get|getting|got|ease|easing|work|working|come|coming|jump|jumping|dive|diving|ramp|ramping)\s+(?:me|you|him|her|them|us|myself|yourself|himself|herself|themselves)?\s*back\b/g;

// Markers of an illness the user is still IN, as opposed to one they have
// recovered from and are returning after. Past-tense framings ("I was sick
// last month", "after the flu") are the normal, appliable case — this only
// catches the ongoing ones.
const ACTIVE_ILLNESS =
  /\b(?:still\s+(?:sick|ill|coughing|congested|feverish|recovering)|have\s+(?:a\s+)?fever|running\s+a\s+fever|got\s+(?:a\s+)?fever|fever\b|covid|pneumonia|bronchitis|chest\s+infection|short\s+of\s+breath|can'?t\s+catch\s+my\s+breath)\b/i;

function hasActiveIllnessMarkers(text: string): boolean {
  return ACTIVE_ILLNESS.test(text);
}

function mentionsBackAsBodyPart(text: string): boolean {
  // Strip the return idioms, then ask the plain question of what's left. So
  // "want to get back into it but my back hurts" still reads as an injury on
  // its second "back".
  return /\bback\b/.test(text.replace(RETURN_IDIOM, " "));
}

function matchesAny(text: string, needles: string[]) {
  return needles.some((needle) => text.includes(needle));
}

// The ABSOLUTE severe-symptom screen. Deterministic, server-side, and not
// model-overridable: no triage attestation can clear a text that trips it.
const SEVERE_MARKER_PATTERNS: RegExp[] = [
  /chest pain/,
  /can'?t breathe|cannot breathe|hurts (when|to) .{0,12}breathe/,
  /\bfaint(ed|ing)?\b/,
  /passed out|blacked out/,
  /\bbleeding\b/,
  // \b keeps "lower the NUMBers on squats" from tripping the screen.
  /\bnumb(ness)?\b/,
  /\btingling\b|pins and needles/,
  /lost feeling|can'?t feel|no feeling/,
  /\bdeformity\b|\bdeformed\b/,
  /severe.{0,16}pain|pain.{0,16}severe/,
  /sharp.{0,16}pain|pain.{0,16}sharp/,
  /shooting.{0,16}(pain|down)|pain.{0,16}shooting/,
  /\bradiat(es|ing)\b/,
  // Scoped to body parts so "can't move my Thursday session" stays a
  // plain reschedule request.
  /can'?t move my (arm|leg|neck|back|shoulder|knee|wrist|ankle|hip|hand|foot|toe|finger)/,
  /\bswollen\b|\bswelling\b/,
  /heard a pop|felt a pop|\bgave out\b/,
];

// Negated clauses are masked BEFORE the severe sweep: the natural way a
// user answers triage questions is "no sharp pain, no numbness, nothing
// radiating" — without masking, the symptom words inside those denials
// tripped the screen and permanently locked every honestly-answered triage
// at high risk (live E2E finding, 2026-07-20).
//
// The mask is NegEx-shaped: after a negation word it may consume ONLY
// closed-class connectors, verbs of experiencing, and the symptom
// vocabulary itself. Any other word ends the mask immediately — so
// pseudo-negation intensifiers ("not gonna lie sharp pain", "nothing
// helps the sharp pain", "without warning sharp pain") keep their severe
// report un-masked, while arbitrarily long joint denials ("no numbness or
// tingling or radiating pain", "haven't passed out or felt faint") mask
// fully. The window never crosses newlines or punctuation, so a denial on
// one line can't eat a report on the next ("no numbness\n- sharp pain").
const NEGATION_WORD =
  "(?:no|not|without|nothing|none|never|den(?:y|ies|ied|ying)|don'?t|doesn'?t|didn'?t|haven'?t|hasn'?t|isn'?t|aren'?t|free of)";
// and/or are guarded: a denial list continues with BARE symptom nouns
// ("no numbness or tingling"), while a report resumes with an anaphor
// ("and MY chest pain is back", "and THE pain is sharp") — so and/or
// followed by a determiner ends the mask and the report survives. "my"
// is deliberately absent from the window for the same reason (no denial
// needs it: "no pain in my chest" already clears with the mask stopping
// at "my").
const NEGATION_WINDOW_WORD =
  "(?:(?:and|or)(?![^\\S\\n]+(?:my|the|this|that|it)\\b)|any|of|the|that|this|these|those|a|an|anything|some|more|stuff|other|either|really|ever|even|at|all|in|on|to|had|have|has|having|been|felt|feel|feels|feeling|experienced?|experiencing|noticed?|noticing|getting|got|gotten|symptoms?|issues?|problems?|sharp|shooting|radiat\\w*|numb(?:ness)?|tingl\\w*|pins|needles|pains?|painful|swelling|swollen|bruising|bleeding|faint\\w*|dizz\\w*|severe|chest|deform\\w*|weakness|pop|popping|passed|blacked|out|breath\\w*)";
const NEGATION_CLAUSE = new RegExp(
  `\\b${NEGATION_WORD}\\b(?:[^\\S\\n]+${NEGATION_WINDOW_WORD}\\b)*`,
  "gi",
);

// Severe reports that a negation mask could otherwise eat, screened against
// the raw text BEFORE masking:
// - "no feeling in my foot" / "lost all feeling" / "haven't been able to
//   feel" — severe reports that START with (or contain) a negation word.
//   \bfeeling\b keeps the "no feelings either way" idiom from locking.
// - "never had chest pain like this" — the anaphoric new-onset shape,
//   built entirely from window-maskable words. Textbook cardiac language.
// - "pain this sharp" / "been this swollen" superlatives — severity
//   phrased THROUGH negation. Pain-noun anchors accept this|that; state
//   verbs accept only "this" ("hasn't been THAT swollen lately" and "the
//   pain isn't that sharp anymore" are improvement reports and must stay
//   clear — the recovery arc depends on them). so/too also deliberately
//   excluded ("not so sharp anymore").
const NEGATION_SHAPED_SEVERE =
  /no (?:more )?feeling\b|lost (?:all )?(?:the )?feeling\b|zero feeling\b|no sensation\b|lost sensation\b|can'?t feel\b|(?:unable|not able|n'?t been able) to feel\b|\b(?:pop|pains?|numb(?:ness)?|tingling|swelling|faint(?:ing|ness)?)\b[^.,;\n]{0,24}like (?:this|that)\b|this chest pain\b|(?:pain\w*|hurts?|ach\w*) (?:this|that) (?:sharp|severe|intense|unbearable|excruciating|numb|swollen|faint)\b|(?:it|been|felt|feel|feels|being) this (?:numb|swollen|faint|unbearable|excruciating)\b|(?:pain\w*|hurts?|ach\w*|it)[^.,;\n]{0,16}(?:been|felt|feels?|being) this (?:sharp|severe|intense|unbearable|excruciating)\b|worst pain/;

// A masked denial that CONTAINS a severe phrase and is immediately followed
// by a report-continuation verb is a report resuming with a bare symptom
// noun — "no numbness and chest pain IS back" — not a denial. The mask
// keeps it locked instead of eating it. Denial lists never continue into
// one of these verbs ("no numbness and tingling" just ends), so the only
// cost is conservative ("no numbness or tingling is present" locks).
const REPORT_CONTINUATION =
  /^[^\S\n]*(?:is|was|has|came|got|started|returned|keeps?|won'?t|again)\b/;

export function hasSevereMarkers(content: string): boolean {
  // iOS smart punctuation is on by default — normalize curly apostrophes so
  // "can’t feel" matches the same patterns as "can't feel".
  const lower = content.toLowerCase().replace(/[‘’]/g, "'");
  if (NEGATION_SHAPED_SEVERE.test(lower)) {
    return true;
  }
  let reLock = false;
  const text = lower.replace(NEGATION_CLAUSE, (span, offset: number, whole: string) => {
    if (
      SEVERE_MARKER_PATTERNS.some((pattern) => pattern.test(span)) &&
      REPORT_CONTINUATION.test(whole.slice(offset + span.length))
    ) {
      reLock = true;
    }
    return " ";
  });
  if (reLock) {
    return true;
  }
  return SEVERE_MARKER_PATTERNS.some((pattern) => pattern.test(text));
}

function riskForCategory(category: AdjustmentCategory, content: string): AdjustmentRiskLevel {
  if (hasSevereMarkers(content)) {
    return "high";
  }
  if (category === "injury_pain" || category === "pregnancy_postpartum") return "high";
  if (category === "readiness_low" || category === "nutrition_context") return "medium";
  return "low";
}

// `hasConcretePatch` means the caller supplied model-authored replacement days
// the user can read in full on the card.
//
// equipment_limit and "other" (which is where too_hard / too_easy land) used to
// require follow-up UNCONDITIONALLY, and that made them dead ends: the card
// always said "Coach needs one more detail" and accept always threw
// plan_adjustment_requires_review. No phrasing could get past it. "I don't have
// the ceiling height for overhead press" was understood fine and refused
// anyway.
//
// The rule was correct for the deterministic keyword classifier, which cannot
// invent exercise names (see the comment in maybeCreatePlanAdjustmentProposal).
// It was never revisited when the tool loop arrived. The model CAN author
// concrete substitutions, and a proposal the user reads in full before
// approving is reviewable by definition — which is exactly why the injury path
// and the re-entry ramp are allowed to apply. These two categories just never
// got the same treatment.
//
// Risk is untouched: anything not already low still requires review.
function needsFollowUp(
  category: AdjustmentCategory,
  riskLevel: AdjustmentRiskLevel,
  hasConcretePatch = false,
) {
  if (riskLevel !== "low") return true;
  if (category === "equipment_limit" || category === "other") return !hasConcretePatch;
  return false;
}

function summaryForCategory(category: AdjustmentCategory, exerciseName?: string) {
  const target = exerciseName ? ` for ${exerciseName}` : "";
  const summaries: Record<AdjustmentCategory, string> = {
    time_limit: `User needs a shorter workout option${target}.`,
    equipment_limit: `User needs an equipment-aware workout adjustment${target}.`,
    skip_or_reschedule: "User needs to skip, move, or reschedule training without cramming unsafe volume.",
    readiness_low: "User reported low readiness and needs a conservative training adjustment.",
    style_preference: "User wants a different training style while preserving the week's intent.",
    injury_pain: "User reported pain or injury and needs a safety-first adjustment.",
    pregnancy_postpartum: "User mentioned pregnancy or postpartum context and needs conservative, clinician-aware guidance.",
    travel: "User needs a travel-compatible training adjustment.",
    nutrition_context: "User raised nutrition context that may affect plan targets or recovery guidance.",
    other: `User requested a workout-plan adjustment${target}.`,
  };
  return summaries[category];
}

function rationaleForCategory(category: AdjustmentCategory) {
  const rationales: Record<AdjustmentCategory, string> = {
    time_limit: "Shortening should preserve the highest-value movements and reduce volume before intensity becomes sloppy.",
    equipment_limit: "Equipment constraints should drive substitutions that preserve the intended movement pattern when possible.",
    skip_or_reschedule: "Missed sessions should preserve weekly intent without automatically doubling volume later.",
    readiness_low: "Low readiness calls for reducing load, volume, intensity, or impact before adding work.",
    style_preference: "Style changes can improve adherence if the plan still respects the user's goals and recovery.",
    injury_pain: "Pain reports require avoiding aggravating movements and gathering more context before progressing.",
    pregnancy_postpartum: "Pregnancy and postpartum context requires conservative, clinician-aware boundaries.",
    travel: "Travel plans should use available time, space, and equipment without punishing the user for constraints.",
    nutrition_context: "Nutrition changes should be range-based and constrained by safety context, not strict medical dieting.",
    other: "The user supplied a flexible reason, so MYO should review context before changing the plan.",
  };
  return rationales[category];
}

// No-equipment, no-corpus-knowledge-required fallback used by
// replaceDayFocusPatch below. Deliberately generic and conservative — a
// keyword classifier can't know what specific substitution a real coach
// would pick, so this only ever offers a safe, always-available circuit.
const GENERIC_MOBILITY_CONDITIONING_EXERCISES: PlannedExerciseType[] = [
  { name: "Bodyweight Squat", sets: 3, reps: 15, weight: 0 },
  { name: "Push-Up", sets: 3, reps: 12, weight: 0 },
  { name: "Walking Lunge", sets: 3, reps: 12, weight: 0 },
  { name: "Plank", sets: 3, reps: 30, weight: 0 },
  { name: "Jumping Jacks", sets: 3, reps: 20, weight: 0 },
];

function shortenWorkoutPatch(targetDay: PlannedWorkoutDayType): ProposedPlanPatch {
  const exercises = targetDay.exercises;
  const keepCount = Math.max(1, Math.ceil(exercises.length / 2));
  const removeExercises = exercises.slice(keepCount).map((exercise) => exercise.name);
  return {
    type: "shorten_workout",
    title: "Shorten today's workout",
    changes: [
      `Keep the first ${keepCount} exercise${keepCount === 1 ? "" : "s"} — the highest-value/compound work.`,
      `Drop: ${removeExercises.join(", ")}.`,
    ],
    removeExercises,
    addExercises: [],
  };
}

function replaceDayFocusPatch(targetDay: PlannedWorkoutDayType | undefined, title: string): ProposedPlanPatch {
  return {
    type: "replace_day_focus",
    title,
    changes: [
      "Replace today's exercises with a bodyweight mobility/conditioning circuit.",
      "Keeps the day's training stimulus without needing the original equipment or setting.",
    ],
    replacementDay: {
      name: targetDay ? `${targetDay.name} · Adapted` : "Mobility & Conditioning",
      muscles: targetDay?.muscles ?? [],
      exercises: GENERIC_MOBILITY_CONDITIONING_EXERCISES,
    },
    removeExercises: [],
    addExercises: [],
  };
}

function patchForCategory(
  category: AdjustmentCategory,
  requiresFollowUp: boolean,
  targetDay: PlannedWorkoutDayType | undefined,
): ProposedPlanPatch {
  if (requiresFollowUp) {
    return {
      type: "review_only",
      title: "Ask one follow-up before changing the plan",
      changes: [
        "Keep the current plan unchanged until the missing context is clear.",
        "Use the user's reason, current workout, and safety context to propose a specific edit next.",
      ],
      removeExercises: [],
      addExercises: [],
    };
  }

  if (category === "time_limit") {
    // maybeCreatePlanAdjustmentProposal forces requiresFollowUp when there
    // aren't at least 2 exercises to trim, so targetDay is guaranteed here.
    if (!targetDay || targetDay.exercises.length < 2) {
      throw new Error("plan_adjustment_missing_target_day_for_shorten");
    }
    return shortenWorkoutPatch(targetDay);
  }

  if (category === "skip_or_reschedule") {
    return {
      type: "reschedule_day",
      title: "Preserve the week without cramming",
      changes: [
        "Move or skip the session while protecting recovery.",
        "Do not automatically double the next workout.",
      ],
      removeExercises: [],
      addExercises: [],
    };
  }

  if (category === "style_preference") {
    return replaceDayFocusPatch(targetDay, "Swap the style while preserving intent");
  }

  if (category === "travel") {
    return replaceDayFocusPatch(targetDay, "Travel-compatible workout");
  }

  const reviewOnlyTitles: Partial<Record<AdjustmentCategory, string>> = {
    equipment_limit: "Find equipment-matched substitutions",
    readiness_low: "Reduce intensity for low readiness",
    injury_pain: "Safety-first adjustment",
    pregnancy_postpartum: "Clinician-aware adjustment",
    nutrition_context: "Review nutrition context",
    other: "Review requested change",
  };
  const reviewOnlyChanges: Partial<Record<AdjustmentCategory, string[]>> = {
    equipment_limit: ["Map unavailable equipment to same-pattern alternatives."],
    readiness_low: ["Consider easier load, fewer sets, mobility, walking, or rest."],
    injury_pain: ["Avoid movements that reproduce or worsen symptoms until more context is known."],
    pregnancy_postpartum: ["Keep suggestions conservative and ask about clinician restrictions."],
    nutrition_context: ["Use range-based guidance and avoid medical diet prescriptions."],
    other: ["Turn the user's freeform reason into a specific plan edit after context check."],
  };
  return {
    type: "review_only",
    title: reviewOnlyTitles[category] ?? "Review requested change",
    changes: reviewOnlyChanges[category] ?? ["Review requested change after context check."],
    removeExercises: [],
    addExercises: [],
  };
}

function safetyNotesForCategory(category: AdjustmentCategory, corpusSafetyNotes: string[]) {
  const notes = [...corpusSafetyNotes];
  if (category === "injury_pain") {
    notes.unshift("Do not diagnose injuries or prescribe rehab protocols. Escalate for severe or worsening symptoms.");
  }
  if (category === "pregnancy_postpartum") {
    notes.unshift("Ask about clinician restrictions and avoid high-intensity pregnancy/postpartum prescriptions.");
  }
  if (category === "nutrition_context") {
    notes.unshift("Use estimate ranges, not strict medical nutrition plans.");
  }
  return [...new Set(notes)].slice(0, 6);
}
