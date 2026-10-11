import { describe, expect, it } from "vitest";
import { planStructure, selectPlanDays } from "../../../src/onboarding/flow.js";

// Fixture: a minimal 7-day seed with distinguishable names so the test can
// see which seed day ended up where. Each "training" day has at least one
// exercise — selectPlanDays only uses seed days whose exercises array is
// non-empty.
const SEED = {
  Mon: { name: "Push", muscles: ["chest"], exercises: [{ name: "Bench" }] },
  Tue: { name: "Pull", muscles: ["back"], exercises: [{ name: "Row" }] },
  Wed: { name: "Push2", muscles: ["chest"], exercises: [{ name: "OHP" }] },
  Thu: { name: "Legs", muscles: ["legs"], exercises: [{ name: "Squat" }] },
  Fri: { name: "Pull2", muscles: ["back"], exercises: [{ name: "Pulldown" }] },
  Sat: { name: "Pull3", muscles: ["back"], exercises: [{ name: "Curl" }] },
  Sun: { name: "Pull4", muscles: ["back"], exercises: [{ name: "Shrug" }] },
} as Parameters<typeof selectPlanDays>[0];

// Helper: which weekday labels in the returned plan have exercises (i.e.
// are training days vs. rest days)?
function trainingDayKeys(
  plan: ReturnType<typeof selectPlanDays>,
): string[] {
  return Object.entries(plan)
    .filter(([, day]) => (day.exercises?.length ?? 0) > 0)
    .map(([key]) => key);
}

describe("selectPlanDays — distributes training days across the week", () => {
  it("3_days_per_week_uses_Mon_Wed_Fri_not_Mon_Tue_Wed", () => {
    // The bug we're closing: pre-fix this returned ["Mon", "Tue", "Wed"]
    // and four straight rest days. Canonical 3-day split is M/W/F.
    const plan = selectPlanDays(SEED, 3);
    expect(trainingDayKeys(plan)).toEqual(["Mon", "Wed", "Fri"]);
    expect(plan.Tue.name).toBe("Rest");
    expect(plan.Thu.name).toBe("Rest");
    expect(plan.Sat.name).toBe("Rest");
    expect(plan.Sun.name).toBe("Rest");
  });

  it("4_days_per_week_uses_upper_lower_split_pattern", () => {
    const plan = selectPlanDays(SEED, 4);
    expect(trainingDayKeys(plan)).toEqual(["Mon", "Tue", "Thu", "Fri"]);
    expect(plan.Wed.name).toBe("Rest");
    expect(plan.Sat.name).toBe("Rest");
    expect(plan.Sun.name).toBe("Rest");
  });

  it("5_days_keeps_a_midweek_break_on_Thu", () => {
    const plan = selectPlanDays(SEED, 5);
    expect(trainingDayKeys(plan)).toEqual(["Mon", "Tue", "Wed", "Fri", "Sat"]);
    expect(plan.Thu.name).toBe("Rest");
    expect(plan.Sun.name).toBe("Rest");
  });

  it("7_days_trains_every_day_no_rest_inserted", () => {
    const plan = selectPlanDays(SEED, 7);
    expect(trainingDayKeys(plan)).toEqual([
      "Mon",
      "Tue",
      "Wed",
      "Thu",
      "Fri",
      "Sat",
      "Sun",
    ]);
  });

  it("1_day_per_week_picks_Mon_only", () => {
    const plan = selectPlanDays(SEED, 1);
    expect(trainingDayKeys(plan)).toEqual(["Mon"]);
  });

  it("honors_preferredDays_when_user_listed_enough_of_them", () => {
    // User said they want to train Tue/Thu/Sat (e.g. lifting around a job
    // that keeps them busy other days). Honor it, don't override.
    const plan = selectPlanDays(SEED, 3, ["Tue", "Thu", "Sat"]);
    expect(trainingDayKeys(plan)).toEqual(["Tue", "Thu", "Sat"]);
  });

  it("falls_back_to_canonical_when_preferredDays_is_too_short", () => {
    // User said "Mon, Wed" but wants to train 3 days a week. Don't drop
    // them down to 2 — pick the canonical 3-day spread instead.
    const plan = selectPlanDays(SEED, 3, ["Mon"]);
    expect(trainingDayKeys(plan)).toEqual(["Mon", "Wed", "Fri"]);
  });

  it("clamps_daysPerWeek_to_valid_range", () => {
    // Negative, zero, or huge inputs shouldn't blow up.
    expect(trainingDayKeys(selectPlanDays(SEED, 0))).toEqual(["Mon"]);
    expect(trainingDayKeys(selectPlanDays(SEED, -3))).toEqual(["Mon"]);
    expect(trainingDayKeys(selectPlanDays(SEED, 99))).toEqual([
      "Mon",
      "Tue",
      "Wed",
      "Thu",
      "Fri",
      "Sat",
      "Sun",
    ]);
  });
});

describe("selectPlanDays — the structure follows the recommended focus", () => {
  const names = (plan: ReturnType<typeof selectPlanDays>) =>
    Object.values(plan).filter((d) => d.exercises.length).map((d) => d.name);

  it("full_body builds full-body sessions from the seed, not the push/pull rotation", () => {
    const plan = selectPlanDays(SEED, 3, undefined, "full_body");
    expect(names(plan)).toEqual(["Full body · A", "Full body · B", "Full body · C"]);
    const monday = plan.Mon.exercises.map((e) => e.name);
    // A lower-body lift, a push and a pull, each from a different seed day.
    expect(monday).toContain("Squat");
    expect(monday).toContain("Bench");
    expect(monday).toContain("Row");
  });

  it("myo_recommended on three days is full body, same as the recommendation says", () => {
    expect(planStructure("myo_recommended", 3)).toBe("full_body");
    expect(planStructure(undefined, 3)).toBe("full_body");
    expect(selectPlanDays(SEED, 3).Mon.name).toBe("Full body · A");
  });

  it("myo_recommended on five days is a split", () => {
    expect(planStructure("myo_recommended", 5)).toBe("split");
    expect(selectPlanDays(SEED, 5, undefined, "myo_recommended").Mon.name).toBe("Push");
  });

  it("a three-day split has a legs day, not push / pull / push", () => {
    const plan = selectPlanDays(SEED, 3, undefined, "muscle_split");
    expect(names(plan)).toEqual(["Push", "Pull", "Legs"]);
  });

  it("a split never hands out the seed's padded duplicate days", () => {
    const plan = selectPlanDays(SEED, 7, undefined, "muscle_split");
    expect(names(plan).slice(0, 5)).toEqual(["Push", "Pull", "Legs", "Push2", "Pull2"]);
  });
});
