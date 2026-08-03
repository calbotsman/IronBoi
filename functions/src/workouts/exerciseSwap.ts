// Swapping one exercise for another that trains the same thing.
//
// Three scopes, because "I don't want to do this move" means three different
// things depending on when it's said:
//
//   session       — mid-workout. Change what's in front of me right now and
//                   leave the plan alone; I'll probably do the real one next
//                   week. Never touches workoutPlans or trainingPrograms.
//   today         — this occurrence only, written as a date-keyed
//                   dailyOverride. Expires on its own (rollover prunes past
//                   dates), so the template is never touched.
//   going_forward — the template day plus every materialized program week
//                   from the active week on. This is "stop programming that
//                   movement for me".
//
// The replacement is validated against the server-side catalog on every path.
// A client cannot name an arbitrary string here and have it land in the
// user's program — see isValidSwap.

import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { z } from "zod";
import {
  ActiveWorkoutSession,
  PlannedExercise,
  PlannedWorkoutDay,
} from "../contracts/coach-agent.js";
import { recordAuditEventBestEffort } from "../audit/log.js";
import { safeLogger } from "../logging/safeLogger.js";
import {
  activeWorkoutPath,
  trainingProgramPath,
  workoutPlanPath,
  workoutSessionPath,
} from "../paths.js";
import {
  CATALOG_EQUIPMENT,
  isValidSwap,
  lookupExercise,
  normalizeExerciseKey,
  suggestSwaps,
  suggestedLoadForSwap,
  type Equipment,
} from "./exerciseCatalog.js";
import { loadBaselines, resolvePrescribedWeight, roundToPlate } from "./exerciseBaselines.js";
import { currentDateISO, nextOccurrenceOfWeekday } from "./planAdjustments.js";
import {
  ensureTrainingProgram,
  parseTrainingProgramDocument,
  syncCurrentWeekSnapshot,
} from "./program.js";

type PlannedWorkoutDayType = z.infer<typeof PlannedWorkoutDay>;
type PlannedExerciseType = z.infer<typeof PlannedExercise>;
type ActiveWorkoutSessionType = z.infer<typeof ActiveWorkoutSession>;

export const GetExerciseSwapOptionsRequest = z.object({
  exerciseName: z.string().min(1),
  dayKey: z.string().min(1).optional(),
  sessionId: z.string().min(1).optional(),
  planId: z.string().min(1).default("current"),
  // Omitted = no equipment constraint. An explicitly EMPTY array means "I
  // have nothing today", which is a real answer and filters to bodyweight.
  availableEquipment: z.array(z.enum(CATALOG_EQUIPMENT)).optional(),
  clientDate: z.string().date().optional(),
  limit: z.number().int().min(1).max(12).default(6),
});

export const SwapExerciseRequest = z.object({
  dayKey: z.string().min(1),
  exerciseName: z.string().min(1),
  replacementName: z.string().min(1),
  scope: z.enum(["session", "today", "going_forward"]),
  sessionId: z.string().min(1).optional(),
  planId: z.string().min(1).default("current"),
  clientDate: z.string().date().optional(),
});

export type GetExerciseSwapOptionsRequestType = z.infer<typeof GetExerciseSwapOptionsRequest>;
export type SwapExerciseRequestType = z.infer<typeof SwapExerciseRequest>;

export type SwapOption = {
  name: string;
  primary: string[];
  secondary: string[];
  equipment: Equipment[];
  reason: string;
  suggestedWeightLb: number;
  // True when suggestedWeightLb came from the user's own anchor for this
  // movement rather than being carried across from the exercise they're
  // replacing. The UI says "your usual" instead of a bare number.
  weightFromBaseline: boolean;
};

export async function getExerciseSwapOptions(
  db: Firestore,
  userId: string,
  request: GetExerciseSwapOptionsRequestType,
): Promise<{ ok: true; exerciseName: string; options: SwapOption[] }> {
  const today = request.clientDate ?? currentDateISO();

  // Everything already in the day is excluded — including the exercise being
  // replaced. Offering a swap to a movement the user is doing three rows
  // down is not an option.
  const contextDay = await loadDayContext(db, userId, request, today);
  const excludeNames = contextDay?.exercises.map((exercise) => exercise.name) ?? [];
  const originalWeight =
    contextDay?.exercises.find(
      (exercise) => normalizeExerciseKey(exercise.name) === normalizeExerciseKey(request.exerciseName),
    )?.weight ?? 0;

  const candidates = suggestSwaps({
    exerciseName: request.exerciseName,
    excludeNames,
    availableEquipment: request.availableEquipment ?? null,
    limit: request.limit,
  });

  const baselines = await loadBaselines(db, userId);
  const options: SwapOption[] = candidates.map((candidate) => {
    const baseline = baselines.get(normalizeExerciseKey(candidate.name));
    const suggested = baseline
      ? resolvePrescribedWeight({ name: candidate.name, weight: 0 }, baselines, today)
      : suggestedLoadForSwap(request.exerciseName, candidate.name, originalWeight);
    return {
      name: candidate.name,
      primary: candidate.primary,
      secondary: candidate.secondary,
      equipment: candidate.equipment,
      reason: candidate.reason,
      suggestedWeightLb: roundToPlate(suggested),
      weightFromBaseline: baseline !== undefined,
    };
  });

  return { ok: true, exerciseName: request.exerciseName, options };
}

