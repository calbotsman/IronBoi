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

const CAP = 1.3;

// Steps are chosen by what a gym can actually load, not just by how heavy
// the movement is:
//   barbell  — 2.5 lb plates exist: +5/wk on squat/bench/deadlift; the press
//              and rows stall sooner, so +2.5/wk and +5/2wk; bar isolation
//              (skull crushers, EZ curl) +5/2wk.
//   dumbbell / bench-only loaded work — racks go in 5 lb steps per hand, so
//              +5 every 2 weeks (moderate) or every 4 weeks (light).
//   cable / machine — 5-10 lb stacks: +5/2wk.
//   kettlebell / club / sandbag / medball — fixed implements with big jumps
//              (a 53 → 62 lb bell is +17%); no automatic step. The coach can
//              propose the jump when the user reports the bell is easy.
//   bodyweight, timed, or unknown — nothing.
export function defaultProgressionFor(
  exerciseName: string,
  weight: number,
): ExerciseProgressionType | undefined {
  if (!(weight > 0)) return undefined;
  const entry = lookupExercise(exerciseName);
  if (!entry || entry.loadClass === "bodyweight") return undefined;
  const has = (equipment: string) => (entry.equipment as string[]).includes(equipment);
  const rule = (amount: number, everyWeeks: number): ExerciseProgressionType => ({
    mode: "linear_lb",
    amount,
    everyWeeks,
    capMultiple: CAP,
  });

  if (has("kettlebell") || has("club") || has("sandbag") || has("medball")) return undefined;

  if (has("barbell")) {
    if (entry.loadClass === "heavy") {
      if (entry.pattern === "vertical_push") return rule(2.5, 1);
      if (entry.pattern === "horizontal_pull") return rule(5, 2);
      return rule(5, 1);
    }
    return rule(5, 2);
  }
  if (has("cable") || has("machine")) return rule(5, 2);
  // Dumbbells, and loaded work whose only listed kit is a bench or nothing.
  return entry.loadClass === "light" ? rule(5, 4) : rule(5, 2);
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
