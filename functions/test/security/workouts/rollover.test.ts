import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { rolloverTrainingPrograms } from "../../../src/workouts/rollover.js";
import {
  acceptPlanAdjustmentProposal,
  maybeCreatePlanAdjustmentProposal,
} from "../../../src/workouts/planAdjustments.js";
import { profilePath, trainingProgramPath, workoutPlanPath } from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

// Unique per-file user ids — the emulator DB is shared across the suite.
// The rollover scans collectionGroup("trainingPrograms"), so it will also
// touch leftovers from other test files; every assertion here is therefore
// scoped to these users' docs, and summary counters are only checked with
// >= (never exact equality against the global scan).
const USER_ROLL = "rollover-user-a";
const USER_OVERRIDES = "rollover-user-b";
const USER_EXTEND = "rollover-user-c";
const USER_NOOP = "rollover-user-d";
const USER_CORRUPT = "rollover-user-e";
const USER_PRUNE = "rollover-user-f";
const USER_CASCADE = "rollover-user-g";
const USER_CAP = "rollover-user-h";
const ALL_USERS = [
  USER_ROLL,
  USER_OVERRIDES,
  USER_EXTEND,
  USER_NOOP,
  USER_CORRUPT,
  USER_PRUNE,
  USER_CASCADE,
  USER_CAP,
];

// Fixed dates are safe here (no calendar time-bombs): every call injects
// todayISO explicitly, so nothing depends on the wall clock. 2026-07-17 is
// exactly 2 weeks after 2026-07-03.
const START_DATE = "2026-07-03";
const TODAY = "2026-07-17";

let app: App;
let db: Firestore;

function weekDays(label: string) {
  return {
    Mon: {
      name: `Push ${label}`,
      muscles: ["Chest"],
      exercises: [{ name: "Bench Press", sets: 3, reps: 8, weight: 95 }],
    },
    Tue: { name: "Rest", muscles: [], exercises: [] },
  };
}

// Each week gets DISTINCT day content so "the snapshot now shows week N"
// is observable, not vacuously true.
function makeProgram(userId: string, startDate: string, weekCount: number, activeWeekIndex = 0) {
  return {
    userId,
    programId: "current",
    startDate,
    weeks: Array.from({ length: weekCount }, (_, weekIndex) => ({
      weekIndex,
      days: weekDays(`W${weekIndex}`),
    })),
    activeWeekIndex,
    source: "coach_generated",
    updatedAt: "2026-07-03T00:00:00.000Z",
  };
}

function makePlan(userId: string, days: Record<string, unknown>) {
  return {
    userId,
    planId: "current",
    source: "coach_generated",
    days,
    updatedAt: "2026-07-03T00:00:00.000Z",
  };
}

