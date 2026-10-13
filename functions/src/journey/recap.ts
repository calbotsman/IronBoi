import type { z } from "zod";
import type { ActiveWorkoutExercise, PlannedWorkoutDay } from "../contracts/coach-agent.js";

// The first days of the habit journey (docs/product/habit-journey-plan.md,
// Phase 1): the starter session, the end-of-workout recap, and the welcome.
// Everything here is deterministic and built from logged numbers — the coach
// never invents progress, so nothing in a recap can overclaim.

type Exercise = z.infer<typeof ActiveWorkoutExercise>;
type PlannedDay = z.infer<typeof PlannedWorkoutDay>;

const WEEK = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] as const;
const DAY_NAMES: Record<string, string> = {
  Mon: "Monday", Tue: "Tuesday", Wed: "Wednesday", Thu: "Thursday",
  Fri: "Friday", Sat: "Saturday", Sun: "Sunday",
};

const STARTER_MAX_EXERCISES = 4;
const STARTER_MAX_SETS = 2;

/**
 * The first-ever session: the planned day cut to a few moves and two sets
 * each, so it finishes in about twenty minutes and feels doable. Weights are
 * left alone — the coach tells you to leave reps in the tank, and the finish
 * screen learns your real starting numbers from what you lift.
 */
export function trimToStarter(day: PlannedDay): PlannedDay {
  return {
    ...day,
    exercises: day.exercises
      .filter((exercise) => exercise.sets > 0)
      .slice(0, STARTER_MAX_EXERCISES)
      .map((exercise) => ({ ...exercise, sets: Math.min(exercise.sets, STARTER_MAX_SETS) })),
  };
}

/** A previous workout, as far as the recap cares: lift name → heaviest load (kg) and best reps at it. */
export type PreviousBest = Map<string, { loadKg: number; reps: number }>;

/** Folds earlier workoutLogs docs into each lift's heaviest set (kg). */
export function previousBests(logs: Array<Record<string, unknown>>): PreviousBest {
  const best: PreviousBest = new Map();
  for (const log of logs) {
    const exercises = Array.isArray(log.exercises) ? log.exercises : [];
    for (const exercise of exercises) {
      if (!exercise || typeof exercise !== "object") continue;
      const { name, sets } = exercise as { name?: unknown; sets?: unknown };
      if (typeof name !== "string" || !Array.isArray(sets)) continue;
      const key = liftKey(name);
      for (const set of sets) {
        const loadKg = typeof set?.loadKg === "number" ? set.loadKg : 0;
        const reps = typeof set?.reps === "number" ? set.reps : 0;
        const current = best.get(key);
        if (!current || loadKg > current.loadKg || (loadKg === current.loadKg && reps > current.reps)) {
          best.set(key, { loadKg, reps });
        }
      }
    }
  }
  return best;
}

export type WorkoutRecap = {
  /** Spoken and shown, in order: what you did, one thing noticed, what's next. */
  lines: string[];
  firstWorkout: boolean;
};

const POUNDS_TO_KG = 0.45359237;

/**
 * Three short lines, all from logged numbers:
 *  1. what you did — moves, sets, reps, minutes;
 *  2. one specific thing — a new best, or that every set got done;
 *  3. what's next — the next planned day.
 */
export function buildWorkoutRecap(input: {
  exercises: Exercise[];
  previous: PreviousBest;
  firstWorkout: boolean;
  durationSec?: number;
  nextDay?: { dayKey: string; name: string };
}): WorkoutRecap {
  const done = input.exercises
    .map((exercise) => ({ exercise, sets: exercise.completedSets.filter((set) => set.completed) }))
    .filter(({ sets }) => sets.length > 0);
  const setCount = done.reduce((sum, { sets }) => sum + sets.length, 0);
  const repCount = done.reduce(
    (sum, { exercise, sets }) => sum + sets.reduce((s, set) => s + (set.reps ?? exercise.targetReps), 0),
    0,
  );
  const plannedSets = input.exercises.reduce((sum, exercise) => sum + exercise.targetSets, 0);

  const minutes = input.durationSec !== undefined && input.durationSec >= 60 && input.durationSec <= 3 * 3600
    ? Math.round(input.durationSec / 60)
    : undefined;
  const lines: string[] = [];
  lines.push(
    `${count(done.length, "move")}, ${count(setCount, "set")}, ${count(repCount, "rep")}` +
      (minutes !== undefined ? ` in ${count(minutes, "minute")}.` : "."),
  );

  if (input.firstWorkout) {
    lines.push("That's your starting point. I'll use today's numbers to set your weights.");
  } else {
    lines.push(noticed(done, input.previous) ?? (
      setCount >= plannedSets && plannedSets > 0
        ? "Every set done."
        : "Not every set, and that still counts. Showing up is the hard part."
    ));
  }

  if (input.nextDay) {
    lines.push(`Next up: ${input.nextDay.name}, ${DAY_NAMES[input.nextDay.dayKey] ?? input.nextDay.dayKey}.`);
  }
  return { lines, firstWorkout: input.firstWorkout };
}

