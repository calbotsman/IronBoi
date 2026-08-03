// Working-weight baselines and the progression that runs on top of them.
//
// The problem this solves: the plan said 60 lb, the user lifted 30, and next
// week the plan still said 60. Every session started by re-litigating a
// number the user had already settled.
//
// The fix is NOT "rewrite the plan to 30". That would also silently discard a
// coaching protocol like "add 5 lb a week" — the user asked for the drop to
// stick AND for progression to keep running from the new number. So the plan's
// prescribed weight becomes a DERIVED value:
//
//   prescribed = anchor + progression(weeks since the anchor was set)
//
// Re-anchoring to 30 restarts that clock at 30. Week one prescribes 30, week
// two 35, week three 40 — the drop stuck, and the protocol survived it.

import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { z } from "zod";
import {
  ExerciseBaseline,
  ExerciseProgression,
  PlannedWorkoutDay,
} from "../contracts/coach-agent.js";
import { safeLogger } from "../logging/safeLogger.js";
import {
  exerciseBaselinePath,
  exerciseBaselinesCollectionPath,
} from "../paths.js";
import { normalizeExerciseKey } from "./exerciseCatalog.js";

type ExerciseBaselineType = z.infer<typeof ExerciseBaseline>;
type ExerciseProgressionType = z.infer<typeof ExerciseProgression>;
type PlannedWorkoutDayType = z.infer<typeof PlannedWorkoutDay>;

export type BaselineMap = Map<string, ExerciseBaselineType>;

// Smallest increment worth prescribing. Gyms have 2.5 lb plates; telling
// someone to load 33.7 lb is noise dressed up as precision.
const PLATE_INCREMENT_LB = 2.5;

export function roundToPlate(weightLb: number): number {
  if (weightLb <= 0) return 0;
  return Math.round(weightLb / PLATE_INCREMENT_LB) * PLATE_INCREMENT_LB;
}

export function weeksBetween(fromISODate: string, toISODate: string): number {
  const from = Date.parse(`${fromISODate}T00:00:00Z`);
  const to = Date.parse(`${toISODate}T00:00:00Z`);
  if (Number.isNaN(from) || Number.isNaN(to)) return 0;
  return Math.max(0, Math.floor((to - from) / 86_400_000 / 7));
}

// What the anchor has grown to after `weeksElapsed` weeks of the protocol.
//
// Percent mode is linear on the anchor rather than compounding: 5%/week
// compounded is +63% over ten weeks, which nobody means when they say "add
// five percent a week", and which would quietly outrun any load the user has
// actually demonstrated.
export function applyProgression(
  anchorWeightLb: number,
  progression: ExerciseProgressionType | undefined,
  weeksElapsed: number,
): number {
  if (!progression || progression.mode === "none" || anchorWeightLb <= 0) {
    return roundToPlate(anchorWeightLb);
  }
  const steps = Math.floor(Math.max(0, weeksElapsed) / progression.everyWeeks);
  if (steps <= 0) return roundToPlate(anchorWeightLb);

  const increment =
    progression.mode === "linear_lb"
      ? progression.amount * steps
      : anchorWeightLb * (progression.amount / 100) * steps;

  const cap = anchorWeightLb * progression.capMultiple;
  return roundToPlate(Math.min(anchorWeightLb + increment, cap));
}

// The weight that should actually be prescribed for one exercise today.
//
// No baseline means no anchor has ever been established, so the plan's own
// number stands — which is exactly the pre-existing behavior, and why every
// current user sees no change until they rebaseline something.
export function resolvePrescribedWeight(
  exercise: { name: string; weight: number; progression?: ExerciseProgressionType },
  baselines: BaselineMap,
  todayISO: string,
): number {
  const baseline = baselines.get(normalizeExerciseKey(exercise.name));
  if (!baseline) return exercise.weight;
  return applyProgression(
    baseline.anchorWeightLb,
    exercise.progression,
    weeksBetween(baseline.anchorDate, todayISO),
  );
}

export async function loadBaselines(db: Firestore, userId: string): Promise<BaselineMap> {
  const snap = await db.collection(exerciseBaselinesCollectionPath(userId)).get();
  const map: BaselineMap = new Map();
  for (const doc of snap.docs) {
    const parsed = ExerciseBaseline.safeParse(stripServerFields(doc.data()));
    if (parsed.success) {
      map.set(parsed.data.exerciseKey, parsed.data);
    } else {
      // One malformed baseline doc must not make the user's workout
      // unstartable. Drop it and fall back to the plan's own weight.
      safeLogger.warn("Skipping malformed exercise baseline", {
        event: "exercise_baseline_malformed",
        userId,
        outcome: doc.id,
      });
    }
  }
  return map;
}

// Live docs carry serverUpdatedAt; the contract schema is .strict().
function stripServerFields(data: FirebaseFirestore.DocumentData | undefined) {
  const raw = data ?? {};
  return {
    userId: raw.userId,
    exerciseKey: raw.exerciseKey,
    exerciseName: raw.exerciseName,
    anchorWeightLb: raw.anchorWeightLb,
    anchorDate: raw.anchorDate,
    source: raw.source,
    lastSessionId: raw.lastSessionId,
    updatedAt: raw.updatedAt,
  };
}

