import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { FieldValue, getFirestore, type Firestore } from "firebase-admin/firestore";
import {
  buildTrainingProgramFromDays,
  ensureTrainingProgram,
  syncCurrentWeekSnapshot,
  weekIndexForDate,
  writeRegeneratedPlanAndProgram,
} from "../../../src/workouts/program.js";
import { trainingProgramPath, workoutPlanPath } from "../../../src/paths.js";

const USER_ID = "training-program-user-a";

let app: App;
let db: Firestore;

function sampleDays() {
  return {
    Mon: { name: "Push", muscles: ["Chest"], exercises: [{ name: "Bench Press", sets: 3, reps: 8, weight: 95 }] },
    Tue: { name: "Rest", muscles: [], exercises: [] },
  };
}

describe("trainingPrograms/current — multi-week model", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });

  beforeEach(async () => {
    await Promise.allSettled([db.recursiveDelete(db.doc(`users/${USER_ID}`))]);
  });

  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  it("weekIndexForDate advances every 7 days from startDate", () => {
    expect(weekIndexForDate("2026-07-06", "2026-07-06")).toBe(0);
    expect(weekIndexForDate("2026-07-06", "2026-07-12")).toBe(0);
    expect(weekIndexForDate("2026-07-06", "2026-07-13")).toBe(1);
    expect(weekIndexForDate("2026-07-06", "2026-07-27")).toBe(3);
    // Never negative for a date before startDate.
    expect(weekIndexForDate("2026-07-06", "2026-06-01")).toBe(0);
  });

  it("buildTrainingProgramFromDays seeds every week with the same days", () => {
    const program = buildTrainingProgramFromDays(USER_ID, sampleDays(), "2026-07-06", "2026-07-06T00:00:00.000Z", 4);
    expect(program.weeks).toHaveLength(4);
    expect(program.activeWeekIndex).toBe(0);
    expect(program.weeks.map((week) => week.weekIndex)).toEqual([0, 1, 2, 3]);
    expect(program.weeks[2].days).toEqual(sampleDays());
  });

  it("ensureTrainingProgram backfills from the legacy flat workoutPlans/current doc", async () => {
    await db.doc(workoutPlanPath(USER_ID, "current")).set({
      userId: USER_ID,
      planId: "current",
      source: "coach_generated",
      days: sampleDays(),
      updatedAt: "2026-07-06T00:00:00.000Z",
    });

    const program = await ensureTrainingProgram(db, USER_ID);
    expect(program.userId).toBe(USER_ID);
    expect(program.weeks.length).toBeGreaterThan(0);
    expect(program.weeks[0].days).toEqual(sampleDays());

    const stored = await db.doc(trainingProgramPath(USER_ID)).get();
    expect(stored.exists).toBe(true);

    // workoutPlans/current itself must be untouched by the backfill.
    const planAfter = await db.doc(workoutPlanPath(USER_ID, "current")).get();
    expect(planAfter.data()).toMatchObject({ days: sampleDays() });
  });

  it("ensureTrainingProgram returns the existing doc without rewriting it", async () => {
    const existing = buildTrainingProgramFromDays(USER_ID, sampleDays(), "2026-01-01", "2026-01-01T00:00:00.000Z", 2);
    // Real writes always carry serverUpdatedAt (FieldValue sentinel) — the
    // strict schema must tolerate that on read, not just on the values this
    // module itself constructs in memory.
    await db.doc(trainingProgramPath(USER_ID)).set({
      ...existing,
      serverUpdatedAt: FieldValue.serverTimestamp(),
    });

    const program = await ensureTrainingProgram(db, USER_ID);
    expect(program.startDate).toBe("2026-01-01");
    expect(program.weeks).toHaveLength(2);
  });

  it("syncCurrentWeekSnapshot writes the active week's days without touching dailyOverrides", async () => {
    await db.doc(workoutPlanPath(USER_ID, "current")).set({
      userId: USER_ID,
      planId: "current",
      source: "coach_generated",
      days: {},
      dailyOverrides: { "2026-07-14": { name: "Rest · Sore", muscles: [], exercises: [] } },
      updatedAt: "2026-07-06T00:00:00.000Z",
    });

    const program = buildTrainingProgramFromDays(USER_ID, sampleDays(), "2026-07-06", "2026-07-06T00:00:00.000Z", 2);
    await syncCurrentWeekSnapshot(db, USER_ID, program, "2026-07-13T00:00:00.000Z");

    const planSnap = await db.doc(workoutPlanPath(USER_ID, "current")).get();
    expect(planSnap.data()).toMatchObject({
      days: sampleDays(),
      dailyOverrides: { "2026-07-14": { name: "Rest · Sore", muscles: [], exercises: [] } },
    });
  });

  it("writeRegeneratedPlanAndProgram overwrites both docs and clears dailyOverrides", async () => {
    await db.doc(workoutPlanPath(USER_ID, "current")).set({
      userId: USER_ID,
      planId: "current",
      source: "coach_generated",
      days: { Mon: { name: "Old Day", muscles: [], exercises: [] } },
      dailyOverrides: { "2026-07-14": { name: "Stale Override", muscles: [], exercises: [] } },
      updatedAt: "2026-01-01T00:00:00.000Z",
    });

    await writeRegeneratedPlanAndProgram(db, USER_ID, sampleDays(), "2026-07-06T00:00:00.000Z");

    const [planSnap, programSnap] = await Promise.all([
      db.doc(workoutPlanPath(USER_ID, "current")).get(),
      db.doc(trainingProgramPath(USER_ID)).get(),
    ]);

    expect(planSnap.data()).toMatchObject({ days: sampleDays(), dailyOverrides: {} });
    expect(programSnap.data()).toMatchObject({
      startDate: "2026-07-06",
      activeWeekIndex: 0,
    });
  });
});
