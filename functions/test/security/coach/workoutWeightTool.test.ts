import { describe, expect, it } from "vitest";
import { SET_WORKOUT_WEIGHT, SetWorkoutWeightArgs, runSetWorkoutWeight } from "../../../src/coach/workoutWeightTool.js";
import { liveToolDeclarations } from "../../../src/coach/liveSession.js";
import { liveWorkoutRules } from "../../../src/coach/liveWorkout.js";

const live = {
  workoutName: "Push",
  exercise: "Dumbbell Shoulder Press",
  exerciseNumber: 2,
  setNumber: 2,
  totalSets: 3,
  targetReps: 10,
  weightLb: 35,
  exercises: ["Barbell Bench Press", "Dumbbell Shoulder Press", "Lateral Raises"],
};

// 2026-11-05: "I'm increasing the weight" mid-workout changed nothing. The
// coach now has a tool for it; the phone applies what it decides.
describe("set_workout_weight", () => {
  it("sets a new number on the lift they're on", () => {
    const { result, action } = runSetWorkoutWeight({ weight: 40 }, live);
    expect(action).toEqual({ type: "set_weight", exerciseName: "Dumbbell Shoulder Press", toLb: 40 });
    expect(result).toMatchObject({ ok: true, nowLb: 40 });
    expect(String(result.say)).toContain("40 lb in each hand");
  });

  it("applies a difference to the current weight", () => {
    const { result, action } = runSetWorkoutWeight({ change: 5 }, live);
    expect(action).toMatchObject({ type: "set_weight", byLb: 5 });
    expect(result.nowLb).toBe(40);
    expect(runSetWorkoutWeight({ change: -10 }, live).result.nowLb).toBe(25);
  });

  it("halves a total on a two-dumbbell lift, but not on a barbell", () => {
    expect(runSetWorkoutWeight({ weight: 80, basis: "total" }, live).result.nowLb).toBe(40);
    const bench = runSetWorkoutWeight(
      { weight: 155, basis: "total", exerciseName: "barbell bench press" },
      { ...live, exercise: "Barbell Bench Press", weightLb: 135 },
    );
    expect(bench.result.nowLb).toBe(155);
  });

  it("converts kilos onto the 2.5 lb grid like the phone does", () => {
    expect(runSetWorkoutWeight({ weight: 20, unit: "kg" }, live).action).toMatchObject({ toLb: 45 });
  });

  it("with no number, tells the phone to listen for one and the coach to ask", () => {
    const { result, action } = runSetWorkoutWeight({}, live);
    expect(action).toEqual({ type: "ask_weight", exerciseName: "Dumbbell Shoulder Press" });
    expect(result).toMatchObject({ ok: true, waitingForNumber: true });
    expect(String(result.say)).toContain("Up to what?");
  });

  it("targets another lift by name, and refuses ones not in the workout", () => {
    const other = runSetWorkoutWeight({ exerciseName: "lateral raises", weight: 15 }, live);
    expect(other.action).toMatchObject({ exerciseName: "Lateral Raises", toLb: 15 });
    expect(other.result.nowLb).toBe(15);
    const missing = runSetWorkoutWeight({ exerciseName: "Deadlift", weight: 200 }, live);
    expect(missing.action).toBeUndefined();
    expect(missing.result).toMatchObject({ ok: false, error: "exercise_not_in_workout" });
  });

  it("refuses bad calls and calls outside a workout", () => {
    expect(runSetWorkoutWeight({ weight: 40 }, undefined).result).toMatchObject({ ok: false });
    expect(runSetWorkoutWeight({ weight: 40, change: 5 }, live).action).toBeUndefined();
    expect(runSetWorkoutWeight({ weight: -5 }, live).action).toBeUndefined();
    expect(runSetWorkoutWeight({ weight: 40, userId: "x" }, live).action).toBeUndefined();
    expect(SetWorkoutWeightArgs.safeParse({ change: 0 }).success).toBe(false);
  });

  it("is a phone tool in live voice and named in the workout prompt", () => {
    expect(liveToolDeclarations().some((tool) => tool.name === SET_WORKOUT_WEIGHT.name)).toBe(true);
    const rules = liveWorkoutRules(live) ?? "";
    expect(rules).toContain("set_workout_weight");
    expect(rules).toContain("Up to what?");
    expect(rules).toContain("35 lb in each hand");
    expect(rules).toContain("35 each hand?");
    const barbell = liveWorkoutRules({ ...live, exercise: "Barbell Bench Press", weightLb: 135 }) ?? "";
    expect(barbell).toContain("135 lb total");
    expect(barbell).not.toContain("each hand?");
  });

  it("tells the coach reps are per side on one-side-at-a-time lifts", () => {
    const row = liveWorkoutRules({ ...live, exercise: "Single-arm DB Row", weightLb: 30 }) ?? "";
    expect(row).toContain("PER SIDE");
    expect(row).toContain("10 each side");
    expect(liveWorkoutRules({ ...live, eachSide: true }) ?? "").toContain("PER SIDE");
    expect(liveWorkoutRules(live) ?? "").not.toContain("PER SIDE");
  });
});
