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

export const StartWorkoutSessionRequest = z.object({
  dayKey: z.string().min(1),
  planId: z.string().min(1).default("current"),
  sessionId: z.string().min(1).optional(),
  startedAt: z.string().datetime().optional(),
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
  const dayPlan = await loadWorkoutDay(db, userId, request.planId, request.dayKey, defaultPlan);

  const activeWorkout = ActiveWorkoutSession.parse({
    userId,
    sessionId,
    planId: request.planId,
    dayKey: request.dayKey,
    workoutName: dayPlan.name,
    status: "active",
    startedAt,
    updatedAt: now,
    exercises: dayPlan.exercises.map((exercise, exerciseIndex) => ({
      exerciseIndex,
      name: exercise.name,
      targetSets: exercise.sets,
      targetReps: exercise.reps,
      targetWeight: exercise.weight,
      completedSets: Array.from({ length: exercise.sets }, (_, setIndex) => ({
        setIndex,
        completed: false,
        reps: exercise.reps,
        weight: exercise.weight,
      })),
      exerciseDone: false,
    })),
  });

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
      sets: exercise.completedSets
        .filter((set) => set.completed)
        .map((set) => ({
          reps: set.reps ?? exercise.targetReps,
          loadKg:
            set.weight && set.weight > 0
              ? Math.round(set.weight * POUNDS_TO_KG * 10) / 10
              : undefined,
          notes: exercise.notes,
        })),
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

  return { activeWorkout: completedSession, workoutLog: log };
}

async function loadWorkoutDay(
  db: Firestore,
  userId: string,
  planId: string,
  dayKey: string,
  defaultPlan: Record<string, unknown>,
) {
  const planSnap = await db.doc(workoutPlanPath(userId, planId)).get();
  const planDays = planSnap.exists ? planSnap.data()?.days : defaultPlan;
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