// The day the swap is happening in — the live session's exercises when one is
// running, otherwise the plan's resolved day (override beats template, same
// contract as startWorkoutSession).
async function loadDayContext(
  db: Firestore,
  userId: string,
  request: { dayKey?: string; sessionId?: string; planId: string },
  today: string,
): Promise<{ exercises: Array<{ name: string; weight: number }> } | null> {
  if (request.sessionId) {
    const snap = await db.doc(activeWorkoutPath(userId)).get();
    const data = snap.data();
    if (data && data.sessionId === request.sessionId && Array.isArray(data.exercises)) {
      return {
        exercises: data.exercises
          .filter(isRecord)
          .map((exercise) => ({
            name: typeof exercise.name === "string" ? exercise.name : "",
            weight: typeof exercise.targetWeight === "number" ? exercise.targetWeight : 0,
          }))
          .filter((exercise) => exercise.name.length > 0),
      };
    }
  }

  if (!request.dayKey) return null;
  const planSnap = await db.doc(workoutPlanPath(userId, request.planId)).get();
  if (!planSnap.exists) return null;
  const day = resolvePlanDay(planSnap.data(), request.dayKey, today);
  return day ? { exercises: day.exercises } : null;
}

function resolvePlanDay(
  planData: FirebaseFirestore.DocumentData | undefined,
  dayKey: string,
  today: string,
): PlannedWorkoutDayType | null {
  const overrideDate = nextOccurrenceOfWeekday(dayKey, today);
  const overrides = isRecord(planData?.dailyOverrides) ? planData.dailyOverrides : {};
  const override = overrides[overrideDate];
  if (isRecord(override)) {
    const parsed = PlannedWorkoutDay.safeParse(override);
    if (parsed.success) return parsed.data;
  }
  const days = isRecord(planData?.days) ? planData.days : {};
  const parsed = PlannedWorkoutDay.safeParse(days[dayKey]);
  return parsed.success ? parsed.data : null;
}

// Swaps `exerciseName` for `replacementName` in a day's exercise list,
// preserving position, sets and reps. Progression rules do NOT carry over —
// a protocol authored for a barbell press is not a protocol for push-ups.
export function swapInDay(
  day: PlannedWorkoutDayType,
  exerciseName: string,
  replacement: PlannedExerciseType,
): PlannedWorkoutDayType {
  const targetKey = normalizeExerciseKey(exerciseName);
  let replaced = false;
  const exercises = day.exercises.map((exercise) => {
    if (replaced || normalizeExerciseKey(exercise.name) !== targetKey) return exercise;
    replaced = true;
    return replacement;
  });
  if (!replaced) {
    throw new Error("exercise_swap_target_not_in_day");
  }
  return { ...day, exercises };
}

function buildReplacement(
  original: PlannedExerciseType | undefined,
  replacementName: string,
  weightLb: number,
): PlannedExerciseType {
  const entry = lookupExercise(replacementName);
  return PlannedExercise.parse({
    // The catalog's spelling, not the client's. Otherwise "push ups" and
    // "Push-ups" both end up in plans and neither matches a baseline.
    name: entry?.name ?? replacementName,
    sets: original?.sets ?? 3,
    reps: original?.reps ?? 10,
    weight: roundToPlate(weightLb),
  });
}

