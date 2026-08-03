import type { DocumentData, Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { z } from "zod";
import {
  ActiveWorkoutExercise,
  ActiveWorkoutSession,
  PlannedWorkoutDay,
  WorkoutLog,
} from "../contracts/coach-agent.js";
import {
  activeWorkoutPath,
  userRoot,
  workoutLogPath,
  workoutPlanPath,
  workoutSessionPath,
} from "../paths.js";
import { nextOccurrenceOfWeekday } from "./planAdjustments.js";
import { normalizeExerciseKey } from "./exerciseCatalog.js";
import {
  baselineDocFor,
  baselineRefFor,
  deriveBaselineSuggestions,
  loadBaselines,
  resolvePrescribedWeight,
} from "./exerciseBaselines.js";

export const StartWorkoutSessionRequest = z.object({
  dayKey: z.string().min(1),
  planId: z.string().min(1).default("current"),
  sessionId: z.string().min(1).optional(),
  startedAt: z.string().datetime().optional(),
  // The client's local calendar date (YYYY-MM-DD) — used to resolve a
  // "today only" dailyOverride for the day being started. Older clients
  // omit it; the session then falls back to startedAt's UTC date.
  clientDate: z.string().date().optional(),
});

export const FinishWorkoutSessionRequest = z.object({
  sessionId: z.string().min(1),
  completedAt: z.string().datetime(),
  durationSec: z.number().int().nonnegative().optional(),
  perceivedEffort: z.number().min(1).max(10).optional(),
  postSessionNotes: z.string().optional(),
  exercises: z.array(ActiveWorkoutExercise),
});

type StartWorkoutSessionRequest = z.infer<typeof StartWorkoutSessionRequest>;
type FinishWorkoutSessionRequest = z.infer<typeof FinishWorkoutSessionRequest>;

const POUNDS_TO_KG = 0.45359237;

export async function startWorkoutSession(
  db: Firestore,
  userId: string,
  request: StartWorkoutSessionRequest,
  defaultPlan: Record<string, unknown>,
) {
  const now = new Date().toISOString();
  const startedAt = request.startedAt ?? now;
  const sessionId =
    request.sessionId ?? `${startedAt.slice(0, 10)}_${request.dayKey.toLowerCase()}`;
  const sessionDate = request.clientDate ?? startedAt.slice(0, 10);
  const dayPlan = await loadWorkoutDay(
    db,
    userId,
    request.planId,
    request.dayKey,
    sessionDate,
    defaultPlan,
  );

  // The prescription is DERIVED, not read straight off the plan: an exercise
  // the user has rebaselined starts from their own anchor, advanced by
  // whatever progression protocol the plan carries. With no baseline (every
  // user before this feature) resolvePrescribedWeight returns the plan's own
  // weight, so nothing changes for them.
  const baselines = await loadBaselines(db, userId);
  const activeWorkout = ActiveWorkoutSession.parse({
    userId,
    sessionId,
    planId: request.planId,
    dayKey: request.dayKey,
    workoutName: dayPlan.name,
    status: "active",
    startedAt,
    updatedAt: now,
    exercises: dayPlan.exercises.map((exercise, exerciseIndex) => {
      const targetWeight = resolvePrescribedWeight(exercise, baselines, sessionDate);
      return {
        exerciseIndex,
        name: exercise.name,
        targetSets: exercise.sets,
        targetReps: exercise.reps,
        targetWeight,
        completedSets: Array.from({ length: exercise.sets }, (_, setIndex) => ({
          setIndex,
          completed: false,
          reps: exercise.reps,
          weight: targetWeight,
        })),
        exerciseDone: false,
      };
    }),
  });

  // Seed an anchor for anything the plan wants to progress but that has none
  // yet. Without this, a coach-authored protocol ("add 5 lb a week") would
  // never move until the user happened to change a weight by hand — there
  // would be no anchor for progression to measure from. Narrow by design:
  // only exercises that carry a progression rule AND a real load, and the
  // seeded anchor equals what the plan already said, so nothing the user
  // sees changes on the day it is written.
  await seedMissingProgressionBaselines(db, userId, dayPlan.exercises, baselines, sessionDate, now);

  await Promise.all([
    db.doc(activeWorkoutPath(userId)).set({
      ...activeWorkout,
      serverUpdatedAt: FieldValue.serverTimestamp(),
    }),
    db.doc(workoutSessionPath(userId, sessionId)).set({
      ...activeWorkout,
      serverUpdatedAt: FieldValue.serverTimestamp(),
    }),
  ]);

  return activeWorkout;
}

export async function finishWorkoutSession(
  db: Firestore,
  userId: string,
  request: FinishWorkoutSessionRequest,
) {
  const activeRef = db.doc(activeWorkoutPath(userId));
  const sessionRef = db.doc(workoutSessionPath(userId, request.sessionId));
  const [activeSnap, sessionSnap] = await Promise.all([activeRef.get(), sessionRef.get()]);
  const source = (activeSnap.exists ? activeSnap.data() : sessionSnap.data()) ?? {};

  const workoutName =
    stringOr(source.workoutName, `Workout ${request.completedAt.slice(0, 10)}`);
  const startedAt = stringOr(source.startedAt, request.completedAt);
  const dayKey = stringOr(source.dayKey, "Workout");
  const completedExercises = request.exercises.map((exercise) => ({
    ...exercise,
    exerciseDone:
      exercise.exerciseDone || exercise.completedSets.some((set) => set.completed),
  }));

  const log = WorkoutLog.parse({
    userId,
    sessionId: request.sessionId,
    date: request.completedAt.slice(0, 10),
    source: "manual",
    exercises: completedExercises.map((exercise) => ({
      name: exercise.name,
      // Keys are OMITTED rather than set to undefined. The admin SDK is
      // initialized without ignoreUndefinedProperties (functions/src/firebase.ts),
      // so Firestore REJECTS an undefined value outright — meaning a bodyweight
      // set (no loadKg) or an exercise with no notes made the whole
      // finishWorkoutSession write throw, and the user could not finish their
      // workout at all. Zod keeps optional keys whose value is explicitly
      // undefined, so the object handed to .set() has to be built without them.
      sets: exercise.completedSets
        .filter((set) => set.completed)
        .map((set) => {
          const loadKg =
            set.weight && set.weight > 0
              ? Math.round(set.weight * POUNDS_TO_KG * 10) / 10
              : undefined;
          return {
            reps: set.reps ?? exercise.targetReps,
            ...(loadKg !== undefined ? { loadKg } : {}),
            ...(exercise.notes !== undefined ? { notes: exercise.notes } : {}),
          };
        }),
    })),
    durationSec: request.durationSec,
    perceivedEffort: request.perceivedEffort,
    postSessionNotes: request.postSessionNotes ?? `${dayKey}: ${workoutName}`,
    createdAt: request.completedAt,
  });

  const completedSession = ActiveWorkoutSession.parse({
    userId,
    sessionId: request.sessionId,
    planId: stringOr(source.planId, "current"),
    dayKey,
    workoutName,
    status: "completed",
    startedAt,
    updatedAt: request.completedAt,
    completedAt: request.completedAt,
    exercises: completedExercises,
  });

  await Promise.all([
    activeRef.set(
      {
        ...completedSession,
        serverUpdatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    ),
    sessionRef.set(
      {
        ...completedSession,
        serverUpdatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    ),
    db.doc(workoutLogPath(userId, request.sessionId)).set({
      ...log,
      serverRecordedAt: FieldValue.serverTimestamp(),
    }),
  ]);

  // Proposed, NOT applied. The user asked to be asked: finishing surfaces a
  // card listing what changed, and nothing moves until they tap Apply
  // (applyExerciseBaselines). Returning suggestions from the same call the
  // client already makes avoids a second round trip on the finish screen.
  const baselineSuggestions = deriveBaselineSuggestions(completedExercises);

  return { activeWorkout: completedSession, workoutLog: log, baselineSuggestions };
}

async function seedMissingProgressionBaselines(
  db: Firestore,
  userId: string,
  exercises: Array<{ name: string; weight: number; progression?: { mode: string } }>,
  baselines: Awaited<ReturnType<typeof loadBaselines>>,
  anchorDate: string,
  now: string,
) {
  const missing = exercises.filter(
    (exercise) =>
      exercise.progression !== undefined &&
      exercise.progression.mode !== "none" &&
      exercise.weight > 0 &&
      !baselines.has(normalizeExerciseKey(exercise.name)),
  );
  if (missing.length === 0) return;

  const batch = db.batch();
  for (const exercise of missing) {
    batch.set(
      baselineRefFor(db, userId, exercise.name),
      {
        ...baselineDocFor(userId, exercise.name, exercise.weight, anchorDate, "plan_seed", now),
        serverUpdatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  }
  await batch.commit();
}

async function loadWorkoutDay(
  db: Firestore,
  userId: string,
  planId: string,
  dayKey: string,
  sessionDate: string,
  defaultPlan: Record<string, unknown>,
) {
  const planSnap = await db.doc(workoutPlanPath(userId, planId)).get();
  const planData = planSnap.exists ? planSnap.data() : undefined;

  // Resolution contract (contracts/coach-agent.ts WorkoutPlan): a
  // dailyOverride for the requested day's date wins over the weekday
  // template. Without this, a "just today" plan adjustment shows on the
  // Train tab but the started session silently loads the original full day.
  // The lookup targets the next occurrence of the REQUESTED dayKey (which
  // is sessionDate itself when starting today's workout), so starting a
  // different day early can't accidentally pick up today's override.
  const overrideDate = nextOccurrenceOfWeekday(dayKey, sessionDate);
  const override = readDay(planData?.dailyOverrides, overrideDate);
  if (override) {
    return PlannedWorkoutDay.parse(override);
  }

  const planDays = planSnap.exists ? planData?.days : defaultPlan;
  const dayData = readDay(planDays, dayKey) ?? readFirstWorkoutDay(planDays);
  return PlannedWorkoutDay.parse(dayData);
}

function readDay(planDays: unknown, dayKey: string): DocumentData | undefined {
  if (!planDays || typeof planDays !== "object") return undefined;
  const days = planDays as Record<string, DocumentData>;
  return days[dayKey];
}

function readFirstWorkoutDay(planDays: unknown): DocumentData | undefined {
  if (!planDays || typeof planDays !== "object") return undefined;
  return Object.values(planDays as Record<string, DocumentData>).find(
    (day) => Array.isArray(day?.exercises) && day.exercises.length > 0,
  );
}

function stringOr(value: unknown, fallback: string) {
  return typeof value === "string" && value.length > 0 ? value : fallback;
}

