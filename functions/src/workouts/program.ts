import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import {
  PlannedExercise,
  PlannedWorkoutDay,
  TrainingProgram,
  type TrainingProgram as TrainingProgramType,
} from "../contracts/coach-agent.js";
import { safeLogger } from "../logging/safeLogger.js";
import { trainingProgramPath, workoutPlanPath } from "../paths.js";
import { z } from "zod";

const WEEK_ORDER = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] as const;
type PlannedWorkoutDayType = z.infer<typeof PlannedWorkoutDay>;

// Number of weeks materialized when a program is first created — how far
// ahead a fresh program is seeded so there's always a "next week" to look
// at before any adjustment has ever been made. Note: nothing currently
// extends the array past this; a going_forward patch rewrites the
// materialized weeks only.
const INITIAL_PROGRAM_WEEKS = 4;

export function weekIndexForDate(startDate: string, targetDate: string): number {
  const start = Date.parse(`${startDate}T00:00:00Z`);
  const target = Date.parse(`${targetDate}T00:00:00Z`);
  if (Number.isNaN(start) || Number.isNaN(target)) {
    return 0;
  }
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
// from today. Batched so the two docs can't diverge on a partial failure.
export async function writeRegeneratedPlanAndProgram(
  db: Firestore,
  userId: string,
  days: Record<string, PlannedWorkoutDayType>,
  now: string,
): Promise<void> {
  const startDate = now.slice(0, 10);
  const program = buildTrainingProgramFromDays(userId, days, startDate, now);

  const batch = db.batch();
  batch.set(
    db.doc(workoutPlanPath(userId, "current")),
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
  );
  batch.set(db.doc(trainingProgramPath(userId)), {
    ...program,
    serverUpdatedAt: FieldValue.serverTimestamp(),
  });
  await batch.commit();
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

// The legacy flat plan's `days` were written by clients (the legacy_pwa
// source exists for a reason) and were never schema-validated beyond the
// rules' top-level key allowlist. A strict parse here would make ONE
// malformed exercise brick every future accept for that user — so the
// backfill coerces instead: keep what parses, drop what doesn't, log what
// was dropped.
function sanitizeDaysForBackfill(
  userId: string,
  rawDays: Record<string, unknown>,
): Record<string, PlannedWorkoutDayType> {
  const days: Record<string, PlannedWorkoutDayType> = {};
  let droppedExercises = 0;
  let droppedDays = 0;

  for (const dayKey of WEEK_ORDER) {
    const rawDay = rawDays[dayKey];
    if (!isRecord(rawDay)) continue;
    const name = typeof rawDay.name === "string" && rawDay.name.length > 0 ? rawDay.name : null;
    if (!name) {
      droppedDays += 1;
      continue;
    }
    const muscles = Array.isArray(rawDay.muscles)
      ? rawDay.muscles.filter((muscle): muscle is string => typeof muscle === "string")
      : [];
    const rawExercises = Array.isArray(rawDay.exercises) ? rawDay.exercises : [];
    const exercises: z.infer<typeof PlannedExercise>[] = [];
    for (const rawExercise of rawExercises) {
      const parsed = PlannedExercise.safeParse(
        isRecord(rawExercise)
          ? {
              name: rawExercise.name,
              sets: coerceNonNegativeInt(rawExercise.sets),
              reps: coerceNonNegativeInt(rawExercise.reps),
              weight: coerceNonNegativeNumber(rawExercise.weight),
            }
          : rawExercise,
      );
      if (parsed.success) {
        exercises.push(parsed.data);
      } else {
        droppedExercises += 1;
      }
    }
    days[dayKey] = { name, muscles, exercises };
  }

  if (droppedExercises > 0 || droppedDays > 0) {
    safeLogger.warn("Training program backfill dropped malformed plan content", {
      event: "training_program_backfill_sanitized",
      userId,
      outcome: `dropped_${droppedDays}_days_${droppedExercises}_exercises`,
    });
  }

  return days;
}

function coerceNonNegativeInt(value: unknown): number {
  const num = typeof value === "number" ? value : Number(value);
  return Number.isFinite(num) && num >= 0 ? Math.round(num) : 0;
}

function coerceNonNegativeNumber(value: unknown): number {
  const num = typeof value === "number" ? value : Number(value);
  return Number.isFinite(num) && num >= 0 ? num : 0;
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
  const days = sanitizeDaysForBackfill(
    userId,
    planData && isRecord(planData.days) ? planData.days : {},
  );

  const now = new Date().toISOString();
  const startDate = now.slice(0, 10);
  const program = buildTrainingProgramFromDays(userId, days, startDate, now);

  // create(), not set(): two concurrent accepts can both see "missing" and
  // both backfill — a blind set() from the loser would then overwrite a
  // program the winner's transaction may already have patched. create()
  // makes the loser fail with ALREADY_EXISTS, and we re-read the winner's doc.
  try {
    await programRef.create({ ...program, serverUpdatedAt: FieldValue.serverTimestamp() });
    return program;
  } catch (error) {
    const alreadyExists =
      isRecord(error) && (error.code === 6 || error.code === "ALREADY_EXISTS");
    if (!alreadyExists) throw error;
    const existing = await programRef.get();
    return parseTrainingProgramDocument(existing.data());
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export { WEEK_ORDER };
export type { TrainingProgramType };