export async function swapExercise(
  db: Firestore,
  userId: string,
  request: SwapExerciseRequestType,
) {
  if (!isValidSwap(request.exerciseName, request.replacementName)) {
    // Covers all three failures — unknown original, unknown replacement, and
    // a known pair that shares no primary muscle. The client already got a
    // ranked option list; anything outside it is either a stale UI or a
    // hand-rolled call, and neither should reach the plan.
    throw new Error("exercise_swap_not_equivalent");
  }

  const today = request.clientDate ?? currentDateISO();
  const baselines = await loadBaselines(db, userId);
  const replacementKey = normalizeExerciseKey(request.replacementName);
  const anchored = baselines.get(replacementKey);

  const result =
    request.scope === "session"
      ? await swapInSession(db, userId, request, today, anchored?.anchorWeightLb)
      : await swapInPlan(db, userId, request, today, anchored?.anchorWeightLb);

  await recordAuditEventBestEffort(db, {
    userId,
    eventType: "exercise_swapped",
    actor: "user",
    payload: {
      from: request.exerciseName,
      to: request.replacementName,
      scope: request.scope,
      dayKey: request.dayKey,
    },
  });

  safeLogger.info("Exercise swapped", {
    event: "exercise_swapped",
    userId,
    outcome: `${request.scope}_${request.dayKey}`,
  });

  return result;
}

async function swapInSession(
  db: Firestore,
  userId: string,
  request: SwapExerciseRequestType,
  today: string,
  anchorWeightLb: number | undefined,
): Promise<{ ok: true; scope: "session"; activeWorkout: ActiveWorkoutSessionType }> {
  if (!request.sessionId) {
    throw new Error("exercise_swap_session_id_required");
  }

  const activeRef = db.doc(activeWorkoutPath(userId));
  const sessionRef = db.doc(workoutSessionPath(userId, request.sessionId));
  const now = new Date().toISOString();

  const next = await db.runTransaction(async (transaction) => {
    const activeSnap = await transaction.get(activeRef);
    if (!activeSnap.exists) throw new Error("active_workout_not_found");

    const session = ActiveWorkoutSession.parse(stripSessionServerFields(activeSnap.data()));
    if (session.sessionId !== request.sessionId) {
      throw new Error("active_workout_session_mismatch");
    }
    if (session.status !== "active") {
      throw new Error("active_workout_not_active");
    }

    const targetKey = normalizeExerciseKey(request.exerciseName);
    const targetIndex = session.exercises.findIndex(
      (exercise) => normalizeExerciseKey(exercise.name) === targetKey,
    );
    if (targetIndex < 0) throw new Error("exercise_swap_target_not_in_day");

    const target = session.exercises[targetIndex];
    const suggested =
      anchorWeightLb ??
      suggestedLoadForSwap(request.exerciseName, request.replacementName, target.targetWeight);
    const entry = lookupExercise(request.replacementName);
    const replacementName = entry?.name ?? request.replacementName;
    const replacementWeight = roundToPlate(suggested);

    const completedCount = target.completedSets.filter((set) => set.completed).length;
    const replacementExercise = {
      exerciseIndex: 0, // reindexed below
      name: replacementName,
      targetSets: Math.max(target.targetSets - completedCount, 1),
      targetReps: target.targetReps,
      targetWeight: replacementWeight,
      completedSets: Array.from(
        { length: Math.max(target.targetSets - completedCount, 1) },
        (_, setIndex) => ({
          setIndex,
          completed: false,
          reps: target.targetReps,
          weight: replacementWeight,
        }),
      ),
      exerciseDone: false,
    };

    // Sets already logged are history, not a draft. If the user did two sets
    // of bench and then swapped, those two sets HAPPENED — dropping the
    // exercise would erase them from the workout log and from every progress
    // metric built on it. So the original stays, truncated to what was
    // actually completed, and the replacement is inserted after it.
    const nextExercises = completedCount > 0
      ? [
          ...session.exercises.slice(0, targetIndex),
          {
            ...target,
            targetSets: completedCount,
            completedSets: target.completedSets.filter((set) => set.completed),
            exerciseDone: true,
          },
          replacementExercise,
          ...session.exercises.slice(targetIndex + 1),
        ]
      : [
          ...session.exercises.slice(0, targetIndex),
          replacementExercise,
          ...session.exercises.slice(targetIndex + 1),
        ];

    // exerciseIndex is the client's identity for a row (ActiveWorkoutExercise
    // is Identifiable on it). Inserting without reindexing gives two rows the
    // same id, and SwiftUI renders that as one row or none.
    const reindexed = nextExercises.map((exercise, exerciseIndex) => ({
      ...exercise,
      exerciseIndex,
    }));

    const updated = ActiveWorkoutSession.parse({
      ...session,
      exercises: reindexed,
      updatedAt: now,
    });

    for (const ref of [activeRef, sessionRef]) {
      transaction.set(
        ref,
        { ...updated, serverUpdatedAt: FieldValue.serverTimestamp() },
        { merge: true },
      );
    }
    return updated;
  });

  return { ok: true, scope: "session", activeWorkout: next };
}

