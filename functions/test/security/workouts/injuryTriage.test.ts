import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import {
  acceptLatestPlanAdjustmentFromChat,
  createClearOverridesProposalFromTool,
  createPlanAdjustmentProposalFromTool,
  findLatestPendingProposal,
} from "../../../src/workouts/planAdjustments.js";
import { sweepCoachFollowUps } from "../../../src/followups/sweep.js";
import {
  coachFollowUpPath,
  coachSessionMessagePath,
  profilePath,
  trainingProgramPath,
  workoutPlanPath,
} from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

const USER_ID = "injury-triage-user-a";

let app: App;
let db: Firestore;

function makeWorkoutPlan() {
  return {
    userId: USER_ID,
    planId: "current",
    source: "coach_generated",
    updatedAt: "2026-07-06T00:00:00.000Z",
    days: {
      Mon: {
        name: "Deadlift Day",
        muscles: ["Back"],
        exercises: [{ name: "Deadlift", sets: 3, reps: 5, weight: 185 }],
      },
      Wed: {
        name: "Row Day",
        muscles: ["Back"],
        exercises: [{ name: "Barbell Row", sets: 3, reps: 8, weight: 115 }],
      },
      Fri: {
        name: "Squat Day",
        muscles: ["Legs"],
        exercises: [{ name: "Back Squat", sets: 3, reps: 5, weight: 155 }],
      },
    },
  };
}

const BACK_SAFE_PATCHES = [
  {
    dayKey: "Wed",
    dayName: "Back-safe core",
    replacementExercises: [
      { name: "Bird Dog", sets: 3, reps: 10, weight: 0 },
      { name: "Dead Bug", sets: 3, reps: 10, weight: 0 },
    ],
  },
  {
    dayKey: "Fri",
    dayName: "Back-safe lower",
    replacementExercises: [{ name: "Glute Bridge", sets: 3, reps: 12, weight: 0 }],
  },
];

const CLEAN_TRIAGE = {
  redFlagsAsked: true as const,
  userReportsSevere: false,
  description: "dull ache in lower back after yesterday, no other symptoms",
};

