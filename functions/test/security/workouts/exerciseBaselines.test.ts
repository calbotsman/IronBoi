import { describe, expect, it } from "vitest";
import {
  applyBaselinesToDay,
  applyProgression,
  deriveBaselineSuggestions,
  resolvePrescribedWeight,
  roundToPlate,
  weeksBetween,
  type BaselineMap,
} from "../../../src/workouts/exerciseBaselines.js";
import { normalizeExerciseKey } from "../../../src/workouts/exerciseCatalog.js";

// Pure progression/anchoring math — no emulator.

function baselineMap(
  entries: Array<{ name: string; anchorWeightLb: number; anchorDate: string }>,
): BaselineMap {
  const map: BaselineMap = new Map();
  for (const entry of entries) {
    map.set(normalizeExerciseKey(entry.name), {
      userId: "u",
      exerciseKey: normalizeExerciseKey(entry.name),
      exerciseName: entry.name,
      anchorWeightLb: entry.anchorWeightLb,
      anchorDate: entry.anchorDate,
      source: "user_session",
      updatedAt: "2026-08-03T00:00:00.000Z",
    });
  }
  return map;
}

describe("roundToPlate", () => {
  it("rounds to the nearest 2.5 lb", () => {
    expect(roundToPlate(31.2)).toBe(30);
    expect(roundToPlate(31.3)).toBe(32.5);
    expect(roundToPlate(30)).toBe(30);
    expect(roundToPlate(0)).toBe(0);
    expect(roundToPlate(-5)).toBe(0);
  });
});

describe("weeksBetween", () => {
  it("counts whole weeks and never goes negative", () => {
    expect(weeksBetween("2026-08-03", "2026-08-03")).toBe(0);
    expect(weeksBetween("2026-08-03", "2026-08-09")).toBe(0);
    expect(weeksBetween("2026-08-03", "2026-08-10")).toBe(1);
    expect(weeksBetween("2026-08-03", "2026-08-31")).toBe(4);
    expect(weeksBetween("2026-08-03", "2026-07-01")).toBe(0);
  });
});

describe("applyProgression", () => {
  it("holds the anchor with no rule at all", () => {
    expect(applyProgression(30, undefined, 10)).toBe(30);
  });

  it("holds the anchor for mode none", () => {
    expect(applyProgression(30, { mode: "none", amount: 0, everyWeeks: 1, capMultiple: 1.5 }, 10)).toBe(30);
  });

  it("adds a fixed amount on schedule", () => {
    const rule = { mode: "linear_lb" as const, amount: 5, everyWeeks: 1, capMultiple: 3 };
    expect(applyProgression(30, rule, 0)).toBe(30);
    expect(applyProgression(30, rule, 1)).toBe(35);
    expect(applyProgression(30, rule, 3)).toBe(45);
  });

  it("respects everyWeeks — a fortnightly rule does not fire weekly", () => {
    const rule = { mode: "linear_lb" as const, amount: 5, everyWeeks: 2, capMultiple: 3 };
    expect(applyProgression(30, rule, 1)).toBe(30);
    expect(applyProgression(30, rule, 2)).toBe(35);
    expect(applyProgression(30, rule, 3)).toBe(35);
    expect(applyProgression(30, rule, 4)).toBe(40);
  });

  it("percent mode is linear on the anchor, not compounding", () => {
    const rule = { mode: "percent" as const, amount: 10, everyWeeks: 1, capMultiple: 3 };
    // 100 + (10% of 100) x 3 = 130. Compounding would give 133.1 — over a
    // long program that difference is the coach silently outrunning the user.
    expect(applyProgression(100, rule, 3)).toBe(130);
  });

  it("caps at capMultiple so an abandoned program cannot run away", () => {
    const rule = { mode: "linear_lb" as const, amount: 10, everyWeeks: 1, capMultiple: 1.5 };
    expect(applyProgression(100, rule, 100)).toBe(150);
  });

  it("leaves a bodyweight movement at zero", () => {
    const rule = { mode: "percent" as const, amount: 10, everyWeeks: 1, capMultiple: 1.5 };
    expect(applyProgression(0, rule, 5)).toBe(0);
  });
});

