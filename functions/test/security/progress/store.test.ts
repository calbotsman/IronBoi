import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { ProgressSummary } from "../../../src/contracts/coach-agent.js";
import { loadCoachContext } from "../../../src/coach/context.js";
import {
  recomputeProgressSummaryIfStale,
  writeProgressSummary,
} from "../../../src/progress/store.js";
import {
  healthSamplePath,
  metricSnapshotPath,
  profilePath,
  progressSummaryPath,
  workoutLogPath,
  workoutPlanPath,
} from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

const USER_ID = "progress-user-a";
const TODAY = "2026-07-16T12:00:00.000Z";

let app: App;
let db: Firestore;

function benchLog(sessionId: string, date: string, loadKg: number) {
  return {
    userId: USER_ID,
    sessionId,
    date,
    source: "manual" as const,
    exercises: [{ name: "Bench Press", sets: [{ reps: 5, loadKg }] }],
    createdAt: `${date}T10:00:00.000Z`,
  };
}

async function seedUser() {
  await db.doc(profilePath(USER_ID)).set({
    ...baseProfile,
    userId: USER_ID,
    goals: ["fat_loss"],
  });

  const trainingDay = (name: string) => ({
    name,
    muscles: [],
    exercises: [{ name: "Bench Press", sets: 3, reps: 5, weight: 100 }],
  });
  await db.doc(workoutPlanPath(USER_ID)).set({
    userId: USER_ID,
    planId: "current",
    source: "coach_generated",
    days: { Mon: trainingDay("Push"), Wed: trainingDay("Pull"), Fri: trainingDay("Legs") },
    updatedAt: TODAY,
  });

  await db
    .doc(workoutLogPath(USER_ID, "log-1"))
    .set(benchLog("log-1", "2026-07-10", 100));
  await db
    .doc(workoutLogPath(USER_ID, "log-2"))
    .set(benchLog("log-2", "2026-07-12", 102.5));
  await db
    .doc(workoutLogPath(USER_ID, "log-3"))
    .set(benchLog("log-3", "2026-07-14", 105));
  // Outside the 42-day window — must not count.
  await db
    .doc(workoutLogPath(USER_ID, "log-old"))
    .set(benchLog("log-old", "2026-05-01", 90));

  // HealthKit body-weight sample inside the window.
  await db.doc(healthSamplePath(USER_ID, "hash-bodyweight-1")).set({
    userId: USER_ID,
    category: "body_weight_kg",
    value: 88,
    unit: "kg",
    startDate: "2026-07-10T08:00:00.000Z",
    endDate: "2026-07-10T08:00:00.000Z",
    sampleHash: "hash-bodyweight-1",
    ingestedAt: TODAY,
  });
  // Non-weight sample — must be ignored by the weight stream.
  await db.doc(healthSamplePath(USER_ID, "hash-steps-1")).set({
    userId: USER_ID,
    category: "steps",
    value: 9_000,
    unit: "count",
    startDate: "2026-07-11T08:00:00.000Z",
    endDate: "2026-07-11T08:00:00.000Z",
    sampleHash: "hash-steps-1",
    ingestedAt: TODAY,
  });

  // Manual weigh-in typed into the app → metricSnapshot, source "manual".
  await db.doc(metricSnapshotPath(USER_ID, "snap-manual")).set({
    userId: USER_ID,
    snapshotId: "snap-manual",
    capturedAt: "2026-07-15T08:00:00.000Z",
    source: "manual",
    metrics: { bodyWeightKg: 87.6 },
    interpretationPolicy: "context_only_not_deterministic",
  });
  // HealthKit-sourced snapshot — skipped (those days flow via healthSamples).
  await db.doc(metricSnapshotPath(USER_ID, "snap-healthkit")).set({
    userId: USER_ID,
    snapshotId: "snap-healthkit",
    capturedAt: "2026-07-13T08:00:00.000Z",
    source: "healthkit",
    metrics: { bodyWeightKg: 99 },
    interpretationPolicy: "context_only_not_deterministic",
  });
}

