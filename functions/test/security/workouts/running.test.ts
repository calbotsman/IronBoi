import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { buildCoachToolRegistry } from "../../../src/coach/toolRegistry.js";
import { claimsPlanChange } from "../../../src/coach/honesty.js";
import { executeTool } from "../../../src/tools/executor.js";
import { updateTrainingSetup } from "../../../src/workouts/trainingSetup.js";
import { applyRunning, runDays } from "../../../src/workouts/running.js";
import { profilePath, workoutPlanPath } from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

// "Add my runs to my plan": Josh, 2026-10-15, three runs a week of about two
// miles, Mon/Tue/Wed, then Friday too. The coach said it had and nothing
// changed. Now the runs are real sessions and the lifting is fitted round them.

const USER_ID = "running-user-a";
let app: App;
let db: Firestore;

const fullBody = (name: string) => ({
  name,
  muscles: ["Quads", "Chest", "Back"],
  exercises: [
    { name: "Goblet Squat", sets: 3, reps: 10, weight: 35 },
    { name: "Dumbbell Shoulder Press", sets: 3, reps: 10, weight: 25 },
    { name: "Bent-over Barbell Row", sets: 3, reps: 10, weight: 65 },
  ],
});

describe("runs in the plan", () => {
  it("lift days keep their lifting with an easy run after; other days become runs; legs lose a set", () => {
    const days = applyRunning(
      { Mon: fullBody("Full body A"), Wed: fullBody("Full body B"), Fri: fullBody("Full body C") },
      { days: ["Mon", "Tue", "Wed", "Fri"], milesPerRun: 2 },
    );
    expect(days.Mon!.runs).toEqual([{ kind: "easy", distanceMi: 2, note: "After lifting, at an easy pace" }]);
    expect(days.Tue).toEqual({ name: "Easy run", muscles: [], exercises: [], runs: [{ kind: "easy", distanceMi: 2 }] });
    // Squats on a run day: one set less. Upper body untouched.
    expect(days.Mon!.exercises.map((e) => e.sets)).toEqual([2, 3, 3]);
    expect(days.Thu).toBeUndefined();
  });

  it("legs the day before a run lose a set too", () => {
    const days = applyRunning({ Mon: fullBody("A") }, { days: ["Tue"], minutesPerRun: 30 });
    expect(days.Mon!.exercises[0]!.sets).toBe(2);
    expect(days.Tue!.runs).toEqual([{ kind: "easy", durationMin: 30 }]);
  });

  it("without days, runs go on the days they don't lift", () => {
    const lifting = { Mon: fullBody("A"), Wed: fullBody("B"), Fri: fullBody("C") };
    expect(runDays(lifting, { runsPerWeek: 3 })).toEqual(["Tue", "Thu", "Sat"]);
  });

  it("no running: the plan is as it was, with no runs left over", () => {
    const days = applyRunning({ Mon: { ...fullBody("A"), runs: [{ kind: "easy", distanceMi: 2 }] } }, undefined);
    expect(days.Mon!.runs).toBeUndefined();
    expect(days.Mon!.exercises[0]!.sets).toBe(3);
  });
});

describe("the coach can't fake a plan change", () => {
  it("spots a claimed change", () => {
    expect(claimsPlanChange("I've noted that you'd like to run on Monday. I'll factor this into your plan.")).toBe(true);
    expect(claimsPlanChange("I’ve added a run on Friday to your week.")).toBe(true);
    expect(claimsPlanChange("I'll update your plan once you tell me the days.")).toBe(true);
    expect(claimsPlanChange("Which days do you want to run?")).toBe(false);
    expect(claimsPlanChange("Your plan has goblet squats on Monday.")).toBe(false);
  });
});

describe("adding runs through the setup", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });

  beforeEach(async () => {
    await db.recursiveDelete(db.doc(`users/${USER_ID}`));
    await db.doc(profilePath(USER_ID)).set({
      ...baseProfile,
      userId: USER_ID,
      goals: ["muscle_gain", "fat_loss"],
      trainingExperience: "beginner",
      equipment: ["dumbbells", "kettlebells", "barbell", "bench"],
      schedule: { daysPerWeek: 3, preferredDays: ["Mon", "Wed", "Fri"], sessionLengthMin: 45 },
    });
    await db.doc(workoutPlanPath(USER_ID)).set({ userId: USER_ID, planId: "current", source: "coach_generated", days: {} });
  });

  afterAll(async () => {
    await db.recursiveDelete(db.doc(`users/${USER_ID}`));
    if (app && getApps().length && app.name !== "[DEFAULT]") await deleteApp(app);
  });

  it("the coach's tool puts the runs in the plan, and they survive later changes", async () => {
    const registry = buildCoachToolRegistry(db, { rawUserText: "add my runs, Mon Tue Wed and Fri, about 2 miles" });
    const result = await executeTool(registry, "update_training_setup", {
      running: { days: ["Mon", "Tue", "Wed", "Fri"], milesPerRun: 2 },
    }, { authenticatedUserId: USER_ID }) as Record<string, unknown>;
    expect(result).toMatchObject({ ok: true, rebuiltPlan: true, trainingDays: ["Mon", "Wed", "Fri"] });
    expect(result.runs).toBe("Easy runs on Mon, Tue, Wed, Fri, 2 mi each");

    const days = (await db.doc(workoutPlanPath(USER_ID)).get()).get("days");
    expect(days.Tue.runs).toEqual([{ kind: "easy", distanceMi: 2 }]);
    expect(days.Mon.runs[0].note).toBe("After lifting, at an easy pace");
    expect((await db.doc(profilePath(USER_ID)).get()).get("running")).toEqual({ days: ["Mon", "Tue", "Wed", "Fri"], milesPerRun: 2 });

    // A later change to the lifting keeps the runs.
    await updateTrainingSetup(db, USER_ID, { addEquipment: ["bands"] }, "user");
    expect((await db.doc(workoutPlanPath(USER_ID)).get()).get("days").Tue.runs).toHaveLength(1);

    // Stopped running: the runs come out.
    await updateTrainingSetup(db, USER_ID, { stopRunning: true }, "user");
    const after = (await db.doc(workoutPlanPath(USER_ID)).get()).get("days");
    expect(after.Tue.name).toBe("Rest");
    expect(after.Tue.runs).toBeUndefined();
    expect(after.Mon.runs).toBeUndefined();
    expect((await db.doc(profilePath(USER_ID)).get()).get("running")).toBeUndefined();
  });
});
