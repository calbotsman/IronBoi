import { createRequire } from "node:module";
import { describe, expect, it } from "vitest";
import { equipmentFromAnswer, fitPlanToUser } from "../../../src/workouts/planFit.js";
import { lookupExercise } from "../../../src/workouts/exerciseCatalog.js";
import { selectPlanDays } from "../../../src/onboarding/flow.js";

const require = createRequire(import.meta.url);
const seed = require("../../../src/domain/ironlab-seed.json");

function allExercises(days: Record<string, { exercises: Array<{ name: string; weight: number }> }>) {
  return Object.values(days).flatMap((day) => day.exercises);
}

describe("equipmentFromAnswer", () => {
  it("reads the onboarding answer into catalog equipment", () => {
    expect(equipmentFromAnswer(["Full gym"])).toBeNull();
    expect(equipmentFromAnswer(undefined)).toBeNull();
    expect([...equipmentFromAnswer(["Dumbbells", "Bench"])!].sort()).toEqual(["bench", "dumbbell"]);
    expect([...equipmentFromAnswer(["Bodyweight"])!]).toEqual([]);
    expect(equipmentFromAnswer(["Home gym"])!.has("barbell")).toBe(true);
  });
});

describe("fitPlanToUser — the plan matches their kit and experience", () => {
  it("dumbbells + bench: no barbell, kettlebell or cable work survives", () => {
    const days = selectPlanDays(seed.DEFAULT_PLAN, 3, [], "full_body", {
      equipment: ["Dumbbells", "Bench"],
      experience: "beginner",
    });
    const exercises = allExercises(days);
    expect(exercises.length).toBeGreaterThan(0);
    for (const exercise of exercises) {
      const entry = lookupExercise(exercise.name);
      expect(entry, exercise.name).toBeDefined();
      expect(entry!.equipment.every((item) => ["none", "dumbbell", "bench"].includes(item)), exercise.name).toBe(true);
    }
  });

  it("bodyweight only: every movement needs nothing", () => {
    const days = selectPlanDays(seed.DEFAULT_PLAN, 3, [], "full_body", { equipment: ["Bodyweight"], experience: "new" });
    for (const exercise of allExercises(days)) {
      expect(lookupExercise(exercise.name)!.equipment.every((item) => item === "none"), exercise.name).toBe(true);
    }
  });

  it("beginners start lighter; barbell never below the bar", () => {
    const day = {
      name: "A",
      muscles: [],
      exercises: [
        { name: "Barbell Back Squat", sets: 3, reps: 8, weight: 135 },
        { name: "Barbell Bench Press", sets: 3, reps: 8, weight: 65 },
        { name: "Incline Dumbbell Press", sets: 3, reps: 10, weight: 60 },
      ],
    };
    const fitted = fitPlanToUser({ Mon: day }, { equipment: ["Full gym"], experience: "beginner" }).Mon;
    expect(fitted.exercises.map((e) => e.weight)).toEqual([75, 45, 35]);
    const same = fitPlanToUser({ Mon: day }, { equipment: ["Full gym"], experience: "intermediate" }).Mon;
    expect(same.exercises.map((e) => e.weight)).toEqual([135, 65, 60]);
  });

  it("a full gym and intermediate experience changes nothing", () => {
    const plain = selectPlanDays(seed.DEFAULT_PLAN, 4, [], "muscle_split");
    const fitted = selectPlanDays(seed.DEFAULT_PLAN, 4, [], "muscle_split", { equipment: ["Full gym"], experience: "intermediate" });
    expect(fitted).toEqual(plain);
  });
});

describe("named gear gets used", () => {
  it("dumbbells, a bench and kettlebells: every training day has kettlebell work", () => {
    const days = selectPlanDays(seed.DEFAULT_PLAN, 4, [], "full_body", {
      equipment: ["dumbbells", "bench", "kettlebells"],
      experience: "beginner",
    });
    const training = Object.values(days).filter((d) => d.exercises.length > 0);
    expect(training.length).toBe(4);
    for (const day of training) {
      expect(day.exercises.some((e) => lookupExercise(e.name)?.equipment.includes("kettlebell")), day.name).toBe(true);
      // Dumbbell work stays too.
      expect(day.exercises.some((e) => lookupExercise(e.name)?.equipment.includes("dumbbell")), day.name).toBe(true);
    }
  });

  it("a full gym features nothing, so the plan is unchanged", () => {
    const plain = selectPlanDays(seed.DEFAULT_PLAN, 3, [], "full_body");
    const gym = selectPlanDays(seed.DEFAULT_PLAN, 3, [], "full_body", { equipment: ["full gym"], experience: "intermediate" });
    expect(gym).toEqual(plain);
  });
});

describe("nothing to hold", () => {
  it("bodyweight and bands: no move carries a weight it can't be done with", () => {
    const days = selectPlanDays(seed.DEFAULT_PLAN, 4, [], "full_body", { equipment: ["bodyweight", "bands"], experience: "beginner" });
    for (const exercise of Object.values(days).flatMap((d) => d.exercises)) {
      const entry = lookupExercise(exercise.name)!;
      if (entry.equipment.every((item) => item === "none")) expect(exercise.weight, exercise.name).toBe(0);
    }
  });
});