describe("resolvePrescribedWeight", () => {
  it("falls back to the plan's own weight when no anchor exists", () => {
    // This is every user before this feature shipped — behavior must not change.
    const weight = resolvePrescribedWeight(
      { name: "Barbell Bench Press", weight: 60 },
      new Map(),
      "2026-08-03",
    );
    expect(weight).toBe(60);
  });

  it("the anchor wins over the plan's number", () => {
    // The user dropped to 30 and confirmed it. The plan still says 60; the
    // anchor is what they lift.
    const weight = resolvePrescribedWeight(
      { name: "Barbell Bench Press", weight: 60 },
      baselineMap([{ name: "Barbell Bench Press", anchorWeightLb: 30, anchorDate: "2026-08-03" }]),
      "2026-08-03",
    );
    expect(weight).toBe(30);
  });

  it("progression runs from the NEW anchor, not the old plan weight", () => {
    // The whole point of the "it depends on the protocol" answer: dropping to
    // 30 under a +5 lb/week rule means week two is 35, not 65.
    const baselines = baselineMap([
      { name: "Barbell Bench Press", anchorWeightLb: 30, anchorDate: "2026-08-03" },
    ]);
    const exercise = {
      name: "Barbell Bench Press",
      weight: 60,
      progression: { mode: "linear_lb" as const, amount: 5, everyWeeks: 1, capMultiple: 3 },
    };
    expect(resolvePrescribedWeight(exercise, baselines, "2026-08-03")).toBe(30);
    expect(resolvePrescribedWeight(exercise, baselines, "2026-08-10")).toBe(35);
    expect(resolvePrescribedWeight(exercise, baselines, "2026-08-24")).toBe(45);
  });
});

describe("deriveBaselineSuggestions", () => {
  it("suggests the weight actually worked when it differs from the target", () => {
    const suggestions = deriveBaselineSuggestions([
      {
        name: "Barbell Bench Press",
        targetWeight: 60,
        completedSets: [
          { completed: true, weight: 30 },
          { completed: true, weight: 30 },
          { completed: true, weight: 30 },
        ],
      },
    ]);
    expect(suggestions).toEqual([{ exerciseName: "Barbell Bench Press", fromLb: 60, toLb: 30 }]);
  });

  it("suggests upward moves too", () => {
    const suggestions = deriveBaselineSuggestions([
      {
        name: "Barbell Bench Press",
        targetWeight: 60,
        completedSets: [
          { completed: true, weight: 70 },
          { completed: true, weight: 70 },
        ],
      },
    ]);
    expect(suggestions[0].toLb).toBe(70);
  });

  it("uses the mode, so one stray set does not move the baseline", () => {
    const suggestions = deriveBaselineSuggestions([
      {
        name: "Barbell Bench Press",
        targetWeight: 60,
        completedSets: [
          { completed: true, weight: 30 },
          { completed: true, weight: 30 },
          { completed: true, weight: 30 },
          { completed: true, weight: 95 },
        ],
      },
    ]);
    expect(suggestions[0].toLb).toBe(30);
  });

  it("ignores sets that were never completed", () => {
    const suggestions = deriveBaselineSuggestions([
      {
        name: "Barbell Bench Press",
        targetWeight: 60,
        completedSets: [
          { completed: true, weight: 60 },
          { completed: false, weight: 20 },
        ],
      },
    ]);
    expect(suggestions).toEqual([]);
  });

  it("stays quiet when the user lifted exactly what was prescribed", () => {
    const suggestions = deriveBaselineSuggestions([
      {
        name: "Barbell Bench Press",
        targetWeight: 60,
        completedSets: [{ completed: true, weight: 60 }],
      },
    ]);
    expect(suggestions).toEqual([]);
  });

  it("stays quiet for bodyweight movements", () => {
    const suggestions = deriveBaselineSuggestions([
      {
        name: "Push-ups",
        targetWeight: 0,
        completedSets: [{ completed: true, weight: 0 }],
      },
    ]);
    expect(suggestions).toEqual([]);
  });

  it("skips an exercise with nothing completed at all", () => {
    const suggestions = deriveBaselineSuggestions([
      {
        name: "Barbell Bench Press",
        targetWeight: 60,
        completedSets: [{ completed: false, weight: 30 }],
      },
    ]);
    expect(suggestions).toEqual([]);
  });
});

describe("applyBaselinesToDay", () => {
  it("rewrites only the exercises that have an anchor", () => {
    const day = {
      name: "Push",
      muscles: ["Chest"],
      exercises: [
        { name: "Barbell Bench Press", sets: 3, reps: 8, weight: 60 },
        { name: "Push-ups", sets: 3, reps: 12, weight: 0 },
      ],
    };
    const patched = applyBaselinesToDay(
      day,
      baselineMap([{ name: "Barbell Bench Press", anchorWeightLb: 30, anchorDate: "2026-08-03" }]),
      "2026-08-03",
    );
    expect(patched.exercises[0].weight).toBe(30);
    expect(patched.exercises[1].weight).toBe(0);
  });

  it("returns the SAME object when nothing changed", () => {
    // Identity is the signal callers use to skip a Firestore write entirely.
    const day = {
      name: "Push",
      muscles: [],
      exercises: [{ name: "Barbell Bench Press", sets: 3, reps: 8, weight: 60 }],
    };
    expect(applyBaselinesToDay(day, new Map(), "2026-08-03")).toBe(day);
  });
});
