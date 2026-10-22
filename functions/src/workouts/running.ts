import { z } from "zod";
import type { PlannedRun, PlannedWorkoutDay } from "../contracts/coach-agent.js";
import { lookupExercise } from "./exerciseCatalog.js";

// Runs in the plan, for people who already run. This is "strength for
// runners" (docs/product/flexible-training-plan.md §5): their runs sit in
// the week as real sessions, and the lifting is planned around them, not
// beside them. Couch to 5K for new runners, run history from Apple Health
// and GPS come later.

const WEEK = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] as const;
type Day = z.infer<typeof PlannedWorkoutDay>;
type Run = z.infer<typeof PlannedRun>;

/** How someone runs now, saved on their profile so every rebuilt plan keeps it. */
export const RunningSetup = z
  .object({
    /** The days they run. Without them, the runs go on the days they don't lift. */
    days: z.array(z.enum(WEEK)).min(1).max(7).optional(),
    runsPerWeek: z.number().int().min(1).max(7).optional(),
    milesPerRun: z.number().min(0.25).max(30).optional(),
    minutesPerRun: z.number().int().min(5).max(240).optional(),
  })
  .strict()
  .refine((setup) => setup.days !== undefined || setup.runsPerWeek !== undefined, { message: "days_or_runs_per_week" });
export type RunningSetup = z.infer<typeof RunningSetup>;

/** A plain lower-body lift: these are what a run on the same day (or the next) competes with. */
function isLowerBody(name: string): boolean {
  const pattern = lookupExercise(name)?.pattern;
  if (pattern) return pattern === "squat" || pattern === "hinge" || pattern === "lunge" || pattern === "isolation_calf";
  return /\b(squat|lunge|deadlift|rdl|hip thrust|step[- ]?up|leg|calf|glute bridge|split)\b/i.test(name);
}

function hasLifting(day: Day | undefined): day is Day {
  return Boolean(day && day.exercises.length > 0);
}

/** Which days get a run: theirs if they said, else the days they don't lift, spread out. */
export function runDays(days: Record<string, Day>, setup: RunningSetup): string[] {
  if (setup.days) return WEEK.filter((day) => setup.days!.includes(day));
  const count = Math.min(7, setup.runsPerWeek ?? 3);
  const free = WEEK.filter((day) => !hasLifting(days[day]));
  const spread = (pool: readonly string[], n: number) =>
    Array.from({ length: n }, (_, i) => pool[Math.floor((i * pool.length) / n)]!);
  const picked = free.length >= count ? spread(free, count) : [...free, ...spread(WEEK.filter((d) => !free.includes(d)), count - free.length)];
  return WEEK.filter((day) => picked.includes(day));
}

function describe(setup: RunningSetup): Pick<Run, "distanceMi" | "durationMin"> {
  return {
    ...(setup.milesPerRun !== undefined ? { distanceMi: Math.round(setup.milesPerRun * 4) / 4 } : {}),
    ...(setup.minutesPerRun !== undefined ? { durationMin: setup.minutesPerRun } : {}),
    // Neither given: a run is still a run, with a sensible easy length.
    ...(setup.milesPerRun === undefined && setup.minutesPerRun === undefined ? { durationMin: 25 } : {}),
  };
}

/**
 * The week with their runs in it, and the lifting fitted around them:
 * - A run on a lifting day comes after the lifting, at an easy pace, and
 *   that day's leg work drops a set (never below two) so the legs aren't
 *   doubled up.
 * - Leg work the day before a run also drops a set, so they don't run on
 *   heavy legs.
 * - A run on a non-lifting day is its own session.
 * - At high mileage (over 20 a week) every leg lift drops a set.
 */
export function applyRunning(days: Record<string, Day>, setup: RunningSetup | undefined): Record<string, Day> {
  const out: Record<string, Day> = Object.fromEntries(
    Object.entries(days).map(([key, day]) => [key, { ...day, exercises: [...day.exercises], runs: undefined }]),
  );
  for (const day of Object.values(out)) delete day.runs;
  if (!setup) return out;

  const running = runDays(days, setup);
  const base = describe(setup);
  const weeklyMiles = (setup.milesPerRun ?? 0) * running.length;
  const trim = (day: Day) => {
    day.exercises = day.exercises.map((exercise) =>
      isLowerBody(exercise.name) && exercise.sets > 2 ? { ...exercise, sets: exercise.sets - 1 } : exercise);
  };

  for (const key of running) {
    const lifting = out[key];
    if (hasLifting(lifting)) {
      lifting.runs = [{ kind: "easy", ...base, note: "After lifting, at an easy pace" }];
      if (lifting.exercises.some((exercise) => isLowerBody(exercise.name))) trim(lifting);
    } else {
      out[key] = { name: "Easy run", muscles: [], exercises: [], runs: [{ kind: "easy", ...base }] };
    }
  }
  // Heavy legs the day before a run: one set less, so the run isn't on tired legs.
  for (const key of running) {
    const before = out[WEEK[(WEEK.indexOf(key as (typeof WEEK)[number]) + 6) % 7]!];
    if (hasLifting(before) && !before.runs) trim(before);
  }
  if (weeklyMiles > 20) {
    for (const day of Object.values(out)) if (hasLifting(day)) trim(day);
  }
  return out;
}

/** "Runs Mon, Tue and Wed, about 2 miles" — for the coach's reply and the plan card. */
export function runningSummary(days: Record<string, Day>): string | null {
  const running = WEEK.filter((day) => (days[day]?.runs ?? []).length > 0);
  if (running.length === 0) return null;
  const first = days[running[0]!]!.runs![0]!;
  const length = first.distanceMi !== undefined ? `${first.distanceMi} mi` : `${first.durationMin} min`;
  return `Easy runs on ${running.join(", ")}, ${length} each`;
}