describe("weekly program rollover", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });

  beforeEach(async () => {
    await Promise.allSettled(
      ALL_USERS.map((userId) => db.recursiveDelete(db.doc(`users/${userId}`))),
    );
  });

  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  it("advances activeWeekIndex to the calendar week and resyncs the snapshot", async () => {
    await db.doc(trainingProgramPath(USER_ROLL)).set(makeProgram(USER_ROLL, START_DATE, 4));
    await db.doc(workoutPlanPath(USER_ROLL, "current")).set(makePlan(USER_ROLL, weekDays("W0")));

    const summary = await rolloverTrainingPrograms(db, TODAY);
    expect(summary.rolled).toBeGreaterThanOrEqual(1);

    const [programSnap, planSnap] = await Promise.all([
      db.doc(trainingProgramPath(USER_ROLL)).get(),
      db.doc(workoutPlanPath(USER_ROLL, "current")).get(),
    ]);
    // 2026-07-17 is exactly 14 days after startDate → week 2.
    expect(programSnap.data()).toMatchObject({ activeWeekIndex: 2 });
    expect(programSnap.data()?.updatedAt).not.toBe("2026-07-03T00:00:00.000Z");
    // Snapshot now serves week 2's (distinct) content.
    expect(planSnap.data()?.days?.Mon).toMatchObject({ name: "Push W2" });
  });

  it("dailyOverrides on workoutPlans/current survive the rollover resync", async () => {
    await db
      .doc(trainingProgramPath(USER_OVERRIDES))
      .set(makeProgram(USER_OVERRIDES, START_DATE, 4));
    await db.doc(workoutPlanPath(USER_OVERRIDES, "current")).set({
      ...makePlan(USER_OVERRIDES, weekDays("W0")),
      dailyOverrides: {
        "2026-07-18": { name: "Rest · Sore", muscles: [], exercises: [] },
      },
    });

    await rolloverTrainingPrograms(db, TODAY);

    const planSnap = await db.doc(workoutPlanPath(USER_OVERRIDES, "current")).get();
    // syncCurrentWeekSnapshot merge-writes only `days` — the override map
    // must come through untouched.
    expect(planSnap.data()?.days?.Mon).toMatchObject({ name: "Push W2" });
    expect(planSnap.data()?.dailyOverrides).toEqual({
      "2026-07-18": { name: "Rest · Sore", muscles: [], exercises: [] },
    });
  });

  it("extends the weeks array by cloning the last week when the calendar outruns it", async () => {
    // startDate 5 weeks before TODAY, but only 4 weeks materialized.
    await db.doc(trainingProgramPath(USER_EXTEND)).set(makeProgram(USER_EXTEND, "2026-06-12", 4));
    await db.doc(workoutPlanPath(USER_EXTEND, "current")).set(makePlan(USER_EXTEND, weekDays("W0")));

    await rolloverTrainingPrograms(db, TODAY);

    const [programSnap, planSnap] = await Promise.all([
      db.doc(trainingProgramPath(USER_EXTEND)).get(),
      db.doc(workoutPlanPath(USER_EXTEND, "current")).get(),
    ]);
    const data = programSnap.data()!;
    // expected week = 5; keep 2 future weeks → 8 total, indexes contiguous.
    expect(data.activeWeekIndex).toBe(5);
    expect(data.weeks).toHaveLength(8);
    expect(data.weeks.map((week: { weekIndex: number }) => week.weekIndex)).toEqual([
      0, 1, 2, 3, 4, 5, 6, 7,
    ]);
    // Every extension week clones the LAST materialized week's days.
    for (const week of data.weeks.slice(4)) {
      expect(week.days.Mon).toMatchObject({ name: "Push W3" });
    }
    // And the snapshot serves the (cloned) new active week.
    expect(planSnap.data()?.days?.Mon).toMatchObject({ name: "Push W3" });
  });

  it("caps materialization at 52 weeks and clamps activeWeekIndex to the last week", async () => {
    // startDate 60 weeks before TODAY (2026-07-17 − 420 days = 2025-05-23).
    await db.doc(trainingProgramPath(USER_CAP)).set(makeProgram(USER_CAP, "2025-05-23", 4));
    await db.doc(workoutPlanPath(USER_CAP, "current")).set(makePlan(USER_CAP, weekDays("W0")));

    await rolloverTrainingPrograms(db, TODAY);

    const programSnap = await db.doc(trainingProgramPath(USER_CAP)).get();
    expect(programSnap.data()?.weeks).toHaveLength(52);
    expect(programSnap.data()?.activeWeekIndex).toBe(51);

    // A second pass is a no-op — the clamped program must not rewrite itself
    // forever (expected 60 stays ≠ 51, but nothing is left to change).
    const before = (await db.doc(trainingProgramPath(USER_CAP)).get()).data()?.updatedAt;
    await rolloverTrainingPrograms(db, TODAY);
    const after = (await db.doc(trainingProgramPath(USER_CAP)).get()).data()?.updatedAt;
    expect(after).toBe(before);
  });

  it("no-ops when activeWeekIndex already matches the calendar", async () => {
    await db.doc(trainingProgramPath(USER_NOOP)).set(makeProgram(USER_NOOP, START_DATE, 4, 2));

    await rolloverTrainingPrograms(db, TODAY);

    const programSnap = await db.doc(trainingProgramPath(USER_NOOP)).get();
    expect(programSnap.data()).toMatchObject({
      activeWeekIndex: 2,
      updatedAt: "2026-07-03T00:00:00.000Z",
    });
    // No snapshot sync ran either — the plan doc was never created.
    const planSnap = await db.doc(workoutPlanPath(USER_NOOP, "current")).get();
    expect(planSnap.exists).toBe(false);
  });

  it("skips a corrupt program doc (untouched, not deleted) while a healthy one still rolls", async () => {
    await db.doc(trainingProgramPath(USER_CORRUPT)).set({
      userId: USER_CORRUPT,
      programId: "current",
      startDate: START_DATE,
      weeks: "definitely-not-an-array",
      activeWeekIndex: 0,
      source: "coach_generated",
      updatedAt: "2026-07-03T00:00:00.000Z",
    });
    await db.doc(trainingProgramPath(USER_ROLL)).set(makeProgram(USER_ROLL, START_DATE, 4));
    await db.doc(workoutPlanPath(USER_ROLL, "current")).set(makePlan(USER_ROLL, weekDays("W0")));

    const summary = await rolloverTrainingPrograms(db, TODAY);
    expect(summary.corrupt).toBeGreaterThanOrEqual(1);

    const [corruptSnap, healthySnap] = await Promise.all([
      db.doc(trainingProgramPath(USER_CORRUPT)).get(),
      db.doc(trainingProgramPath(USER_ROLL)).get(),
    ]);
    // Corrupt doc is left EXACTLY as it was — no delete, no "repair".
    expect(corruptSnap.exists).toBe(true);
    expect(corruptSnap.data()).toMatchObject({
      weeks: "definitely-not-an-array",
      activeWeekIndex: 0,
      updatedAt: "2026-07-03T00:00:00.000Z",
    });
    // The healthy program still rolled.
    expect(healthySnap.data()).toMatchObject({ activeWeekIndex: 2 });
  });

  it("prunes past-dated dailyOverrides and keeps today's and future ones", async () => {
    await db.doc(trainingProgramPath(USER_PRUNE)).set(makeProgram(USER_PRUNE, START_DATE, 4));
    await db.doc(workoutPlanPath(USER_PRUNE, "current")).set({
      ...makePlan(USER_PRUNE, weekDays("W0")),
      dailyOverrides: {
        "2026-07-01": { name: "Stale Past Override", muscles: [], exercises: [] },
        [TODAY]: { name: "Live Today Override", muscles: [], exercises: [] },
        "2026-07-25": { name: "Future Override", muscles: [], exercises: [] },
      },
    });

    await rolloverTrainingPrograms(db, TODAY);

    const planSnap = await db.doc(workoutPlanPath(USER_PRUNE, "current")).get();
    const overrides = planSnap.data()?.dailyOverrides ?? {};
    // Strictly past dates go; today's override is still live until midnight.
    expect(Object.keys(overrides).sort()).toEqual([TODAY, "2026-07-25"]);
    expect(overrides[TODAY]).toMatchObject({ name: "Live Today Override" });
  });

  it("a going_forward adjustment accepted last week is what the NEW active week serves", async () => {
    await db.doc(profilePath(USER_CASCADE)).set({ ...baseProfile, userId: USER_CASCADE });
    await db.doc(workoutPlanPath(USER_CASCADE, "current")).set({
      userId: USER_CASCADE,
      planId: "current",
      source: "coach_generated",
      updatedAt: "2026-07-03T00:00:00.000Z",
      days: {
        Mon: {
          name: "Push",
          muscles: ["Chest"],
          exercises: [{ name: "Barbell Bench Press", sets: 3, reps: 8, weight: 95 }],
        },
        Tue: {
          name: "Pull",
          muscles: ["Back"],
          exercises: [{ name: "Pull-Up", sets: 3, reps: 8, weight: 0 }],
        },
      },
    });

    // Real accept path: skip Tue, going_forward → cascades through every
    // materialized week of the (backfilled) trainingPrograms/current doc.
    const proposal = await maybeCreatePlanAdjustmentProposal({
      db,
      userId: USER_CASCADE,
      content: "I need to skip today.",
      structuredAnswer: { kind: "workout_plan_adjustment", dayKey: "Tue" },
    });
    const accepted = await acceptPlanAdjustmentProposal(db, USER_CASCADE, {
      proposalId: proposal!.proposalId,
      scope: "going_forward",
    });
    expect(accepted.ok).toBe(true);

    // ensureTrainingProgram backfilled with startDate = the REAL today, so
    // compute "a week later" relative to the stored startDate instead of
    // hardcoding a date (no calendar time-bombs).
    const startDate = (await db.doc(trainingProgramPath(USER_CASCADE)).get()).data()
      ?.startDate as string;
    const oneWeekLater = new Date(Date.parse(`${startDate}T00:00:00Z`) + 8 * 86_400_000)
      .toISOString()
      .slice(0, 10);

    await rolloverTrainingPrograms(db, oneWeekLater);

    const [programSnap, planSnap] = await Promise.all([
      db.doc(trainingProgramPath(USER_CASCADE)).get(),
      db.doc(workoutPlanPath(USER_CASCADE, "current")).get(),
    ]);
    expect(programSnap.data()?.activeWeekIndex).toBe(1);
    // The patched content cascaded into week 1, and week 1 is what the
    // snapshot now serves — the adjustment survived the week boundary.
    expect(programSnap.data()?.weeks?.[1]?.days?.Tue).toMatchObject({ name: "Rest · Skipped" });
    expect(planSnap.data()?.days?.Tue).toMatchObject({ name: "Rest · Skipped" });
    // Untouched days still serve the original template.
    expect(planSnap.data()?.days?.Mon).toMatchObject({ name: "Push" });
  });
});
