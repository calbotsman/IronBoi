import { describe, expect, it } from "vitest";
import {
  attachDefaultProgression,
  defaultProgressionFor,
  progressionLabel,
} from "../../../src/workouts/progressionDefaults.js";
import { selectPlanDays } from "../../../src/onboarding/flow.js";

describe("default progression rules", () => {
  it("picks a rule from the catalog load class and never for bodyweight, unknown, or unloaded work", () => {
    // Barbell: plates exist in 2.5s. Squat/bench/deadlift +5/wk; the press
    // and rows stall sooner; bar isolation every other week.
    expect(defaultProgressionFor("Barbell Bench Press", 155)).toEqual({ mode: "linear_lb", amount: 5, everyWeeks: 1, capMultiple: 1.3 });
    expect(defaultProgressionFor("Overhead Press", 95)).toMatchObject({ amount: 2.5, everyWeeks: 1 });
    expect(defaultProgressionFor("Bent-over Barbell Row", 135)).toMatchObject({ amount: 5, everyWeeks: 2 });
    expect(defaultProgressionFor("Skull Crushers", 65)).toMatchObject({ amount: 5, everyWeeks: 2 });
    // Dumbbells go up 5 lb a hand: slower cadence, never a 2.5 half-step.
    expect(defaultProgressionFor("Incline Dumbbell Press", 60)).toEqual({ mode: "linear_lb", amount: 5, everyWeeks: 2, capMultiple: 1.3 });
    expect(defaultProgressionFor("Lateral Raises", 20)).toMatchObject({ amount: 5, everyWeeks: 4 });
    expect(defaultProgressionFor("Bulgarian Split Squat", 35)).toMatchObject({ amount: 5, everyWeeks: 4 });
    // Fixed implements have no loadable step.
    expect(defaultProgressionFor("KB Clean & Press", 53)).toBeUndefined();
    expect(defaultProgressionFor("KB Halo", 35)).toBeUndefined();
    expect(defaultProgressionFor("Heavy Club Mill", 15)).toBeUndefined();
    expect(defaultProgressionFor("Diamond Push-ups", 0)).toBeUndefined();
    expect(defaultProgressionFor("Barbell Bench Press", 0)).toBeUndefined();
    expect(defaultProgressionFor("Some Exercise Nobody Knows", 100)).toBeUndefined();
  });

  it("attaches rules only where missing and returns the same object when nothing changes", () => {
    const days = {
      Mon: {
        name: "Push", muscles: [],
        exercises: [
          { name: "Barbell Bench Press", sets: 5, reps: 8, weight: 155 },
          { name: "Diamond Push-ups", sets: 3, reps: 15, weight: 0 },
          { name: "Overhead Press", sets: 5, reps: 6, weight: 95, progression: { mode: "none" as const, amount: 0, everyWeeks: 1, capMultiple: 1.5 } },
        ],
      },
      Tue: { name: "Rest", muscles: [], exercises: [] },
    };
    const first = attachDefaultProgression(days);
    expect(first.changed).toBe(true);
    expect(first.days.Mon.exercises[0].progression).toMatchObject({ mode: "linear_lb", amount: 5 });
    expect(first.days.Mon.exercises[1].progression).toBeUndefined();
    // An explicit "none" is a coach decision and is respected.
    expect(first.days.Mon.exercises[2].progression).toEqual({ mode: "none", amount: 0, everyWeeks: 1, capMultiple: 1.5 });
    expect(first.days.Tue).toBe(days.Tue);

    const second = attachDefaultProgression(first.days);
    expect(second.changed).toBe(false);
    expect(second.days).toBe(first.days);
  });

  it("labels rules the way the coach and cards show them", () => {
    expect(progressionLabel({ mode: "linear_lb", amount: 5, everyWeeks: 1, capMultiple: 1.3 })).toBe("+5 lb/wk");
    expect(progressionLabel({ mode: "linear_lb", amount: 2.5, everyWeeks: 2, capMultiple: 1.5 })).toBe("+2.5 lb/2wk");
    expect(progressionLabel({ mode: "percent", amount: 2, everyWeeks: 1, capMultiple: 1.5 })).toBe("+2%/wk");
    expect(progressionLabel({ mode: "none", amount: 0, everyWeeks: 1, capMultiple: 1.5 })).toBeUndefined();
    expect(progressionLabel(undefined)).toBeUndefined();
  });

  it("selectPlanDays hands every loaded catalog exercise a rule, so a generated plan progresses from day one", () => {
    const seed = {
      Mon: { name: "Push", muscles: [], exercises: [
        { name: "Barbell Bench Press", sets: 5, reps: 8, weight: 155 },
        { name: "Diamond Push-ups", sets: 3, reps: 15, weight: 0 },
      ] },
      Tue: { name: "Rest", muscles: [], exercises: [] },
      Wed: { name: "Rest", muscles: [], exercises: [] },
      Thu: { name: "Rest", muscles: [], exercises: [] },
      Fri: { name: "Rest", muscles: [], exercises: [] },
      Sat: { name: "Rest", muscles: [], exercises: [] },
      Sun: { name: "Rest", muscles: [], exercises: [] },
    } as Parameters<typeof selectPlanDays>[0];
    const plan = selectPlanDays(seed, 1);
    const training = Object.values(plan).find((day) => day.exercises.length > 0);
    expect(training?.exercises[0].progression).toMatchObject({ mode: "linear_lb", amount: 5, everyWeeks: 1 });
    expect(training?.exercises[1].progression).toBeUndefined();
  });
});