async function swapInPlan(
  db: Firestore,
  userId: string,
  request: SwapExerciseRequestType,
  today: string,
  anchorWeightLb: number | undefined,
): Promise<{ ok: true; scope: "today" | "going_forward"; dayKey: string }> {
  const scope = request.scope as "today" | "going_forward";
  const planRef = db.doc(workoutPlanPath(userId, request.planId));
  const programRef = db.doc(trainingProgramPath(userId));
  const now = new Date().toISOString();

  // ensureTrainingProgram can itself write (legacy backfill), and Firestore
  // forbids a write before every read inside a transaction — same reason
  // acceptPlanAdjustmentProposal hoists it out.
  if (scope === "going_forward") {
    await ensureTrainingProgram(db, userId);
  }

  await db.runTransaction(async (transaction) => {
    const [planSnap, programSnap] = await Promise.all([
      transaction.get(planRef),
      scope === "going_forward" ? transaction.get(programRef) : Promise.resolve(null),
    ]);
    if (!planSnap.exists) throw new Error("workout_plan_not_found");

    const planData = planSnap.data() ?? {};

    if (scope === "today") {
      const overrideDate = nextOccurrenceOfWeekday(request.dayKey, today);
      const currentDay = resolvePlanDay(planData, request.dayKey, today);
      if (!currentDay) throw new Error("exercise_swap_target_day_not_found");
      const original = currentDay.exercises.find(
        (exercise) =>
          normalizeExerciseKey(exercise.name) === normalizeExerciseKey(request.exerciseName),
      );
      const replacement = buildReplacement(
        original,
        request.replacementName,
        anchorWeightLb ??
          suggestedLoadForSwap(request.exerciseName, request.replacementName, original?.weight ?? 0),
      );
      const patchedDay = swapInDay(currentDay, request.exerciseName, replacement);

      transaction.set(
        planRef,
        {
          dailyOverrides: { [overrideDate]: patchedDay },
          source: "user_edited",
          updatedAt: now,
          serverUpdatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      return;
    }

    // going_forward: the repeating template, and every already-materialized
    // week from the active one on. A template-only edit would be invisible
    // until the program ran off the end of its materialized weeks.
    const days = isRecord(planData.days) ? planData.days : {};
    const parsedDay = PlannedWorkoutDay.safeParse(days[request.dayKey]);
    if (!parsedDay.success) throw new Error("exercise_swap_target_day_not_found");

    const original = parsedDay.data.exercises.find(
      (exercise) =>
        normalizeExerciseKey(exercise.name) === normalizeExerciseKey(request.exerciseName),
    );
    const replacement = buildReplacement(
      original,
      request.replacementName,
      anchorWeightLb ??
        suggestedLoadForSwap(request.exerciseName, request.replacementName, original?.weight ?? 0),
    );
    const patchedDay = swapInDay(parsedDay.data, request.exerciseName, replacement);

    transaction.set(
      planRef,
      {
        days: { [request.dayKey]: patchedDay },
        source: "user_edited",
        updatedAt: now,
        serverUpdatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    if (programSnap?.exists) {
      const program = parseTrainingProgramDocument(programSnap.data());
      const weeks = program.weeks.map((week) => {
        if (week.weekIndex < program.activeWeekIndex) return week;
        const weekDay = PlannedWorkoutDay.safeParse(week.days[request.dayKey]);
        if (!weekDay.success) return week;
        // A week whose day no longer contains the exercise (an earlier
        // adjustment already changed it) is left alone rather than failing
        // the whole swap.
        const hasTarget = weekDay.data.exercises.some(
          (exercise) =>
            normalizeExerciseKey(exercise.name) === normalizeExerciseKey(request.exerciseName),
        );
        if (!hasTarget) return week;
        return {
          ...week,
          days: {
            ...week.days,
            [request.dayKey]: swapInDay(weekDay.data, request.exerciseName, replacement),
          },
        };
      });

      transaction.set(
        programRef,
        {
          weeks,
          source: "user_edited",
          updatedAt: now,
          serverUpdatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    }
  });

  return { ok: true, scope, dayKey: request.dayKey };
}

function stripSessionServerFields(data: FirebaseFirestore.DocumentData | undefined) {
  const raw = data ?? {};
  return {
    userId: raw.userId,
    sessionId: raw.sessionId,
    planId: raw.planId,
    dayKey: raw.dayKey,
    workoutName: raw.workoutName,
    status: raw.status,
    startedAt: raw.startedAt,
    updatedAt: raw.updatedAt,
    completedAt: raw.completedAt,
    exercises: raw.exercises,
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export { syncCurrentWeekSnapshot };
