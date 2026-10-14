import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { buildCoachToolRegistry } from "../../../src/coach/toolRegistry.js";
import { executeTool } from "../../../src/tools/executor.js";
import { updateTrainingSetup } from "../../../src/workouts/trainingSetup.js";
import { lookupExercise } from "../../../src/workouts/exerciseCatalog.js";
import { profilePath, workoutPlanPath } from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

// Changing what onboarding asked, later: "4 days a week now, I've got
// kettlebells, building muscle" — by voice (the coach's tool) or on the You
// screen (the callable). Both go through updateTrainingSetup.

const USER_ID = "training-setup-user-a";
let app: App;
let db: Firestore;

const trainingDays = (days: Record<string, { exercises?: unknown[] }>) =>
  ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].filter((d) => (days[d]?.exercises?.length ?? 0) > 0);

describe("updateTrainingSetup", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });

  beforeEach(async () => {
    await db.recursiveDelete(db.doc(`users/${USER_ID}`));
    await db.doc(profilePath(USER_ID)).set({
      ...baseProfile,
      userId: USER_ID,
      goals: ["fat_loss"],
      equipment: ["dumbbells", "bench"],
      schedule: { daysPerWeek: 3, preferredDays: ["Mon", "Wed", "Fri"], sessionLengthMin: 45 },
    });
    await db.doc(workoutPlanPath(USER_ID)).set({ userId: USER_ID, planId: "current", source: "coach_generated", days: {} });
  });

  afterAll(async () => {
    await db.recursiveDelete(db.doc(`users/${USER_ID}`));
    if (app && getApps().length && app.name !== "[DEFAULT]") await deleteApp(app);
  });

  it("4 days, kettlebells, build muscle: saved, and the plan rebuilt to match", async () => {
    const result = await updateTrainingSetup(
      db, USER_ID, { daysPerWeek: 4, equipment: ["kettlebells"], goals: ["muscle_gain"] }, "coach",
    );
    expect(result.rebuiltPlan).toBe(true);
    expect(result.trainingDays).toHaveLength(4);

    const profile = (await db.doc(profilePath(USER_ID)).get()).data()!;
    expect(profile.goals).toEqual(["muscle_gain"]);
    expect(profile.equipment).toEqual(["kettlebells"]);
    expect(profile.schedule.daysPerWeek).toBe(4);
    // The old Mon/Wed/Fri can't hold 4 days: cleared so the builder spreads them.
    expect(profile.schedule.preferredDays).toEqual([]);
    expect(profile.schedule.sessionLengthMin).toBe(45);

    const days = (await db.doc(workoutPlanPath(USER_ID)).get()).get("days");
    expect(trainingDays(days)).toHaveLength(4);
    for (const day of Object.values(days) as Array<{ exercises: Array<{ name: string }> }>) {
      for (const exercise of day.exercises) {
        const entry = lookupExercise(exercise.name);
        expect(entry!.equipment.every((item) => item === "none" || item === "kettlebell"), exercise.name).toBe(true);
      }
    }
  });

  it("'I've got dumbbells too' adds to what they have", async () => {
    await db.doc(profilePath(USER_ID)).set({ equipment: ["kettlebells"] }, { merge: true });
    await updateTrainingSetup(db, USER_ID, { addEquipment: ["dumbbells"] }, "coach");
    expect((await db.doc(profilePath(USER_ID)).get()).get("equipment")).toEqual(["kettlebells", "dumbbells"]);
    await updateTrainingSetup(db, USER_ID, { removeEquipment: ["kettlebell"] }, "coach");
    expect((await db.doc(profilePath(USER_ID)).get()).get("equipment")).toEqual(["dumbbells"]);
  });

  it("named days win, and the time is saved for the phone's reminders", async () => {
    const result = await updateTrainingSetup(
      db, USER_ID, { preferredDays: ["Fri", "Tue", "Sat"], preferredTime: "06:30" }, "user",
    );
    expect(result.trainingDays).toEqual(["Tue", "Fri", "Sat"]);
    const profile = (await db.doc(profilePath(USER_ID)).get()).data()!;
    expect(profile.schedule).toMatchObject({ daysPerWeek: 3, preferredDays: ["Tue", "Fri", "Sat"] });
    expect(profile.preferredTime).toBe("06:30");
    expect(profile.preferences.preferredWorkoutTime).toBe("morning");
  });

  it("a new session length alone saves without rebuilding the plan", async () => {
    const result = await updateTrainingSetup(db, USER_ID, { sessionLengthMin: 30 }, "user");
    expect(result.rebuiltPlan).toBe(false);
    expect((await db.doc(profilePath(USER_ID)).get()).get("schedule.sessionLengthMin")).toBe(30);
  });

  it("keeps adjustments still ahead (an injury week), drops ones already past", async () => {
    await db.doc(workoutPlanPath(USER_ID)).set({
      dailyOverrides: {
        "2001-01-01": { name: "Old", muscles: [], exercises: [] },
        "2999-01-01": { name: "Knee-safe", muscles: [], exercises: [] },
      },
    }, { merge: true });
    const result = await updateTrainingSetup(db, USER_ID, { daysPerWeek: 2 }, "user");
    expect(result.keptAdjustments).toBe(1);
    const overrides = (await db.doc(workoutPlanPath(USER_ID)).get()).get("dailyOverrides");
    expect(Object.keys(overrides)).toEqual(["2999-01-01"]);
  });
});

describe("update_training_setup (the coach's tool)", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });

  beforeEach(async () => {
    await db.recursiveDelete(db.doc(`users/${USER_ID}`));
    await db.doc(profilePath(USER_ID)).set({ ...baseProfile, userId: USER_ID });
  });

  it("applies what the person said this turn", async () => {
    const registry = buildCoachToolRegistry(db, {
      latestPendingProposalId: null,
      rawUserText: "I wanna work out 4 days a week now. I got kettlebells and I'm trying to build muscle now.",
    });
    const result = (await executeTool(
      registry, "update_training_setup",
      { daysPerWeek: 4, equipment: ["kettlebells"], goals: ["muscle_gain"] },
      { authenticatedUserId: USER_ID },
    )) as Record<string, unknown>;
    expect(result.ok).toBe(true);
    expect(result.trainingDays).toHaveLength(4);
  });

  it("refuses without a user message, and rejects made-up values", async () => {
    const silent = buildCoachToolRegistry(db, { latestPendingProposalId: null });
    const none = (await executeTool(silent, "update_training_setup", { daysPerWeek: 4 }, { authenticatedUserId: USER_ID })) as Record<string, unknown>;
    expect(none).toMatchObject({ ok: false, error: "no_user_message" });

    const registry = buildCoachToolRegistry(db, { latestPendingProposalId: null, rawUserText: "train 9 days" });
    const bad = (await executeTool(registry, "update_training_setup", { daysPerWeek: 9 }, { authenticatedUserId: USER_ID })) as Record<string, unknown>;
    expect(bad).toMatchObject({ ok: false, error: "invalid_training_setup" });
    const empty = (await executeTool(registry, "update_training_setup", {}, { authenticatedUserId: USER_ID })) as Record<string, unknown>;
    expect(empty.ok).toBe(false);
    expect((await db.doc(profilePath(USER_ID)).get()).get("schedule.daysPerWeek")).toBe(4);
  });
});
