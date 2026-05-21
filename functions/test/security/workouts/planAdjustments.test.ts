import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { FieldValue, getFirestore, type Firestore } from "firebase-admin/firestore";
import {
  acceptPlanAdjustmentProposal,
  maybeCreatePlanAdjustmentProposal,
} from "../../../src/workouts/planAdjustments.js";
import {
  planAdjustmentProposalPath,
  profilePath,
  workoutPlanPath,
} from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

const USER_ID = "plan-adjustment-user-a";

let app: App;
let db: Firestore;

describe("plan adjustment proposals", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });

  beforeEach(async () => {
    await Promise.allSettled([db.recursiveDelete(db.doc(`users/${USER_ID}`))]);
    await db.doc(profilePath(USER_ID)).set({ ...baseProfile, userId: USER_ID });
  });

  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  it("creates a safety-scoped proposal from a freeform injury reason", async () => {
    const result = await maybeCreatePlanAdjustmentProposal({
      db,
      userId: USER_ID,
      content: "I hurt my ankle the other day. Can you adjust today's workout?",
    });

    expect(result).toMatchObject({
      category: "injury_pain",
      riskLevel: "high",
      requiresFollowUp: true,
    });
    expect(result?.sourceCorpusEntryIds).toContain("myo_pain_injury_adjustment_v1");

    const snap = await db.doc(planAdjustmentProposalPath(USER_ID, result!.proposalId)).get();
    expect(snap.data()).toMatchObject({
      userId: USER_ID,
      source: "coach_chat",
      decision: "pending",
      category: "injury_pain",
      riskLevel: "high",
      originalUserText: "I hurt my ankle the other day. Can you adjust today's workout?",
      proposedPlanPatch: {
        type: "review_only",
      },
    });
    expect(snap.data()?.sourceCorpusEntryIds).toContain("myo_pain_injury_adjustment_v1");
    expect(snap.data()?.serverCreatedAt).toBeTruthy();
  });

  it("keeps fixed workout-detail actions as context, not the only allowed path", async () => {
    const result = await maybeCreatePlanAdjustmentProposal({
      db,
      userId: USER_ID,
      content: "Can we make this more mobility focused today?",
      structuredAnswer: {
        kind: "workout_plan_adjustment",
        dayKey: "Tue",
        exerciseName: "Barbell Bench Press",
      },
    });

    expect(result).toMatchObject({
      category: "style_preference",
      riskLevel: "low",
      requiresFollowUp: false,
    });

    const snap = await db.doc(planAdjustmentProposalPath(USER_ID, result!.proposalId)).get();
    expect(snap.data()).toMatchObject({
      source: "workout_detail",
      appliesTo: {
        planId: "current",
        dayKey: "Tue",
        exerciseName: "Barbell Bench Press",
      },
      proposedPlanPatch: {
        type: "replace_day_focus",
      },
    });
  });

  it("does not create proposal documents for normal chat", async () => {
    const result = await maybeCreatePlanAdjustmentProposal({
      db,
      userId: USER_ID,
      content: "What should I focus on during today's warmup?",
    });

    expect(result).toBeNull();
  });

  it("accepts a low-risk skip proposal and marks the target day as skipped rest", async () => {
    await db.doc(workoutPlanPath(USER_ID, "current")).set(makeWorkoutPlan());
    const result = await maybeCreatePlanAdjustmentProposal({
      db,
      userId: USER_ID,
      content: "I need to skip today.",
      structuredAnswer: {
        kind: "workout_plan_adjustment",
        dayKey: "Tue",
      },
    });

    await db.doc(planAdjustmentProposalPath(USER_ID, result!.proposalId)).set(
      {
        serverCreatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    const acceptResult = await acceptPlanAdjustmentProposal(db, USER_ID, {
      proposalId: result!.proposalId,
      decidedAt: "2026-05-12T00:00:00.000Z",
    });

    const [planSnap, proposalSnap] = await Promise.all([
      db.doc(workoutPlanPath(USER_ID, "current")).get(),
      db.doc(planAdjustmentProposalPath(USER_ID, result!.proposalId)).get(),
    ]);

    expect(acceptResult.ok).toBe(true);
    expect(planSnap.data()).toMatchObject({
      source: "user_edited",
      days: {
        Tue: {
          name: "Rest · Skipped",
          muscles: [],
          exercises: [],
        },
      },
    });
    expect(proposalSnap.data()).toMatchObject({
      decision: "accepted",
      decidedAt: acceptResult.decidedAt,
    });
  });

  it("rejects high-risk proposals instead of mutating the plan", async () => {
    await db.doc(workoutPlanPath(USER_ID, "current")).set(makeWorkoutPlan());
    const result = await maybeCreatePlanAdjustmentProposal({
      db,
      userId: USER_ID,
      content: "I hurt my ankle. Can you adjust today?",
      structuredAnswer: {
        kind: "workout_plan_adjustment",
        dayKey: "Tue",
      },
    });

    await expect(
      acceptPlanAdjustmentProposal(db, USER_ID, { proposalId: result!.proposalId }),
    ).rejects.toThrow("plan_adjustment_requires_review");

    const planSnap = await db.doc(workoutPlanPath(USER_ID, "current")).get();
    expect(planSnap.data()).toMatchObject({
      days: {
        Tue: {
          name: "Pull",
        },
      },
    });
  });
});

function makeWorkoutPlan() {
  return {
    userId: USER_ID,
    planId: "current",
    source: "coach_generated",
    updatedAt: "2026-05-12T00:00:00.000Z",
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
  };
}
