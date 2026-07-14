import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import {
  PlannedWorkoutDay,
  TrainingProgram,
  type TrainingProgram as TrainingProgramType,
} from "../contracts/coach-agent.js";
import { trainingProgramPath, workoutPlanPath } from "../paths.js";
import { z } from "zod";

const WEEK_ORDER = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] as const;
type PlannedWorkoutDayType = z.infer<typeof PlannedWorkoutDay>;

// Number of weeks materialized when a program is first created. Not a hard
// cap — a "going_forward" plan adjustment can extend the array — just how
// far ahead a fresh program is seeded so there's always a "next week" to
// look at before any adjustment has ever been made.
const INITIAL_PROGRAM_WEEKS = 4;

export function weekIndexForDate(startDate: string, targetDate: string): number {
  const start = Date.parse(`${startDate}T00:00:00Z`);
  const target = Date.parse(`${targetDate}T00:00:00Z`);
  const diffDays = Math.floor((target - start) / 86_400_000);
  return Math.max(0, Math.floor(diffDays / 7));
}

export function buildTrainingProgramFromDays(
  userId: string,
  days: Record<string, PlannedWorkoutDayType>,
  startDate: string,
  now: string,
  weekCount = INITIAL_PROGRAM_WEEKS,
): TrainingProgramType {
  return TrainingProgram.parse({
    userId,
    programId: "current",
    startDate,
    weeks: Array.from({ length: weekCount }, (_, weekIndex) => ({
      weekIndex,
      days,
    })),
    activeWeekIndex: 0,
    source: "coach_generated",
    updatedAt: now,
  });
}

// Writes users/{uid}/workoutPlans/current as a flattened view of the
// program's currently-active week. Existing `dailyOverrides` are left
// untouched by the merge — this only ever rewrites `days`.
export async function syncCurrentWeekSnapshot(
  db: Firestore,
  userId: string,
  program: TrainingProgramType,
  now: string,
): Promise<void> {
  const activeWeek =
    program.weeks.find((week) => week.weekIndex === program.activeWeekIndex) ??
    program.weeks[0];

  await db.doc(workoutPlanPath(userId, "current")).set(
    {
      userId,
      planId: "current",
      source: program.source,
      days: activeWeek?.days ?? {},
      updatedAt: now,
      serverUpdatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
}

// Shared by regenerateWorkoutPlan / regenerateWorkoutPlanHttp — a full
// rebuild resets both docs: workoutPlans/current is overwritten (dropping
// any dailyOverrides, matching the existing "old days that were dropped
// should go" behavior) and trainingPrograms/current restarts its week clock
// from today.
export async function writeRegeneratedPlanAndProgram(
  db: Firestore,
  userId: string,
  days: Record<string, PlannedWorkoutDayType>,
  now: string,
): Promise<void> {
  const startDate = now.slice(0, 10);
  const program = buildTrainingProgramFromDays(userId, days, startDate, now);

  await Promise.all([
    db.doc(workoutPlanPath(userId, "current")).set(
      {
        userId,
        planId: "current",
        source: "coach_generated",
        days,
        dailyOverrides: {},
        updatedAt: now,
        serverUpdatedAt: FieldValue.serverTimestamp(),
      },
      { merge: false },
    ),
    db.doc(trainingProgramPath(userId)).set({
      ...program,
      serverUpdatedAt: FieldValue.serverTimestamp(),
    }),
  ]);
}

// Live docs carry server bookkeeping fields (serverCreatedAt/serverUpdatedAt)
// that aren't in the strict schema — pick only the declared fields before
// parsing, the same pattern planAdjustments.ts uses for proposal docs.
export function parseTrainingProgramDocument(
  data: FirebaseFirestore.DocumentData | undefined,
): TrainingProgramType {
  const raw = data ?? {};
  return TrainingProgram.parse({
    userId: raw.userId,
    programId: raw.programId,
    startDate: raw.startDate,
    weeks: raw.weeks,
    activeWeekIndex: raw.activeWeekIndex,
    source: raw.source,
    updatedAt: raw.updatedAt,
  });
}

// Returns the user's trainingPrograms/current doc, backfilling it from the
// legacy flat workoutPlans/current doc if it doesn't exist yet. Backfilling
// repeats the user's current single week forward so a cascading adjustment
// has real week slots to diverge into, without changing what the user sees
// right now (workoutPlans/current is left as-is by the backfill).
export async function ensureTrainingProgram(
  db: Firestore,
  userId: string,
): Promise<TrainingProgramType> {
  const programRef = db.doc(trainingProgramPath(userId));
  const snap = await programRef.get();
  if (snap.exists) {
    return parseTrainingProgramDocument(snap.data());
  }

  const planSnap = await db.doc(workoutPlanPath(userId, "current")).get();
  const planData = planSnap.data();
  const days: Record<string, PlannedWorkoutDayType> =
    planData && isRecord(planData.days) ? (planData.days as Record<string, PlannedWorkoutDayType>) : {};

  const now = new Date().toISOString();
  const startDate = now.slice(0, 10);
  const program = buildTrainingProgramFromDays(userId, days, startDate, now);

  await programRef.set({ ...program, serverUpdatedAt: FieldValue.serverTimestamp() });
  return program;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export { WEEK_ORDER };
export type { TrainingProgramType };
