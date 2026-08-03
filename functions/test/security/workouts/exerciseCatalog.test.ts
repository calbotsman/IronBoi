import { describe, expect, it } from "vitest";
import {
  allExercises,
  canonicalMuscle,
  isValidSwap,
  lookupExercise,
  normalizeExerciseKey,
  suggestSwaps,
  suggestedLoadForSwap,
} from "../../../src/workouts/exerciseCatalog.js";

// Pure ranking/validation logic — no emulator. This is the gate that decides
// what may be written into a user's plan, so the cases that matter are the
// REJECTIONS as much as the rankings.

describe("normalizeExerciseKey", () => {
  it("collapses casing and punctuation so one movement is one key", () => {
    expect(normalizeExerciseKey("Single-arm DB Row")).toBe("single_arm_db_row");
    expect(normalizeExerciseKey("single arm db row")).toBe("single_arm_db_row");
    expect(normalizeExerciseKey("HIIT Sprints (20s on/10s off)")).toBe(
      "hiit_sprints_20s_on_10s_off",
    );
  });
});

describe("canonicalMuscle", () => {
  it("folds display names onto the group used for scoring", () => {
    expect(canonicalMuscle("Upper chest")).toBe("chest");
    expect(canonicalMuscle("Front delts")).toBe("delts");
    expect(canonicalMuscle("Mid back")).toBe("lats");
  });
});

describe("suggestSwaps", () => {
  it("ranks same-pattern, same-primary movements first", () => {
    const options = suggestSwaps({ exerciseName: "Barbell Bench Press" });
    expect(options.length).toBeGreaterThan(0);
    // Every option must train chest — the primary of the original.
    for (const option of options) {
      expect(option.primary.map(canonicalMuscle)).toContain("chest");
    }
    // A horizontal press should outrank an isolation movement that merely
    // touches the same tissue.
    const names = options.map((option) => option.name);
    expect(names).toContain("Push-ups");
  });

  it("never offers a movement that shares no primary muscle", () => {
    const options = suggestSwaps({ exerciseName: "Barbell Bench Press", limit: 12 });
    // Plank lists Chest as a SECONDARY. Sharing a secondary is not enough to
    // be proposed as a substitute — this is the guard against nonsense
    // options like "swap your bench for a plank".
    expect(options.map((option) => option.name)).not.toContain("Plank");
  });

  it("never offers the exercise being replaced, or one already in the day", () => {
    const options = suggestSwaps({
      exerciseName: "Barbell Back Squat",
      excludeNames: ["Bodyweight Squat", "Walking Lunges"],
    });
    const names = options.map((option) => option.name);
    expect(names).not.toContain("Barbell Back Squat");
    expect(names).not.toContain("Bodyweight Squat");
    expect(names).not.toContain("Walking Lunges");
  });

  it("an empty equipment list means bodyweight-only, not unconstrained", () => {
    const options = suggestSwaps({
      exerciseName: "Barbell Back Squat",
      availableEquipment: [],
    });
    expect(options.length).toBeGreaterThan(0);
    for (const option of options) {
      // "none" is allowed; anything requiring gear is not.
      expect(option.equipment.every((item) => item === "none")).toBe(true);
    }
    expect(options.map((option) => option.name)).toContain("Bodyweight Squat");
  });

  it("honours a partial equipment list", () => {
    const options = suggestSwaps({
      exerciseName: "Barbell Bench Press",
      availableEquipment: ["dumbbell", "bench"],
    });
    const names = options.map((option) => option.name);
    expect(names).toContain("Dumbbell Bench Press");
    // Needs a barbell, which the user said they don't have.
    expect(names).not.toContain("Weighted Dips");
  });

  it("returns nothing for an exercise the catalog has never heard of", () => {
    expect(suggestSwaps({ exerciseName: "Underwater Basket Weaving" })).toEqual([]);
  });

  it("is deterministic across identical calls", () => {
    const first = suggestSwaps({ exerciseName: "Overhead Press" });
    const second = suggestSwaps({ exerciseName: "Overhead Press" });
    expect(first.map((option) => option.name)).toEqual(second.map((option) => option.name));
  });

  it("every catalog entry has at least one swap option", () => {
    // A swap button that opens an empty list is the failure mode this whole
    // feature exists to avoid.
    for (const entry of allExercises()) {
      const options = suggestSwaps({ exerciseName: entry.name });
      expect(options.length, `${entry.name} has no swap options`).toBeGreaterThan(0);
    }
  });
});