describe("progress summary storage", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });

  beforeEach(async () => {
    await db.recursiveDelete(db.doc(`users/${USER_ID}`));
    await seedUser();
  });

  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  it("writes a contract-valid progress_current doc from real inputs", async () => {
    await writeProgressSummary(db, USER_ID, TODAY);

    const snap = await db.doc(progressSummaryPath(USER_ID)).get();
    expect(snap.exists).toBe(true);

    // Live docs carry the serverUpdatedAt sentinel — field-pick it off
    // before the strict contract parse (repo-wide gotcha).
    const { serverUpdatedAt, ...data } = snap.data() ?? {};
    expect(serverUpdatedAt).toBeDefined();
    const summary = ProgressSummary.parse(data);

    expect(summary.userId).toBe(USER_ID);
    expect(summary.windowDays).toBe(42);
    expect(summary.computedAt).toBe(TODAY);

    // 3 in-window logs; the 2026-05-01 log is outside the window.
    expect(summary.adherence.completedSessions).toBe(3);
    expect(summary.adherence.plannedSessions).toBe(18);
    expect(summary.adherence.streakWeeks).toBe(1);

    expect(summary.lifts).toHaveLength(1);
    expect(summary.lifts[0].exerciseName).toBe("Bench Press");
    expect(summary.lifts[0].e1rmSeries).toHaveLength(3);

    // HealthKit sample + manual snapshot merge into one weight stream; the
    // healthkit-sourced snapshot (99 kg) and the steps sample are excluded.
    expect(summary.body.weightSeries).toEqual([
      { date: "2026-07-10", kg: 88 },
      { date: "2026-07-15", kg: 87.6 },
    ]);
    expect(summary.body.goalDirection).toBe("down");
  });

  it("debounces recomputes to once per hour via the doc's computedAt", async () => {
    await writeProgressSummary(db, USER_ID, TODAY);

    // A new log lands 30 minutes later — still fresh, skip.
    await db
      .doc(workoutLogPath(USER_ID, "log-4"))
      .set(benchLog("log-4", "2026-07-16", 107.5));
    const thirtyMinutesLater = "2026-07-16T12:30:00.000Z";
    const skipped = await recomputeProgressSummaryIfStale(db, USER_ID, thirtyMinutesLater);
    expect(skipped).toEqual({ recomputed: false, reason: "fresh" });

    const afterSkip = await db.doc(progressSummaryPath(USER_ID)).get();
    expect(afterSkip.data()?.computedAt).toBe(TODAY);
    expect(afterSkip.data()?.adherence.completedSessions).toBe(3);

    // Two hours later the doc is stale — recompute picks up the new log.
    const twoHoursLater = "2026-07-16T14:00:00.000Z";
    const recomputed = await recomputeProgressSummaryIfStale(db, USER_ID, twoHoursLater);
    expect(recomputed.recomputed).toBe(true);

    const afterRecompute = await db.doc(progressSummaryPath(USER_ID)).get();
    expect(afterRecompute.data()?.computedAt).toBe(twoHoursLater);
    expect(afterRecompute.data()?.adherence.completedSessions).toBe(4);
  });

  it("writes lensHighlights only when the profile carries a coaching lens", async () => {
    // The seeded fixture profile has no coachingLens → the field is omitted
    // from the persisted doc, not written as [].
    await writeProgressSummary(db, USER_ID, TODAY);
    const bare = await db.doc(progressSummaryPath(USER_ID)).get();
    expect(bare.data()).not.toHaveProperty("lensHighlights");

    await db.doc(profilePath(USER_ID)).set({
      ...baseProfile,
      userId: USER_ID,
      goals: ["fat_loss"],
      preferences: { ...baseProfile.preferences, coachingLens: "schoenfeld" },
    });
    const summary = await writeProgressSummary(db, USER_ID, TODAY);
    expect(summary.lensHighlights?.map((h) => h.metric)).toEqual([
      "volume_trend",
      "top_lift_e1rm",
    ]);

    // The persisted doc round-trips through the strict contract, sentinel
    // field-picked off first (repo-wide gotcha).
    const snap = await db.doc(progressSummaryPath(USER_ID)).get();
    const { serverUpdatedAt, ...data } = snap.data() ?? {};
    expect(serverUpdatedAt).toBeDefined();
    const parsed = ProgressSummary.parse(data);
    expect(parsed.lensHighlights?.[0].framing).toContain("Weekly working volume");
  });

  it("recomputes immediately when no summary doc exists yet", async () => {
    const result = await recomputeProgressSummaryIfStale(db, USER_ID, TODAY);
    expect(result.recomputed).toBe(true);
    const snap = await db.doc(progressSummaryPath(USER_ID)).get();
    expect(snap.exists).toBe(true);
  });

  it("loadCoachContext reads progress only when the option is on, null when absent", async () => {
    await writeProgressSummary(db, USER_ID, TODAY);

    const withProgress = await loadCoachContext(db, USER_ID, "session-a", {
      includeProgress: true,
    });
    expect(withProgress.progressSummary).not.toBeNull();
    expect(withProgress.progressSummary?.windowDays).toBe(42);

    // Flag-off invariance: the read is skipped entirely.
    const withoutOption = await loadCoachContext(db, USER_ID, "session-a");
    expect(withoutOption.progressSummary).toBeNull();

    // Missing doc degrades to null, never throws.
    await db.doc(progressSummaryPath(USER_ID)).delete();
    const missingDoc = await loadCoachContext(db, USER_ID, "session-a", {
      includeProgress: true,
    });
    expect(missingDoc.progressSummary).toBeNull();
  });
});
