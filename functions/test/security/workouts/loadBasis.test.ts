import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import {
  IMPLEMENT_PATTERN,
  BAR_PATTERN,
  ONE_OBJECT_PATTERN,
  SINGLE_IMPLEMENT_PATTERN,
  catalogLoadBases,
  loadBasis,
  weightLabel,
  weightPhrase,
} from "../../../src/workouts/loadBasis.js";
import { UNILATERAL_PATTERN, allExercises, isUnilateralExercise } from "../../../src/workouts/exerciseCatalog.js";

// "35" on a dumbbell press used to be a guess: per hand or both? One
// convention: dumbbells and kettlebells count ONE bell, everything else the
// whole load — and the app says which.
describe("load basis", () => {
  it("counts two-bell lifts per hand, single-bell lifts as the bell, barbells as a total", () => {
    expect(loadBasis("Dumbbell Shoulder Press")).toBe("each");
    expect(loadBasis("Arnold Press")).toBe("each"); // catalog equipment, no "dumbbell" in the name
    expect(loadBasis("Farmer Carry")).toBe("each");
    expect(loadBasis("KB Goblet Squat")).toBe("one");
    expect(loadBasis("KB Swing")).toBe("one");
    expect(loadBasis("Single-arm DB Row")).toBe("one");
    expect(loadBasis("Barbell Bench Press")).toBe("bar");
    expect(loadBasis("Deadlift")).toBe("bar");
    expect(loadBasis("Barbell Curl")).toBe("bar");
  });

  it("reads lifts outside the catalog by name", () => {
    expect(loadBasis("Seated Dumbbell Shoulder Press")).toBe("each");
    expect(loadBasis("Seated Arnold Press")).toBe("each");
    expect(loadBasis("Dumbbell Lunges")).toBe("each");
    expect(loadBasis("One-arm Dumbbell Snatch")).toBe("one");
    expect(loadBasis("Kettlebell Goblet Squat")).toBe("one");
    expect(loadBasis("Leg Press")).toBe("total");
    expect(loadBasis("Cable Fly")).toBe("total");
  });

  it("labels the number so it can't be misread", () => {
    expect(weightLabel(35, "Dumbbell Shoulder Press")).toBe("35 lb each");
    expect(weightLabel(35, "KB Swing")).toBe("35 lb");
    expect(weightLabel(135, "Barbell Bench Press")).toBe("135 lb total");
    expect(weightLabel(37.5, "Hammer Curls")).toBe("37.5 lb each");
    expect(weightPhrase(35, "Dumbbell Shoulder Press")).toContain("35 lb in each hand");
    expect(weightPhrase(35, "Dumbbell Shoulder Press")).toContain("70 lb total");
  });
});

describe("load basis agrees with the app", () => {
  const swift = fs.readFileSync(
    path.resolve(process.cwd(), "../ios/IronBoi/IronBoi/Models/WeightLoad.swift"),
    "utf8",
  );
  const swiftPattern = (name: string) => swift.match(new RegExp(`static let ${name} = #"([^"]*)"#`))?.[1];

  it("uses the same name patterns", () => {
    expect(swiftPattern("implementPattern")).toBe(IMPLEMENT_PATTERN);
    expect(swiftPattern("singleImplementPattern")).toBe(SINGLE_IMPLEMENT_PATTERN);
    expect(swiftPattern("oneObjectPattern")).toBe(ONE_OBJECT_PATTERN);
    expect(swiftPattern("barPattern")).toBe(BAR_PATTERN);
  });

  it("has the same per-lift table as the catalog's equipment gives", () => {
    const block = swift.match(/static let catalogBasis: \[String: LoadBasis\] = \[([\s\S]*?)\n {4}\]/);
    expect(block, "WeightLoad.catalogBasis").not.toBeNull();
    const ios: Record<string, string> = {};
    for (const m of block![1].matchAll(/"([^"]+)":\s*\.(each|one|bar|total)/g)) ios[m[1]] = m[2];
    expect(Object.keys(ios).length).toBeGreaterThan(10); // a regex miss must not pass vacuously
    expect(ios).toEqual(catalogLoadBases());
  });
});

// "MYO still doesn't recognize sides": single-arm rows and split squats are
// a left and a right per set. The flag is data on both sides, kept equal.
describe("one-side-at-a-time lifts agree with the app", () => {
  const swift = fs.readFileSync(
    path.resolve(process.cwd(), "../ios/IronBoi/IronBoi/Models/ExerciseKnowledge.swift"),
    "utf8",
  );

  it("flags the same catalog lifts", () => {
    const ios = [...swift.matchAll(/^\s*"([^"]+)": \.init\(.*unilateral: true\)/gm)].map((m) => m[1]).sort();
    const server = allExercises().filter((entry) => entry.unilateral).map((entry) => entry.name).sort();
    expect(ios.length).toBeGreaterThan(5);
    expect(ios).toEqual(server);
  });

  it("reads other lifts by the same name pattern", () => {
    expect(swift.match(/static let unilateralPattern = #"([^"]*)"#/)?.[1]).toBe(UNILATERAL_PATTERN);
    expect(isUnilateralExercise("Single-arm DB Row")).toBe(true);
    expect(isUnilateralExercise("Bulgarian Split Squat")).toBe(true);
    expect(isUnilateralExercise("Single-arm Kettlebell Press")).toBe(true); // by name
    expect(isUnilateralExercise("Dumbbell Shoulder Press")).toBe(false);
    expect(isUnilateralExercise("Barbell Back Squat")).toBe(false);
  });
});
