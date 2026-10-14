import { randomUUID } from "node:crypto";
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
  profilePath,
  userRoot,
  workoutLogPath,
  workoutPlanPath,
  workoutSessionPath,
} from "../paths.js";
import { nextOccurrenceOfWeekday } from "./planAdjustments.js";
import {
  buildWorkoutRecap,
  nextPlannedDay,
  previousBests,
  trimToStarter,
  type WorkoutRecap,
} from "../journey/recap.js";
import { writeGeneralCoachMessage } from "../journey/messages.js";
import { safeLogger } from "../logging/safeLogger.js";
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
  // The app asks for the first-ever session as a short starter. Honoured
  // only while the user has no finished workout, so it can't be used to
  // trim a normal day.
  starter: z.boolean().optional(),
});

export const FinishWorkoutSessionRequest = z.object({
  sessionId: z.string().min(1),
  completedAt: z.string().datetime(),
  durationSec: z.number().int().nonnegative().optional(),
  perceivedEffort: z.number().min(1).max(10).optional(),
  postSessionNotes: z.string().optional(),
  exercises: z.array(ActiveWorkoutExercise),
  // The client's local date, for "next up: Thursday" in the recap.
  clientDate: z.string().date().optional(),
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
  // A random tail: date + day alone collided (doing a day twice, or a
  // late-evening session landing on the next UTC date), and the second
  // finish overwrote the first workout's log.
  const sessionId =
    request.sessionId ??
    `${startedAt.slice(0, 10)}_${request.dayKey.toLowerCase()}_${randomUUID().slice(0, 8)}`;
  const sessionDate = request.clientDate ?? startedAt.slice(0, 10);
  const { day: plannedDay, fromOverride, planDays } = await loadWorkoutDay(
    db,
    userId,
    request.planId,
    request.dayKey,
    sessionDate,
    defaultPlan,
  );
  const dayPlan =
    request.starter && !fromOverride && !(await hasFinishedWorkout(db, userId))
      ? trimToStarter(plannedDay)
      : plannedDay;

  // The prescription is DERIVED, not read straight off the plan: an exercise
  // the user has rebaselined starts from their own anchor, advanced by
  // whatever progression protocol the plan carries. With no baseline (every
  // user before this feature) resolvePrescribedWeight returns the plan's own
  // weight, so nothing changes for them.
  //
  // EXCEPT for a dated dailyOverride: that is a specific adjustment the user
  // approved (a ramp week at 50%, a back-safe substitution) and it is served
  // exactly as approved — anchors and progression do not apply to it, and it
  // never seeds an anchor, or a 50% ramp week would become the baseline.
  const baselines = fromOverride ? new Map() : await loadBaselines(db, userId);
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
  if (!fromOverride) {
    await seedMissingProgressionBaselines(
      db, userId, dayPlan.exercises, baselines, sessionDate, now, ambiguousLifts(planDays),
    );
  }

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

export const AbandonWorkoutSessionRequest = z.object({
  sessionId: z.string().min(1),
});
export type AbandonWorkoutSessionRequest = z.infer<typeof AbandonWorkoutSessionRequest>;

/**
 * Throws away an unfinished session — a workout started and never finished,
 * often days ago. Marks it abandoned (the app treats only `active` as live)
 * and writes no workout log, so it never counts toward history or progress.
 * A session that already finished is left alone.
 */
export async function abandonWorkoutSession(
  db: Firestore,
  userId: string,
  request: AbandonWorkoutSessionRequest,
) {
  const activeRef = db.doc(activeWorkoutPath(userId));
  const sessionRef = db.doc(workoutSessionPath(userId, request.sessionId));
  const activeSnap = await activeRef.get();
  const now = new Date().toISOString();
  const patch = { status: "abandoned", updatedAt: now, serverUpdatedAt: FieldValue.serverTimestamp() };
  const writes: Promise<unknown>[] = [];
  if (activeSnap.get("sessionId") === request.sessionId && activeSnap.get("status") === "active") {
    writes.push(activeRef.set(patch, { merge: true }));
  }
  const sessionSnap = await sessionRef.get();
  if (sessionSnap.exists && sessionSnap.get("status") === "active") {
    writes.push(sessionRef.set(patch, { merge: true }));
  }
  await Promise.all(writes);
  return { abandoned: writes.length > 0 };
}

export async function finishWorkoutSession(
  db: Firestore,
  userId: string,
  request: FinishWorkoutSessionRequest,
) {
  const activeRef = db.doc(activeWorkoutPath(userId));
  const sessionRef = db.doc(workoutSessionPath(userId, request.sessionId));
  const [activeSnap, sessionSnap, priorLogs] = await Promise.all([
    activeRef.get(),
    sessionRef.get(),
    loadPriorLogs(db, userId, request.sessionId),
  ]);
  const source = (activeSnap.exists ? activeSnap.data() : sessionSnap.data()) ?? {};

  const workoutName =
    stringOr(source.workoutName, `Workout ${request.completedAt.slice(0, 10)}`);
  const startedAt = stringOr(source.startedAt, request.completedAt);
  const dayKey = stringOr(source.dayKey, "Workout");
  const duration = sessionDuration(request.durationSec, startedAt, request.completedAt);
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
    // The app doesn't send a duration: the time from start to finish is it,
    // unless that's implausible (a session left open overnight).
    ...(duration !== undefined ? { durationSec: duration } : {}),
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

  const recap = await recapFinishedWorkout(db, userId, request, completedExercises, startedAt, priorLogs);

  return { activeWorkout: completedSession, workoutLog: log, baselineSuggestions, recap };
}

/**
 * The end of a workout says something: what you did, one thing noticed, what's
 * next — written into the conversation so it stays in history, and returned
 * so the app can say it straight away. Best-effort: the workout is already
 * saved, so a failure here costs the recap, never the workout.
 */
async function recapFinishedWorkout(
  db: Firestore,
  userId: string,
  request: FinishWorkoutSessionRequest,
  exercises: FinishWorkoutSessionRequest["exercises"],
  startedAt: string,
  priorLogs: Array<Record<string, unknown>> | undefined,
): Promise<WorkoutRecap | undefined> {
  // Couldn't read history: no recap rather than calling a regular's
  // workout their "starting point".
  if (!priorLogs) return undefined;
  try {
    const firstWorkout = priorLogs.length === 0;
    const planSnap = await db.doc(workoutPlanPath(userId, "current")).get();
    const elapsed = (Date.parse(request.completedAt) - Date.parse(startedAt)) / 1000;
    const recap = buildWorkoutRecap({
      exercises,
      previous: previousBests(priorLogs),
      firstWorkout,
      durationSec: request.durationSec ?? (Number.isFinite(elapsed) ? Math.round(elapsed) : undefined),
      nextDay: nextPlannedDay(planSnap.get("days"), request.clientDate ?? request.completedAt.slice(0, 10)),
    });
    const now = new Date().toISOString();
    await Promise.all([
      writeGeneralCoachMessage(db, userId, `recap_${request.sessionId}`, recap.lines.join(" "), now),
      firstWorkout
        ? db.doc(profilePath(userId)).set({ firstWorkoutAt: request.completedAt }, { merge: true })
        : Promise.resolve(),
    ]);
    return recap;
  } catch (error) {
    safeLogger.warn("Workout recap failed", {
      event: "workout_recap_failed",
      userId,
      errorDetail: error instanceof Error ? error.message.slice(0, 200) : "unknown_error",
    });
    return undefined;
  }
}

/** Earlier finished workouts, newest first — what this one is compared with. */
async function loadPriorLogs(db: Firestore, userId: string, sessionId: string) {
  try {
    const snap = await db
      .collection(`${userRoot(userId)}/workoutLogs`)
      .orderBy("createdAt", "desc")
      .limit(30)
      .get();
    return snap.docs.filter((doc) => doc.id !== sessionId).map((doc) => doc.data());
  } catch {
    return undefined;
  }
}

async function hasFinishedWorkout(db: Firestore, userId: string) {
  const snap = await db.collection(`${userRoot(userId)}/workoutLogs`).limit(1).get();
  return !snap.empty;
}

export const RateWorkoutSessionRequest = z.object({
  sessionId: z.string().min(1),
  effort: z.enum(["easy", "about_right", "too_much"]),
});
export type RateWorkoutSessionRequest = z.infer<typeof RateWorkoutSessionRequest>;

// "How did that feel?" on the 1–10 effort scale the log already carries.
const EFFORT_SCORE: Record<RateWorkoutSessionRequest["effort"], number> = {
  easy: 4,
  about_right: 6,
  too_much: 9,
};

/** Saves the answer to "How did that feel?" on the finished workout's log. */
export async function rateWorkoutSession(
  db: Firestore,
  userId: string,
  request: RateWorkoutSessionRequest,
) {
  const logRef = db.doc(workoutLogPath(userId, request.sessionId));
  const snap = await logRef.get();
  if (!snap.exists) return { rated: false };
  await logRef.set(
    { perceivedEffort: EFFORT_SCORE[request.effort], serverUpdatedAt: FieldValue.serverTimestamp() },
    { merge: true },
  );
  return { rated: true, perceivedEffort: EFFORT_SCORE[request.effort] };
}

async function seedMissingProgressionBaselines(
  db: Firestore,
  userId: string,
  exercises: Array<{ name: string; weight: number; progression?: { mode: string } }>,
  baselines: Awaited<ReturnType<typeof loadBaselines>>,
  anchorDate: string,
  now: string,
  skip: Set<string> = new Set(),
) {
  const missing = exercises.filter(
    (exercise) =>
      exercise.progression !== undefined &&
      exercise.progression.mode !== "none" &&
      exercise.weight > 0 &&
      !baselines.has(normalizeExerciseKey(exercise.name)) &&
      !skip.has(normalizeExerciseKey(exercise.name)),
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
  const planDays = planSnap.exists ? planData?.days : defaultPlan;
  if (override) {
    return { day: PlannedWorkoutDay.parse(override), fromOverride: true, planDays };
  }

  const dayData = readDay(planDays, dayKey) ?? readFirstWorkoutDay(planDays);
  return { day: PlannedWorkoutDay.parse(dayData), fromOverride: false, planDays };
}

// Lifts the plan prescribes at more than one weight across the week
// (Deadlift 4x6 @135 Tue, 5x5 @155 Fri). Anchors are keyed by exercise, so
// auto-seeding one of them would drag the other day to its number; those
// lifts keep the plan's own weights until the user or the coach anchors
// them deliberately.
function ambiguousLifts(planDays: unknown): Set<string> {
  const weights = new Map<string, Set<number>>();
  if (planDays && typeof planDays === "object") {
    for (const day of Object.values(planDays as Record<string, unknown>)) {
      const exercises = (day as { exercises?: unknown })?.exercises;
      if (!Array.isArray(exercises)) continue;
      for (const exercise of exercises) {
        if (!exercise || typeof exercise !== "object") continue;
        const { name, weight } = exercise as { name?: unknown; weight?: unknown };
        if (typeof name !== "string" || typeof weight !== "number") continue;
        const key = normalizeExerciseKey(name);
        if (!weights.has(key)) weights.set(key, new Set());
        weights.get(key)!.add(weight);
      }
    }
  }
  return new Set([...weights.entries()].filter(([, set]) => set.size > 1).map(([key]) => key));
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

/** Seconds from start to finish, or the client's figure; nothing past six hours. */
export function sessionDuration(sent: number | undefined, startedAt: string, completedAt: string): number | undefined {
  if (sent !== undefined) return sent;
  const elapsed = Math.round((Date.parse(completedAt) - Date.parse(startedAt)) / 1000);
  return Number.isFinite(elapsed) && elapsed > 0 && elapsed <= 6 * 3600 ? elapsed : undefined;
}
