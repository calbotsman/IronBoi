import { randomUUID } from "node:crypto";
import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { z } from "zod";
import {
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
  memoryFactPath,
  planAdjustmentProposalPath,
  profilePath,
  trainingProgramPath,
  workoutPlanPath,
} from "../paths.js";
import { ensureTrainingProgram, parseTrainingProgramDocument, type TrainingProgramType } from "./program.js";

export const AcceptPlanAdjustmentProposalRequest = z.object({
  proposalId: z.string().min(1),
  decidedAt: z.string().datetime().optional(),
  // Chosen at accept time by the iOS proposal card (or, for a future
  // LLM-driven proposal, may already be set on the proposal itself — see
  // `appliesTo.scope`). Falls back to the proposal's own scope, then to
  // the pre-scope legacy behavior when neither is set.
  scope: PlanAdjustmentScope.optional(),
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

export async function createPlanAdjustmentProposalFromTool(input: {
  db: Firestore;
  userId: string;
  reason: keyof typeof ADAPT_PLAN_REASON_TO_CATEGORY;
  userNote?: string;
  dayKey?: string;
  exerciseName?: string;
  scope?: AdjustmentScope;
}) {
  const category = ADAPT_PLAN_REASON_TO_CATEGORY[input.reason];
  const originalUserText = input.userNote?.trim() || `User requested a plan change (${input.reason}) via chat.`;
  const riskLevel = riskForCategory(category, originalUserText);
  let requiresFollowUp = needsFollowUp(category, riskLevel);
  const appliesTo = {
    planId: "current",
    ...resolveAppliesToDayKey(category, input.dayKey),
    ...(input.exerciseName ? { exerciseName: input.exerciseName } : {}),
    ...(input.scope ? { scope: input.scope } : {}),
  };

  let targetDay: PlannedWorkoutDayType | undefined;
  if (!requiresFollowUp && appliesTo.dayKey) {
    targetDay = await loadPlanDay(input.db, input.userId, appliesTo.dayKey);
    if (category === "time_limit" && (targetDay?.exercises.length ?? 0) < 2) {
      requiresFollowUp = true;
    }
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
  });

  return {
    ...persisted,
    // The model should ask "just today, or going forward?" before calling
    // adapt_plan again — unless this proposal needs a different follow-up
    // anyway (requiresFollowUp), in which case scope is moot for now.
    needsScopeConfirmation: !requiresFollowUp && input.scope === undefined,
  };
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
    summary: summaryForCategory(input.category, input.appliesTo.exerciseName),
    rationale: rationaleForCategory(input.category),
    appliesTo: input.appliesTo,
    proposedPlanPatch: patchForCategory(input.category, input.requiresFollowUp, input.targetDay),
    sourceCorpusEntryIds: retrievedCorpus.map((entry) => entry.entryId),
    safetyNotes: safetyNotesForCategory(input.category, retrievedCorpus.flatMap((entry) => entry.safetyBoundaries)),
    requiresFollowUp: input.requiresFollowUp,
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

  // Firestore transactions require all reads before any write, and
  // ensureTrainingProgram may itself need to write a backfilled doc — so it
  // has to run before the transaction opens, not inside it.
  await ensureTrainingProgram(db, userId);

  await db.runTransaction(async (transaction) => {
    const [proposalSnap, planSnap, programSnap] = await Promise.all([
      transaction.get(proposalRef),
      transaction.get(planRef),
      transaction.get(programRef),
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

    const scope = request.scope ?? proposal.appliesTo.scope;
    const program = parseTrainingProgramDocument(programSnap.data());
    const { planPatch, programPatch } = planPatchForAcceptedProposal(
      proposal,
      planSnap.data() ?? {},
      program,
      scope,
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
        // (and Phase D's plan-change memory) know how far this reached
        // without having to re-derive it.
        ...(scope !== undefined ? { "appliesTo.scope": scope } : {}),
        serverDecidedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    // Record what changed and why, so a later coach turn can reference it
    // ("since we shortened Tuesday's session...") instead of re-asking.
    // Written `confirmed` (not `proposed`, unlike upsertMemoryFact's default
    // for coach_inferred facts) because the user already explicitly
    // approved this exact change by accepting the proposal — a second
    // confirmation step would just be redundant friction.
    const memoryFactRef = db.doc(memoryFactPath(userId, `plan_change_${proposal.proposalId}`));
    transaction.set(memoryFactRef, {
      userId,
      factId: `plan_change_${proposal.proposalId}`,
      category: "plan_change",
      content: planChangeMemoryContent(proposal, scope),
      source: "coach_inferred",
      confidence: 1,
      state: "confirmed",
      evidenceExcerpt: proposal.originalUserText.slice(0, 500),
      lastConfirmedAt: serverDecidedAt,
      createdAt: serverDecidedAt,
      lastReinforcedAt: serverDecidedAt,
      userEditable: true,
    });
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
    let exercises = currentDay.exercises;
    if (patch.removeExercises.length > 0) {
      const removeSet = new Set(patch.removeExercises.map(normalizeExerciseName));
      exercises = exercises.filter((exercise) => !removeSet.has(normalizeExerciseName(exercise.name)));
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

// Rebuilds the full `weeks` array with `dayKey` patched in the scoped set
// of weeks. Firestore can't merge inside an array element, so the whole
// array has to be reconstructed and written back.
function patchProgramWeeks(
  program: TrainingProgramType,
  dayKey: string,
  patchedDay: PlannedWorkoutDayType,
  reach: "active_week_only" | "active_week_and_forward",
): { weeks: TrainingProgramType["weeks"] } {
  const weeks = program.weeks.map((week) => {
    const inScope =
      reach === "active_week_and_forward"
        ? week.weekIndex >= program.activeWeekIndex
        : week.weekIndex === program.activeWeekIndex;
    if (!inScope) return week;
    return { ...week, days: { ...week.days, [dayKey]: patchedDay } };
  });
  return { weeks };
}

function planPatchForAcceptedProposal(
  proposal: z.infer<typeof PlanAdjustmentProposal>,
  plan: Record<string, unknown>,
  program: TrainingProgramType,
  scope: AdjustmentScope | undefined,
): { planPatch: Record<string, unknown>; programPatch?: Record<string, unknown> } {
  const days = isRecord(plan.days) ? plan.days : {};
  const dayKey = proposal.appliesTo.dayKey ?? currentDayKey();
  const currentDay = isRecord(days[dayKey]) ? (days[dayKey] as PlannedWorkoutDayType) : undefined;
  const patchedDay = computePatchedDay(proposal.proposedPlanPatch, currentDay);

  if (scope === "today") {
    const dailyOverrides = isRecord(plan.dailyOverrides) ? plan.dailyOverrides : {};
    return {
      planPatch: {
        dailyOverrides: { ...dailyOverrides, [currentDateISO()]: patchedDay },
      },
    };
  }

  if (scope === "rest_of_week") {
    return {
      planPatch: { days: { ...days, [dayKey]: patchedDay } },
      programPatch: patchProgramWeeks(program, dayKey, patchedDay, "active_week_only"),
    };
  }

  if (scope === "going_forward") {
    return {
      planPatch: { days: { ...days, [dayKey]: patchedDay } },
      programPatch: patchProgramWeeks(program, dayKey, patchedDay, "active_week_and_forward"),
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

function currentDateISO() {
  // en-CA formats as YYYY-MM-DD, matching the ISO date keys dailyOverrides
  // and TrainingProgram.startDate use.
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York" }).format(new Date());
}

const SCOPE_LABEL: Record<AdjustmentScope, string> = {
  today: "for today only",
  rest_of_week: "for the rest of this week",
  going_forward: "going forward",
};

function planChangeMemoryContent(
  proposal: z.infer<typeof PlanAdjustmentProposal>,
  scope: AdjustmentScope | undefined,
): string {
  const dayKey = proposal.appliesTo.dayKey;
  const target = dayKey ? ` (${dayKey})` : "";
  const scopeText = scope ? ` — ${SCOPE_LABEL[scope]}` : "";
  return `Plan change${target}${scopeText}: ${proposal.summary} Reason: "${proposal.originalUserText}".`;
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

function riskForCategory(category: AdjustmentCategory, content: string): AdjustmentRiskLevel {
  const text = content.toLowerCase();
  if (
    matchesAny(text, [
      "chest pain",
      "can't breathe",
      "cannot breathe",
      "faint",
      "fainted",
      "bleeding",
      "numb",
      "deformity",
      "severe pain",
    ])
  ) {
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
