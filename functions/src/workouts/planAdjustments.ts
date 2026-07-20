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
  "too_hard" | "too_easy" | "pain_or_discomfort" | "time_constraint" | "equipment_unavailable" | "schedule_change" | "missed_session",
  AdjustmentCategory
> = {
  too_hard: "other",
  too_easy: "other",
  pain_or_discomfort: "injury_pain",
  time_constraint: "time_limit",
  equipment_unavailable: "equipment_limit",
  schedule_change: "skip_or_reschedule",
  missed_session: "skip_or_reschedule",
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
  const rawSaysInjury =
    rawText.length > 0 &&
    (classifyPlanAdjustment(rawText, false) === "injury_pain" || hasSevereMarkers(rawText));
  const category = rawSaysInjury ? "injury_pain" : ADAPT_PLAN_REASON_TO_CATEGORY[input.reason];
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
  let requiresFollowUp = needsFollowUp(category, riskLevel);
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
    ...resolveAppliesToDayKey(category, input.dayKey ?? input.dayPatches?.[0]?.dayKey),
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

  // Model-authored multi-day patch: build the proposal content directly
  // from the (Zod-validated, bounded) replacement days.
  // rest_of_week means THROUGH SUNDAY of the user's current week. Patches
  // whose next occurrence would wrap into next week (Mon/Tue patched on a
  // Wednesday) are dropped — showing them as "this week" would be false.
  const referenceDate = input.clientDate ?? currentDateISO();
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

  // Revise flow: the new proposal replaces whatever pending one the user
  // was looking at ("actually make Friday lighter instead") — cards swap
  // instead of stacking, and stale pendings can't be accepted later.
  // Runs AFTER persist so a persist failure can't destroy the old card
  // with nothing to replace it. The count goes back to the model so it can
  // acknowledge the swap ("this replaces the earlier suggestion").
  const supersededProposalIds = await supersedePendingProposals(
    input.db,
    input.userId,
    persisted.proposalId,
  );

  return {
    ...persisted,
    supersededCount: supersededProposalIds.length,
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
  const supersededProposalIds = await supersedePendingProposals(
    input.db,
    input.userId,
    persisted.proposalId,
  );
  return { ...persisted, supersededCount: supersededProposalIds.length };
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

// Transactional so a concurrent card-tap accept can't be overwritten:
// the accept transaction re-reads decision=="pending", and this transaction
// only flips docs that are still pending at its own read time — whichever
// commits second sees the other's write and behaves correctly.
async function supersedePendingProposals(
  db: Firestore,
  userId: string,
  excludeProposalId?: string,
): Promise<string[]> {
  const query = db
    .collection(planAdjustmentProposalsCollectionPath(userId))
    .where("decision", "==", "pending");
  const now = new Date().toISOString();
  return db.runTransaction(async (transaction) => {
    const snap = await transaction.get(query);
    const superseded: string[] = [];
    for (const doc of snap.docs) {
      if (doc.id === excludeProposalId) continue;
      transaction.set(
        doc.ref,
        { decision: "superseded", decidedAt: now, serverDecidedAt: FieldValue.serverTimestamp() },
        { merge: true },
      );
      superseded.push(doc.id);
    }
    return superseded;
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
const EXPIRY_SCAN_LIMIT = 200;

export async function expireStalePendingProposals(db: Firestore, nowISO?: string) {
  const now = nowISO ?? new Date().toISOString();
  const cutoff = new Date(Date.parse(now) - PENDING_PROPOSAL_TTL_MS).toISOString();
  const stale = await db
    .collectionGroup("planAdjustmentProposals")
    .where("decision", "==", "pending")
    .where("createdAt", "<", cutoff)
    .limit(EXPIRY_SCAN_LIMIT)
    .get();

  let expired = 0;
  let failed = 0;
  for (const doc of stale.docs) {
    try {
      // Transactional per-doc flip: only a doc STILL pending at the
      // transaction's own read time gets expired — a concurrent card-tap
      // accept that commits first wins, same discipline as supersede/reject.
      const flipped = await db.runTransaction(async (transaction) => {
        const snap = await transaction.get(doc.ref);
        if (!snap.exists || snap.get("decision") !== "pending") return false;
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

  safeLogger.info("Stale pending plan adjustment proposals expired", {
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
    decision: "pending",
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
      // A permanent change must WIN immediately: prune any still-active
      // temporary override on the patched days, or the Train tab keeps
      // showing old override content for up to a week after approval.
      const existingOverrides = isRecord(plan.dailyOverrides) ? plan.dailyOverrides : {};
      const patchedDates = new Set(
        contractDayPatches.map((patch) => nextOccurrenceOfWeekday(patch.dayKey, today)),
      );
      const overridePrune = Object.fromEntries(
        Object.keys(existingOverrides)
          .filter((date) => patchedDates.has(date))
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
    return {
      planPatch: { days: { ...days, [dayKey]: patchedDay } },
      programPatch: patchProgramWeeks(program, dayKey, patchedDay),
    };
  }

  // Legacy/no-scope callers (workout-detail sheet, older clients): keep the
  // pre-scope behavior byte-for-byte — in-place patch on the template day
  // only, no dailyOverrides, no program write.
  return { planPatch: { days: { ...days, [dayKey]: patchedDay } } };
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
  if (matchesAny(text, [
    "hurt",
    "pain",
    "injury",
    "injured",
    "ankle",
    "knee",
    "shoulder",
    "back",
    "wrist",
    "hip",
    "swollen",
    "sprain",
  ])) {
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
// at high risk (live E2E finding, 2026-07-20). The mask is deliberately
// narrow — the negation word plus at most 4 following words, stopping at
// any punctuation or contrast word — so a severe report AFTER a denial
// ("no numbness but shooting pain down my leg", "no other symptoms. the
// pain is shooting") keeps its severe phrase un-masked. Coordination
// words (and/or) are NOT stoppers: "no numbness or tingling" is one
// joint denial.
const NEGATION_CLAUSE =
  /\b(?:no|not|without|nothing|none|never|denies?|denied|don'?t|doesn'?t|didn'?t|haven'?t|hasn'?t|isn'?t|aren'?t|free of)\b(?:\s+(?!(?:but|however|though|except|yet)\b)[a-z'-]+){0,4}/gi;

// "no feeling in my leg" is itself a severe report, not a denial - the one
// severe marker family that STARTS with a negation word. Screen it against
// the raw text BEFORE masking so the negation pass cannot eat it.
const NEGATION_SHAPED_SEVERE = /no feeling|lost feeling|can'?t feel/;

export function hasSevereMarkers(content: string): boolean {
  const lower = content.toLowerCase();
  if (NEGATION_SHAPED_SEVERE.test(lower)) {
    return true;
  }
  const text = lower.replace(NEGATION_CLAUSE, " ");
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

function needsFollowUp(category: AdjustmentCategory, riskLevel: AdjustmentRiskLevel) {
  return riskLevel !== "low" || category === "equipment_limit" || category === "other";
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
