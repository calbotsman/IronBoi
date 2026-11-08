// Session progression, "double progression" (docs/plans/myo-training-intelligence.md S2).
//
// The weekly rollover only moves a lift once a week, and only lifts with a
// progression rule, so a user who hit every rep at 35 lb on Monday was told
// 35 again on Thursday. The owner's call: when every prescribed set of a
// lift is done at (or above) the prescribed weight with every rep, the next
// session starts one step heavier, and the coach says so.
//
// The step re-anchors the lift (anchor = new weight, anchorDate = the session
// date). The rollover's rep gate then sees a session_up event for the
// session it is judging and restarts the clock instead of adding its own
// step on top (rollover.ts gateProgression): one earned step per session,
// never two for the same week.

import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import type { z } from "zod";
import type { ActiveWorkoutExercise, ExerciseProgression } from "../contracts/coach-agent.js";
import { trainingProgramPath, workoutPlanPath } from "../paths.js";
import { isTimedExercise, lookupExercise, normalizeExerciseKey } from "./exerciseCatalog.js";
import {
  baselineDocFor,
  baselinePropagation,
  baselineRefFor,
  loadBaselines,
  resolvePrescribedWeight,
  roundToPlate,
  type BaselineMap,
  type BaselineSuggestion,
} from "./exerciseBaselines.js";
import { defaultProgressionFor } from "./progressionDefaults.js";
import { lbText, progressionEventDoc, writeProgressionEvent } from "./progressionEvents.js";
import { parseTrainingProgramDocument } from "./program.js";

type FinishedExercise = z.infer<typeof ActiveWorkoutExercise>;
type ExerciseProgressionType = z.infer<typeof ExerciseProgression>;
type PlanExercise = { name: string; weight: number; progression?: ExerciseProgressionType };

// For lifts with no rule at all (kettlebells, unknown names): the step a gym
// can actually load. Light isolation work moves in the smaller step.
const DEFAULT_STEP_LB = 5;
const LIGHT_STEP_LB = 2.5;
const DEFAULT_CAP_MULTIPLE = 1.3;
// Logged weights carry rounding from the app's steppers; a hair under the
// prescription is still the prescription.
const WEIGHT_SLACK_LB = 0.25;

export type SessionUp = {
  exerciseName: string;
  exerciseKey: string;
  // The weight every set was proved at (≥ prescribed).
  fromLb: number;
  toLb: number;
  reason: string;
};

/**
 * Which lifts earned a step this session. Pure: the caller loads the plan
 * and the anchors. A lift qualifies when it has load, isn't timed, cardio or
 * bodyweight, every prescribed set was completed with reps ≥ target at a
 * weight ≥ prescribed, and the prescription was the full one (a reduced
 * dailyOverride day, such as a ramp week at 60%, is served below the
 * anchor and never earns a step).
 */
export function planSessionProgression(input: {
  exercises: FinishedExercise[];
  planDays: unknown;
  baselines: BaselineMap;
  date: string;
}): SessionUp[] {
  const planExercises = planExercisesByKey(input.planDays);
  const ambiguous = ambiguousLifts(input.planDays);
  const ups: SessionUp[] = [];
  const seen = new Set<string>();

  for (const exercise of input.exercises) {
    const key = normalizeExerciseKey(exercise.name);
    if (seen.has(key) || ambiguous.has(key)) continue;
    seen.add(key);
    if (!(exercise.targetWeight > 0) || exercise.targetSets <= 0 || exercise.targetReps <= 0) continue;
    if (isTimedExercise(exercise.name)) continue;
    if (lookupExercise(exercise.name)?.loadClass === "bodyweight") continue;

    const planExercise = planExercises.get(key);
    // An explicit "none" is a coach decision to hold this lift; respect it.
    if (planExercise?.progression?.mode === "none") continue;

    const prescribed = currentPrescription(exercise, planExercise, input.baselines, input.date);
    if (exercise.targetWeight + WEIGHT_SLACK_LB < prescribed) continue;

    const done = exercise.completedSets.filter((set) => set.completed);
    if (done.length < exercise.targetSets) continue;
    const allHit = done.every((set) => (set.reps ?? exercise.targetReps) >= exercise.targetReps);
    const weights = done.map((set) => set.weight ?? exercise.targetWeight);
    if (!allHit || weights.some((weight) => weight + WEIGHT_SLACK_LB < exercise.targetWeight)) continue;

    // The weight proved on every set, so a heavier lifter steps from what
    // they actually did, not from the old number.
    const base = roundToPlate(Math.max(exercise.targetWeight, Math.min(...weights)));
    const rule = planExercise?.progression ?? defaultProgressionFor(exercise.name, base);
    const step = stepFor(exercise.name, rule, base);
    if (!(step > 0)) continue;
    // The existing ceiling: one step never carries the anchor past its own
    // capMultiple (the same bound the weekly rule respects).
    const cap = base * (rule?.capMultiple ?? DEFAULT_CAP_MULTIPLE);
    const toLb = roundToPlate(Math.min(base + step, cap));
    if (!(toLb > base)) continue;

    ups.push({
      exerciseName: exercise.name,
      exerciseKey: key,
      fromLb: base,
      toLb,
      reason: `All ${exercise.targetSets}×${exercise.targetReps} hit at ${lbText(base)} lb`,
    });
  }
  return ups;
}

function stepFor(name: string, rule: ExerciseProgressionType | undefined, base: number): number {
  if (rule && rule.mode === "linear_lb") return rule.amount;
  if (rule && rule.mode === "percent") return Math.max(LIGHT_STEP_LB, roundToPlate((base * rule.amount) / 100));
  return lookupExercise(name)?.loadClass === "light" ? LIGHT_STEP_LB : DEFAULT_STEP_LB;
}