describe("injury triage → week rebuilder → recovery arc", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });

  beforeEach(async () => {
    await Promise.allSettled([db.recursiveDelete(db.doc(`users/${USER_ID}`))]);
    await db.doc(profilePath(USER_ID)).set({ ...baseProfile, userId: USER_ID });
    await db.doc(workoutPlanPath(USER_ID, "current")).set(makeWorkoutPlan());
  });

  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  it("triage-cleared injury proposal with dayPatches is low-risk and appliable", async () => {
    const created = await createPlanAdjustmentProposalFromTool({
      db,
      userId: USER_ID,
      reason: "pain_or_discomfort",
      userNote: "my back hurts, can we update this weeks workouts",
      scope: "rest_of_week",
      dayPatches: BACK_SAFE_PATCHES,
      painTriage: CLEAN_TRIAGE,
      recoveryDays: 5,
    });

    expect(created).toMatchObject({
      category: "injury_pain",
      riskLevel: "low",
      requiresFollowUp: false,
      needsScopeConfirmation: false,
    });
    expect(created.proposalId).toBeTruthy();
  });

  it("severe markers lock the proposal at high risk no matter what the triage claims", async () => {
    const created = await createPlanAdjustmentProposalFromTool({
      db,
      userId: USER_ID,
      reason: "pain_or_discomfort",
      userNote: "shooting pain down my leg, adjust my week",
      scope: "rest_of_week",
      dayPatches: BACK_SAFE_PATCHES,
      painTriage: CLEAN_TRIAGE,
    });

    expect(created).toMatchObject({ riskLevel: "high", requiresFollowUp: true });

    const accept = await acceptLatestPlanAdjustmentFromChat(
      db,
      USER_ID,
      "rest_of_week",
      (await findLatestPendingProposal(db, USER_ID))?.docId ?? null,
      "2026-07-15",
    );
    expect(accept).toMatchObject({ ok: false, error: "plan_adjustment_requires_review" });
  });

  it("injury proposal WITHOUT triage stays high-risk (model must ask first)", async () => {
    const created = await createPlanAdjustmentProposalFromTool({
      db,
      userId: USER_ID,
      reason: "pain_or_discomfort",
      userNote: "my back is sore",
      scope: "today",
      dayPatches: BACK_SAFE_PATCHES,
    });
    expect(created).toMatchObject({ riskLevel: "high", requiresFollowUp: true });
  });

  it("rest_of_week accept writes dated overrides for the patched days only and schedules a follow-up", async () => {
    const created = await createPlanAdjustmentProposalFromTool({
      db,
      userId: USER_ID,
      reason: "pain_or_discomfort",
      userNote: "my back hurts, can we update this weeks workouts",
      scope: "rest_of_week",
      dayPatches: BACK_SAFE_PATCHES,
      painTriage: CLEAN_TRIAGE,
      recoveryDays: 5,
    });

    // 2026-07-15 is a Wednesday. Wed patch → same day; Fri patch → 07-17.
    const accept = await acceptLatestPlanAdjustmentFromChat(
      db,
      USER_ID,
      undefined,
      (await findLatestPendingProposal(db, USER_ID))?.docId ?? null,
      "2026-07-15",
    );
    expect(accept).toMatchObject({ ok: true, appliedScope: "rest_of_week" });

    const planSnap = await db.doc(workoutPlanPath(USER_ID, "current")).get();
    const overrides = planSnap.data()?.dailyOverrides ?? {};
    expect(Object.keys(overrides).sort()).toEqual(["2026-07-15", "2026-07-17"]);
    expect(overrides["2026-07-15"]).toMatchObject({ name: "Back-safe core" });
    expect(overrides["2026-07-17"]).toMatchObject({ name: "Back-safe lower" });

    // Template untouched, no program cascade.
    expect(planSnap.data()?.days?.Wed).toMatchObject({ name: "Row Day" });
    expect(planSnap.data()?.days?.Fri).toMatchObject({ name: "Squat Day" });
    const programSnap = await db.doc(trainingProgramPath(USER_ID)).get();
    expect(programSnap.exists).toBe(false);

    // Recovery follow-up scheduled 5 days out.
    const followUpSnap = await db
      .doc(coachFollowUpPath(USER_ID, `followup_${created.proposalId}`))
      .get();
    expect(followUpSnap.exists).toBe(true);
    expect(followUpSnap.data()).toMatchObject({ kind: "injury_recheck", status: "scheduled" });
  });

  it("the follow-up sweep delivers a check-in message and marks the doc sent", async () => {
    const followUpId = "followup_test_1";
    await db.doc(coachFollowUpPath(USER_ID, followUpId)).set({
      userId: USER_ID,
      followUpId,
      kind: "injury_recheck",
      context: "Adjusted plan for Wed, Fri to work around reported pain.",
      proposalId: "adjustment_x",
      dueAt: "2026-07-20T00:00:00.000Z",
      status: "scheduled",
      createdAt: "2026-07-15T00:00:00.000Z",
    });

    const result = await sweepCoachFollowUps(db, "2026-07-21T00:00:00.000Z");
    expect(result).toMatchObject({ sent: 1 });

    const messageSnap = await db
      .doc(coachSessionMessagePath(USER_ID, "general", `followup_${followUpId}`))
      .get();
    expect(messageSnap.exists).toBe(true);
    expect(messageSnap.data()?.role).toBe("coach");
    expect(messageSnap.data()?.content).toContain("Checking in");

    const followUpSnap = await db.doc(coachFollowUpPath(USER_ID, followUpId)).get();
    expect(followUpSnap.data()?.status).toBe("sent");

    // Idempotent: sweeping again finds nothing due.
    const second = await sweepCoachFollowUps(db, "2026-07-21T00:00:00.000Z");
    expect(second).toMatchObject({ sent: 0 });
  });

  it("clear_plan_overrides proposal accepts without scope and removes future-dated overrides", async () => {
    await db.doc(workoutPlanPath(USER_ID, "current")).set(
      {
        dailyOverrides: {
          "2026-07-01": { name: "Old Past Override", muscles: [], exercises: [] },
          "2026-07-16": { name: "Back-safe core", muscles: [], exercises: [] },
          "2026-07-18": { name: "Back-safe lower", muscles: [], exercises: [] },
        },
      },
      { merge: true },
    );

    const created = await createClearOverridesProposalFromTool({
      db,
      userId: USER_ID,
      userNote: "feeling much better, ramp me back up",
    });
    expect(created.proposalId).toBeTruthy();

    const accept = await acceptLatestPlanAdjustmentFromChat(
      db,
      USER_ID,
      undefined,
      (await findLatestPendingProposal(db, USER_ID))?.docId ?? null,
      "2026-07-15",
    );
    expect(accept).toMatchObject({ ok: true });

    const planSnap = await db.doc(workoutPlanPath(USER_ID, "current")).get();
    const overrides = planSnap.data()?.dailyOverrides ?? {};
    // Future-dated overrides removed; the already-past one is left alone
    // (it's expired by construction and pruned on the next today-write).
    expect(Object.keys(overrides)).toEqual(["2026-07-01"]);
  });
});