/** A new heaviest set, or more reps at your heaviest — the first one found. */
function noticed(
  done: Array<{ exercise: Exercise; sets: Exercise["completedSets"] }>,
  previous: PreviousBest,
): string | undefined {
  for (const { exercise, sets } of done) {
    const before = previous.get(liftKey(exercise.name));
    if (!before) continue;
    let top = { weight: 0, reps: 0 };
    for (const set of sets) {
      const weight = set.weight ?? exercise.targetWeight;
      const reps = set.reps ?? exercise.targetReps;
      if (weight > top.weight || (weight === top.weight && reps > top.reps)) top = { weight, reps };
    }
    if (top.weight <= 0) continue;
    const topKg = Math.round(top.weight * POUNDS_TO_KG * 10) / 10;
    // Half a kilo of slack: logs round to 0.1 kg, so the same plate can
    // read a hair heavier and must not count as a best.
    if (topKg > before.loadKg + 0.5) {
      return `New best on ${exercise.name}: ${pounds(top.weight)} lb.`;
    }
    if (Math.abs(topKg - before.loadKg) <= 0.5 && top.reps > before.reps) {
      const more = top.reps - before.reps;
      return `${exercise.name}: ${top.reps} reps at ${pounds(top.weight)} lb, ${count(more, "more rep")} than your best.`;
    }
  }
  return undefined;
}

/** The next weekday after `fromDate` (YYYY-MM-DD) that has exercises in the plan. */
export function nextPlannedDay(
  planDays: unknown,
  fromDate: string,
): { dayKey: string; name: string } | undefined {
  if (!planDays || typeof planDays !== "object") return undefined;
  const days = planDays as Record<string, { name?: unknown; exercises?: unknown }>;
  const date = new Date(`${fromDate}T12:00:00Z`);
  if (Number.isNaN(date.getTime())) return undefined;
  const todayIndex = (date.getUTCDay() + 6) % 7; // Mon = 0
  for (let offset = 1; offset <= 7; offset += 1) {
    const key = WEEK[(todayIndex + offset) % 7];
    const day = days[key];
    if (day && Array.isArray(day.exercises) && day.exercises.length > 0) {
      return { dayKey: key, name: typeof day.name === "string" ? day.name : "your next session" };
    }
  }
  return undefined;
}

/** Days a week the plan trains. */
export function trainingDaysPerWeek(planDays: unknown): number {
  if (!planDays || typeof planDays !== "object") return 0;
  return Object.values(planDays as Record<string, { exercises?: unknown }>)
    .filter((day) => Array.isArray(day?.exercises) && day.exercises.length > 0).length;
}

/** The first thing the coach says once the plan is accepted. */
export function welcomeMessage(input: {
  name?: string;
  daysPerWeek: number;
  returning: boolean;
  /** Said yes to the doctor / symptoms screen in onboarding. */
  clearanceAdvised?: boolean;
}): string {
  const hello = input.name ? `Welcome, ${input.name}.` : "Welcome.";
  if (input.clearanceAdvised) {
    return [
      hello,
      `Your plan is set: ${count(input.daysPerWeek, "day")} a week, at the gentlest level.`,
      "Because a doctor has asked you to limit exercise, or you've had symptoms when active, please check with them before your first session.",
    ].join(" ");
  }
  if (input.returning) {
    return `${hello} Your new plan is set: ${count(input.daysPerWeek, "day")} a week. Tap Start when you're ready.`;
  }
  return [
    hello,
    `Your plan is set: ${count(input.daysPerWeek, "day")} a week.`,
    "Your first session is today, and it's short on purpose. Tap Start when you're ready.",
  ].join(" ");
}

function liftKey(name: string) {
  return name.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function pounds(weight: number) {
  return Number.isInteger(weight) ? String(weight) : weight.toFixed(1);
}

function count(n: number, noun: string) {
  return `${n} ${noun}${n === 1 ? "" : "s"}`;
}
