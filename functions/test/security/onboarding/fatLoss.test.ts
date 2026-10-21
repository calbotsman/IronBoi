import { describe, expect, it } from "vitest";
import { FAT_LOSS_CARDIO, FAT_LOSS_FINISHER, addFatLossWork } from "../../../src/onboarding/flow.js";

const rest = { name: "Rest", muscles: [], exercises: [] };
const lift = (name: string) => ({ name, muscles: ["Chest"], exercises: [{ name: "Push-ups", sets: 3, reps: 10, weight: 0 }] });
const week = { Mon: lift("A"), Tue: rest, Wed: lift("B"), Thu: rest, Fri: lift("C"), Sat: rest, Sun: rest };

describe("fat-loss plans", () => {
  it("adds a finisher to every lifting day, once", () => {
    const out = addFatLossWork(week, "beginner");
    for (const day of ["Mon", "Wed", "Fri"]) {
      expect(out[day].exercises.at(-1)).toEqual({ name: FAT_LOSS_FINISHER, sets: 3, reps: 8, weight: 0 });
    }
    expect(addFatLossWork(out).Mon.exercises.filter((e) => e.name === FAT_LOSS_FINISHER)).toHaveLength(1);
  });
  it("puts easy cardio on two rest days between lifting days first", () => {
    const out = addFatLossWork(week);
    const cardio = Object.entries(out).filter(([, d]) => d.exercises.some((e) => e.name === FAT_LOSS_CARDIO)).map(([k]) => k);
    expect(cardio).toEqual(["Tue", "Thu"]);
    expect(out.Sat.exercises).toEqual([]);
  });
  it("goes easier on the finisher for someone new", () => {
    expect(addFatLossWork(week, "new").Mon.exercises.at(-1)?.reps).toBe(6);
  });
});