export type BaselineSuggestion = {
  exerciseName: string;
  fromLb: number;
  toLb: number;
};

type FinishedExercise = {
  name: string;
  targetWeight: number;
  completedSets: Array<{ completed: boolean; weight?: number }>;
};

// What the user actually worked at, across the sets they actually completed.
//
// The MODE, not the last set and not the max: a lifter who does 3 sets at 30
// and one mistaken tap at 60 worked at 30. Ties break heavy, because between
// two equally-represented weights the heavier one is the one they proved.
function workedWeight(exercise: FinishedExercise): number | null {
  const weights = exercise.completedSets
    .filter((set) => set.completed && typeof set.weight === "number")
    .map((set) => set.weight as number);
  if (weights.length === 0) return null;

  const counts = new Map<number, number>();
  for (const weight of weights) {
    counts.set(weight, (counts.get(weight) ?? 0) + 1);
  }
  let best = weights[0];
  let bestCount = 0;
  for (const [weight, count] of counts) {
    if (count > bestCount || (count === bestCount && weight > best)) {
      best = weight;
      bestCount = count;
    }
  }
  return best;
}

// Rebaseline candidates from a finished session — proposed, never applied.
// The user picked "ask on finish", so this returns a list for a card and
// writes nothing; applyExerciseBaselines is what commits.
//
// Direction-agnostic on purpose: going heavier than prescribed is as much a
// new working weight as going lighter, and anchoring only the drops would
// mean a user who moves up keeps being prescribed the old number forever.
export function deriveBaselineSuggestions(
  exercises: FinishedExercise[],
): BaselineSuggestion[] {
  const suggestions: BaselineSuggestion[] = [];
  const seen = new Set<string>();

  for (const exercise of exercises) {
    const key = normalizeExerciseKey(exercise.name);
    if (seen.has(key)) continue;

    const actual = workedWeight(exercise);
    if (actual === null) continue;
    // Bodyweight movements have nothing to rebaseline: prescribed 0, lifted
    // 0. Offering "update Push-ups from 0 lb to 0 lb" is noise.
    if (actual <= 0 && exercise.targetWeight <= 0) continue;
    if (Math.abs(actual - exercise.targetWeight) < 0.5) continue;

    seen.add(key);
    suggestions.push({
      exerciseName: exercise.name,
      fromLb: exercise.targetWeight,
      toLb: actual,
    });
  }

  return suggestions;
}

export const ApplyExerciseBaselinesRequest = z.object({
  // The session these weights came from. Required: it is what proves the
  // user actually performed the exercise at that weight, rather than a
  // client posting arbitrary anchors.
  sessionId: z.string().min(1),
  baselines: z
    .array(
      z.object({
        exerciseName: z.string().min(1),
        weightLb: z.number().nonnegative().max(2000),
      }).strict(),
    )
    .min(1)
    .max(30),
  clientDate: z.string().date().optional(),
});

export type ApplyExerciseBaselinesRequestType = z.infer<typeof ApplyExerciseBaselinesRequest>;

// Rewrites a day's exercises so anchored movements show their derived
// prescription. Used to keep workoutPlans/current and the program's future
// weeks agreeing with the anchors — the Train tab reads those docs directly
// via a snapshot listener, so a number left stale there is a number the user
// sees and doesn't believe.
export function applyBaselinesToDay(
  day: PlannedWorkoutDayType,
  baselines: BaselineMap,
  todayISO: string,
): PlannedWorkoutDayType {
  let changed = false;
  const exercises = day.exercises.map((exercise) => {
    const resolved = resolvePrescribedWeight(exercise, baselines, todayISO);
    if (resolved === exercise.weight) return exercise;
    changed = true;
    return { ...exercise, weight: resolved };
  });
  return changed ? { ...day, exercises } : day;
}

export function applyBaselinesToDays(
  days: Record<string, PlannedWorkoutDayType>,
  baselines: BaselineMap,
  todayISO: string,
): { days: Record<string, PlannedWorkoutDayType>; changed: boolean } {
  let changed = false;
  const next: Record<string, PlannedWorkoutDayType> = {};
  for (const [dayKey, day] of Object.entries(days)) {
    const patched = applyBaselinesToDay(day, baselines, todayISO);
    if (patched !== day) changed = true;
    next[dayKey] = patched;
  }
  return { days: next, changed };
}

export function baselineDocFor(
  userId: string,
  exerciseName: string,
  weightLb: number,
  anchorDate: string,
  source: ExerciseBaselineType["source"],
  now: string,
  sessionId?: string,
): ExerciseBaselineType {
  return ExerciseBaseline.parse({
    userId,
    exerciseKey: normalizeExerciseKey(exerciseName),
    exerciseName,
    anchorWeightLb: roundToPlate(weightLb),
    anchorDate,
    source,
    ...(sessionId !== undefined ? { lastSessionId: sessionId } : {}),
    updatedAt: now,
  });
}

export function baselineRefFor(db: Firestore, userId: string, exerciseName: string) {
  return db.doc(exerciseBaselinePath(userId, normalizeExerciseKey(exerciseName)));
}