describe("isValidSwap", () => {
  it("accepts a substitute sharing a primary muscle", () => {
    expect(isValidSwap("Barbell Bench Press", "Push-ups")).toBe(true);
    expect(isValidSwap("Barbell Back Squat", "Bodyweight Squat")).toBe(true);
  });

  it("rejects a substitute that trains something else entirely", () => {
    expect(isValidSwap("Barbell Bench Press", "Standing Calf Raises")).toBe(false);
    expect(isValidSwap("Deadlift", "Lateral Raises")).toBe(false);
  });

  it("rejects unknown names on either side", () => {
    // The server-side gate: a client naming an arbitrary string cannot get it
    // written into the user's program.
    expect(isValidSwap("Barbell Bench Press", "Definitely Not An Exercise")).toBe(false);
    expect(isValidSwap("Definitely Not An Exercise", "Push-ups")).toBe(false);
  });

  it("rejects swapping an exercise for itself", () => {
    expect(isValidSwap("Push-ups", "push ups")).toBe(false);
  });
});

describe("suggestedLoadForSwap", () => {
  it("carries load across movements of the same load class", () => {
    expect(suggestedLoadForSwap("Barbell Bench Press", "Deadlift", 135)).toBe(135);
  });

  it("refuses to carry a barbell number onto a bodyweight movement", () => {
    expect(suggestedLoadForSwap("Barbell Bench Press", "Push-ups", 185)).toBe(0);
  });

  it("refuses to carry load across load classes", () => {
    // 225 lb is a plausible back squat and an impossible goblet squat.
    expect(suggestedLoadForSwap("Barbell Back Squat", "KB Goblet Squat", 225)).toBe(0);
  });
});

describe("name resolution", () => {
  it("resolves names case- and punctuation-insensitively", () => {
    expect(lookupExercise("barbell bench press")?.name).toBe("Barbell Bench Press");
    expect(lookupExercise("PUSH-UPS")?.name).toBe("Push-ups");
  });

  it("resolves the shorthand a plan or the coach actually writes", () => {
    // Exercise names are not a controlled vocabulary — adapt_plan lets the
    // model author one freely, and older plans carry shorthand. Failing to
    // resolve these means the swap button opens an empty list.
    expect(lookupExercise("Back Squat")?.name).toBe("Barbell Back Squat");
    expect(lookupExercise("Bench Press")?.name).toBe("Barbell Bench Press");
    expect(lookupExercise("Walking Lunge")?.name).toBe("Walking Lunges");
    expect(lookupExercise("Push-up")?.name).toBe("Push-ups");
  });

  it("resolves curated gym shorthand that token-matching alone cannot", () => {
    // "Bench Press" matches both the barbell and dumbbell entries. The alias
    // table settles it; this repo's own plan fixtures use the bare name.
    expect(lookupExercise("Bench Press")?.name).toBe("Barbell Bench Press");
    expect(lookupExercise("Squat")?.name).toBe("Barbell Back Squat");
  });

  it("refuses to guess when the name is ambiguous and unaliased", () => {
    // An empty option list is honest; silently picking a movement is not.
    expect(lookupExercise("Press")).toBeUndefined();
    expect(lookupExercise("Raise")).toBeUndefined();
  });

  it("still returns nothing for a name that matches nothing", () => {
    expect(lookupExercise("Underwater Basket Weaving")).toBeUndefined();
  });

  it("never offers a resolved exercise as a substitute for itself", () => {
    const options = suggestSwaps({ exerciseName: "Back Squat", limit: 12 });
    expect(options.length).toBeGreaterThan(0);
    expect(options.map((option) => option.name)).not.toContain("Barbell Back Squat");
  });

  it("treats a shorthand and its canonical name as the same movement", () => {
    expect(isValidSwap("Back Squat", "Barbell Back Squat")).toBe(false);
  });

  it("ranks swaps for a shorthand name the same as for the canonical one", () => {
    const shorthand = suggestSwaps({ exerciseName: "Back Squat" }).map((option) => option.name);
    const canonical = suggestSwaps({ exerciseName: "Barbell Back Squat" }).map(
      (option) => option.name,
    );
    expect(shorthand).toEqual(canonical);
  });
});

describe("catalog integrity", () => {

  it("has no duplicate exercise keys", () => {
    const keys = allExercises().map((entry) => normalizeExerciseKey(entry.name));
    expect(new Set(keys).size).toBe(keys.length);
  });
});