function currentPrescription(
  exercise: FinishedExercise,
  planExercise: PlanExercise | undefined,
  baselines: BaselineMap,
  date: string,
): number {
  if (planExercise) return resolvePrescribedWeight(planExercise, baselines, date);
  // Swapped in mid-workout (not in the plan): its anchor if it has one,
  // else what the session prescribed.
  const anchor = baselines.get(normalizeExerciseKey(exercise.name));
  return anchor ? roundToPlate(anchor.anchorWeightLb) : exercise.targetWeight;
}

function planExercisesByKey(planDays: unknown): Map<string, PlanExercise> {
  const byKey = new Map<string, PlanExercise>();
  if (!isRecord(planDays)) return byKey;
  for (const day of Object.values(planDays)) {
    const exercises = isRecord(day) && Array.isArray(day.exercises) ? day.exercises : [];
    for (const exercise of exercises) {
      if (!isRecord(exercise) || typeof exercise.name !== "string" || typeof exercise.weight !== "number") continue;
      const key = normalizeExerciseKey(exercise.name);
      if (byKey.has(key)) continue;
      byKey.set(key, {
        name: exercise.name,
        weight: exercise.weight,
        ...(isRecord(exercise.progression) ? { progression: exercise.progression as ExerciseProgressionType } : {}),
      });
    }
  }
  return byKey;
}

// Lifts the plan prescribes at more than one weight across the week
// (Deadlift 4x6 @135 Tue, 5x5 @155 Fri). Anchors are keyed by exercise, so
// moving one of them would drag the other day to its number; those lifts
// keep the plan's own weights until the user or the coach anchors them
// deliberately.
export function ambiguousLifts(planDays: unknown): Set<string> {
  const weights = new Map<string, Set<number>>();
  if (isRecord(planDays)) {
    for (const day of Object.values(planDays)) {
      const exercises = isRecord(day) && Array.isArray(day.exercises) ? day.exercises : [];
      for (const exercise of exercises) {
        if (!isRecord(exercise)) continue;
        const { name, weight } = exercise;
        if (typeof name !== "string" || typeof weight !== "number") continue;
        const key = normalizeExerciseKey(name);
        if (!weights.has(key)) weights.set(key, new Set());
        weights.get(key)!.add(weight);
      }
    }
  }
  return new Set([...weights.entries()].filter(([, set]) => set.size > 1).map(([key]) => key));
}

/**
 * Applies a finished session's steps (anchors, the plan and program the app
 * reads) and writes its events: session_up for each step, changed_in_workout
 * for each lift worked at a different weight than prescribed. One batch, so
 * an anchor never moves without its reason.
 */
export async function applySessionProgression(
  db: Firestore,
  userId: string,
  input: {
    sessionId: string;
    date: string;
    exercises: FinishedExercise[];
    changedInWorkout: BaselineSuggestion[];
    now: string;
  },
): Promise<SessionUp[]> {
  const [planSnap, programSnap, baselines] = await Promise.all([
    db.doc(workoutPlanPath(userId, "current")).get(),
    db.doc(trainingProgramPath(userId)).get(),
    loadBaselines(db, userId),
  ]);
  const planData = planSnap.exists ? planSnap.data() : undefined;
  const ups = planSessionProgression({
    exercises: input.exercises,
    planDays: planData?.days,
    baselines,
    date: input.date,
  });
  if (ups.length === 0 && input.changedInWorkout.length === 0) return ups;

  const batch = db.batch();
  for (const change of input.changedInWorkout) {
    writeProgressionEvent(db, batch, progressionEventDoc({
      userId,
      scope: input.sessionId,
      kind: "changed_in_workout",
      exerciseName: change.exerciseName,
      date: input.date,
      fromLb: change.fromLb,
      toLb: change.toLb,
      reason: `Lifted ${lbText(change.toLb)} lb instead of the planned ${lbText(change.fromLb)} lb`,
      sessionId: input.sessionId,
      now: input.now,
    }));
  }
  for (const up of ups) {
    const doc = baselineDocFor(userId, up.exerciseName, up.toLb, input.date, "user_session", input.now, input.sessionId);
    baselines.set(doc.exerciseKey, doc);
    batch.set(baselineRefFor(db, userId, up.exerciseName), { ...doc, serverUpdatedAt: FieldValue.serverTimestamp() }, { merge: true });
    writeProgressionEvent(db, batch, progressionEventDoc({
      userId,
      scope: input.sessionId,
      kind: "session_up",
      exerciseName: up.exerciseName,
      date: input.date,
      fromLb: up.fromLb,
      toLb: up.toLb,
      reason: up.reason,
      sessionId: input.sessionId,
      now: input.now,
    }));
  }

  if (ups.length > 0) {
    // The Train tab reads these docs straight from a listener: the new
    // number has to land there too, not only on the anchor.
    let program;
    try {
      program = programSnap.exists ? parseTrainingProgramDocument(programSnap.data()) : undefined;
    } catch {
      program = undefined; // A malformed program is the rollover's to report.
    }
    const { planDays, programWeeks } = baselinePropagation(planData, program, baselines, input.date);
    if (planDays) {
      batch.set(planSnap.ref, { days: planDays, updatedAt: input.now, serverUpdatedAt: FieldValue.serverTimestamp() }, { merge: true });
    }
    if (programWeeks) {
      batch.set(programSnap.ref, { weeks: programWeeks, updatedAt: input.now, serverUpdatedAt: FieldValue.serverTimestamp() }, { merge: true });
    }
  }
  await batch.commit();
  return ups;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
