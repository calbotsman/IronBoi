import { describe, expect, it } from "vitest";
import {
  buildWorkoutRecap,
  nextPlannedDay,
  previousBests,
  trainingDaysPerWeek,
  trimToStarter,
  welcomeMessage,
} from "../../../src/journey/recap.js";

const PLAN_DAYS = {
  Mon: { name: "Full Body A", exercises: [{ name: "Goblet Squat" }] },
  Tue: { name: "Rest", exercises: [] },
  Wed: { name: "Full Body B", exercises: [{ name: "Bench Press" }] },
  Thu: { name: "Rest", exercises: [] },
  Fri: { name: "Full Body C", exercises: [{ name: "Deadlift" }] },
  Sat: { name: "Rest", exercises: [] },
  Sun: { name: "Rest", exercises: [] },
};

function exercise(name: string, sets: Array<{ reps: number; weight: number; completed?: boolean }>, targetSets = sets.length) {
  return {
    exerciseIndex: 0,
    name,
    targetSets,
    targetReps: 10,
    targetWeight: sets[0]?.weight ?? 0,
    completedSets: sets.map((set, setIndex) => ({ setIndex, completed: set.completed ?? true, reps: set.reps, weight: set.weight })),
    exerciseDone: true,
  };
}

describe("trimToStarter — the first session is short on purpose", () => {
  it("keeps at most 4 moves at 2 sets each, weights untouched", () => {
    const day = {
      name: "Full Body A",
      muscles: [],
      exercises: [
        { name: "A", sets: 3, reps: 8, weight: 95 },
        { name: "B", sets: 4, reps: 10, weight: 40 },
        { name: "C", sets: 1, reps: 12, weight: 0 },
        { name: "D", sets: 3, reps: 8, weight: 20 },
        { name: "E", sets: 3, reps: 8, weight: 20 },
      ],
    };
    const starter = trimToStarter(day);
    expect(starter.exercises.map((e) => e.name)).toEqual(["A", "B", "C", "D"]);
    expect(starter.exercises.map((e) => e.sets)).toEqual([2, 2, 1, 2]);
    expect(starter.exercises.map((e) => e.weight)).toEqual([95, 40, 0, 20]);
  });
});

describe("buildWorkoutRecap — three lines, all from logged numbers", () => {
  it("first workout: totals, starting point, next day", () => {
    const recap = buildWorkoutRecap({
      exercises: [
        exercise("Goblet Squat", [{ reps: 10, weight: 35 }, { reps: 10, weight: 35 }]),
        exercise("Push-up", [{ reps: 8, weight: 0 }]),
      ],
      previous: new Map(),
      firstWorkout: true,
      durationSec: 22 * 60 + 10,
      nextDay: { dayKey: "Wed", name: "Full Body B" },
    });
    expect(recap.firstWorkout).toBe(true);
    expect(recap.lines).toEqual([
      "2 moves, 3 sets, 28 reps in 22 minutes.",
      "That's your starting point. I'll use today's numbers to set your weights.",
      "Next up: Full Body B, Wednesday.",
    ]);
  });

  it("calls out a new heaviest set", () => {
    const previous = previousBests([
      { exercises: [{ name: "Goblet Squat", sets: [{ reps: 10, loadKg: 15.9 }] }] },
    ]);
    const recap = buildWorkoutRecap({
      exercises: [exercise("Goblet Squat", [{ reps: 10, weight: 45 }])],
      previous,
      firstWorkout: false,
    });
    expect(recap.lines[1]).toBe("New best on Goblet Squat: 45 lb.");
  });

  it("calls out more reps at the same weight, not a rounding wobble", () => {
    // 35 lb logs as 15.9 kg; the same 35 lb must not read as a weight PR.
    const previous = previousBests([
      { exercises: [{ name: "Goblet Squat", sets: [{ reps: 10, loadKg: 15.9 }] }] },
    ]);
    const recap = buildWorkoutRecap({
      exercises: [exercise("Goblet Squat", [{ reps: 12, weight: 35 }])],
      previous,
      firstWorkout: false,
    });
    expect(recap.lines[1]).toBe("Goblet Squat: 12 reps at 35 lb, 2 more reps than your best.");
  });

  it("no best: every set done, or kind words when not", () => {
    const previous = previousBests([
      { exercises: [{ name: "Goblet Squat", sets: [{ reps: 10, loadKg: 15.9 }] }] },
    ]);
    const all = buildWorkoutRecap({
      exercises: [exercise("Goblet Squat", [{ reps: 10, weight: 35 }])],
      previous,
      firstWorkout: false,
    });
    expect(all.lines[1]).toBe("Every set done.");
    const some = buildWorkoutRecap({
      exercises: [exercise("Goblet Squat", [{ reps: 10, weight: 35 }, { reps: 10, weight: 35, completed: false }])],
      previous,
      firstWorkout: false,
    });
    expect(some.lines[0]).toBe("1 move, 1 set, 10 reps.");
    expect(some.lines[1]).toMatch(/still counts/);
  });

  it("leaves out an implausible duration", () => {
    const recap = buildWorkoutRecap({
      exercises: [exercise("Goblet Squat", [{ reps: 10, weight: 35 }])],
      previous: new Map(),
      firstWorkout: true,
      durationSec: 9 * 3600,
    });
    expect(recap.lines[0]).toBe("1 move, 1 set, 10 reps.");
  });
});

describe("nextPlannedDay / trainingDaysPerWeek", () => {
  it("finds the next training day after the given date, wrapping the week", () => {
    expect(nextPlannedDay(PLAN_DAYS, "2026-10-12")).toEqual({ dayKey: "Wed", name: "Full Body B" }); // a Monday
    expect(nextPlannedDay(PLAN_DAYS, "2026-10-16")).toEqual({ dayKey: "Mon", name: "Full Body A" }); // a Friday
    expect(nextPlannedDay(undefined, "2026-10-12")).toBeUndefined();
    expect(trainingDaysPerWeek(PLAN_DAYS)).toBe(3);
  });
});

describe("welcomeMessage", () => {
  it("points a new user at today's light first session, by name when known", () => {
    const text = welcomeMessage({ name: "Sam", daysPerWeek: 3, returning: false });
    expect(text.startsWith("Welcome, Sam.")).toBe(true);
    expect(text).toMatch(/3 days a week/);
    expect(text).toMatch(/first session is today/);
    expect(welcomeMessage({ daysPerWeek: 1, returning: false })).toMatch(/^Welcome\. Your plan is set: 1 day a week/);
  });

  it("doesn't call it a first session for someone who has trained before", () => {
    expect(welcomeMessage({ daysPerWeek: 4, returning: true })).not.toMatch(/first session/);
  });
});
