// Default progression rules for generated plans.
//
// Before 2026-09-03 the whole progression chain existed — a per-exercise
// rule (ExerciseProgression), an anchor seeded the first time the user
// started a session (activeWorkout.ts seedMissingProgressionBaselines), and
// the Sunday rollover recomputing every future week from anchor + rule
// (rollover.ts) — but no plan generator ever attached a rule, so every week
// the user trained was an identical copy of the last. This module is the
// missing link: a conservative default per exercise, chosen from the
// catalog's loadClass, so "add 5 lb a week" is the norm rather than
// something only a coach-authored patch could switch on.
//
// Deliberately conservative: heavy barbell compounds move 5 lb a week,
// moderate/dumbbell work 2.5 lb, light isolation 2.5 lb every second week.
// Bodyweight and timed work never progress by load. capMultiple (schema
// default 1.5) still caps a long-running program at 150% of the anchor.

import type { z } from "zod";
import type { ExerciseProgression, PlannedWorkoutDay } from "../contracts/coach-agent.js";
import { lookupExercise } from "./exerciseCatalog.js";

type ExerciseProgressionType = z.infer<typeof ExerciseProgression>;
type PlannedWorkoutDayType = z.infer<typeof PlannedWorkoutDay>;

export function defaultProgressionFor(
  exerciseName: string,
  weight: number,
): ExerciseProgressionType | undefined {
  if (!(weight > 0)) return undefined;
  const entry = lookupExercise(exerciseName);
  if (!entry) return undefined;
  switch (entry.loadClass) {
    case "heavy":
      return { mode: "linear_lb", amount: 5, everyWeeks: 1, capMultiple: 1.5 };
    case "moderate":
      return { mode: "linear_lb", amount: 2.5, everyWeeks: 1, capMultiple: 1.5 };
    case "light":
      return { mode: "linear_lb", amount: 2.5, everyWeeks: 2, capMultiple: 1.5 };
    default:
      return undefined;
  }
}

// Attaches a default rule to every loaded exercise that has none. Returns
// the SAME object when nothing changed so callers can skip a write.
export function attachDefaultProgression(
  days: Record<string, PlannedWorkoutDayType>,
): { days: Record<string, PlannedWorkoutDayType>; changed: boolean } {
  let changed = false;
  const next: Record<string, PlannedWorkoutDayType> = {};
  for (const [dayKey, day] of Object.entries(days)) {
    let dayChanged = false;
    const exercises = day.exercises.map((exercise) => {
      if (exercise.progression !== undefined) return exercise;
      const rule = defaultProgressionFor(exercise.name, exercise.weight);
      if (!rule) return exercise;
      dayChanged = true;
      return { ...exercise, progression: rule };
    });
    if (dayChanged) changed = true;
    next[dayKey] = dayChanged ? { ...day, exercises } : day;
  }
  return changed ? { days: next, changed } : { days, changed };
}

// One-line label for prompts and cards: "+5 lb/wk", "+2.5 lb/2wk".
export function progressionLabel(progression: ExerciseProgressionType | undefined): string | undefined {
  if (!progression || progression.mode === "none" || !(progression.amount > 0)) return undefined;
  const unit = progression.mode === "linear_lb" ? " lb" : "%";
  const cadence = progression.everyWeeks === 1 ? "wk" : `${progression.everyWeeks}wk`;
  return `+${progression.amount}${unit}/${cadence}`;
}
