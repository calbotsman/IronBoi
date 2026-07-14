import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { FieldValue, getFirestore, type Firestore } from "firebase-admin/firestore";
import {
  acceptPlanAdjustmentProposal,
  maybeCreatePlanAdjustmentProposal,
} from "../../../src/workouts/planAdjustments.js";
import {
  memoryFactPath,
  planAdjustmentProposalPath,
  profilePath,
  trainingProgramPath,
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

  it("accepts a shorten_workout proposal by trimming the target day's exercises", async () => {
    await db.doc(workoutPlanPath(USER_ID, "current")).set(makeWorkoutPlan());
    const result = await maybeCreatePlanAdjustmentProposal({
      db,
      userId: USER_ID,
      content: "I only have 15 minutes today, can we shorten it?",
      structuredAnswer: { kind: "workout_plan_adjustment", dayKey: "Mon" },
    });

    expect(result).toMatchObject({ category: "time_limit", riskLevel: "low", requiresFollowUp: false });

    const acceptResult = await acceptPlanAdjustmentProposal(db, USER_ID, {
      proposalId: result!.proposalId,
    });
    expect(acceptResult.ok).toBe(true);

    const planSnap = await db.doc(workoutPlanPath(USER_ID, "current")).get();
    // makeWorkoutPlan's Mon day has 3 exercises — shortening keeps the first 2.
    expect(planSnap.data()?.days?.Mon?.exercises).toHaveLength(2);
    expect(planSnap.data()?.days?.Mon?.exercises.map((e: { name: string }) => e.name)).toEqual([
      "Barbell Bench Press",
      "Incline Dumbbell Press",
    ]);
  });

  it("scope 'today' writes a dailyOverride and leaves the template untouched", async () => {
    await db.doc(workoutPlanPath(USER_ID, "current")).set(makeWorkoutPlan());
    const result = await maybeCreatePlanAdjustmentProposal({
      db,
      userId: USER_ID,
      content: "I need to skip today.",
      structuredAnswer: { kind: "workout_plan_adjustment", dayKey: "Tue" },
    });

    const acceptResult = await acceptPlanAdjustmentProposal(db, USER_ID, {
      proposalId: result!.proposalId,
      scope: "today",
    });
    expect(acceptResult.ok).toBe(true);

    const planSnap = await db.doc(workoutPlanPath(USER_ID, "current")).get();
    const data = planSnap.data()!;
    // Template day is untouched — only a dailyOverride was written.
    expect(data.days.Tue).toMatchObject({ name: "Pull" });
    const overrideKeys = Object.keys(data.dailyOverrides ?? {});
    expect(overrideKeys).toHaveLength(1);
    expect(data.dailyOverrides[overrideKeys[0]]).toMatchObject({ name: "Rest · Skipped" });
  });

  it("scope 'going_forward' patches every materialized week in trainingPrograms/current", async () => {
    await db.doc(workoutPlanPath(USER_ID, "current")).set(makeWorkoutPlan());
    const result = await maybeCreatePlanAdjustmentProposal({
      db,
      userId: USER_ID,
      content: "I need to skip today.",
      structuredAnswer: { kind: "workout_plan_adjustment", dayKey: "Tue" },
    });

    const acceptResult = await acceptPlanAdjustmentProposal(db, USER_ID, {
      proposalId: result!.proposalId,
      scope: "going_forward",
    });
    expect(acceptResult.ok).toBe(true);

    const [planSnap, programSnap] = await Promise.all([
      db.doc(workoutPlanPath(USER_ID, "current")).get(),
      db.doc(trainingProgramPath(USER_ID)).get(),
    ]);

    expect(planSnap.data()?.days.Tue).toMatchObject({ name: "Rest · Skipped" });
    const weeks = programSnap.data()?.weeks as Array<{ weekIndex: number; days: Record<string, { name: string }> }>;
    expect(weeks.length).toBeGreaterThan(1);
    for (const week of weeks) {
      expect(week.days.Tue).toMatchObject({ name: "Rest · Skipped" });
      // Untouched days stay as the original template.
      expect(week.days.Mon).toMatchObject({ name: "Push" });
    }
  });

  it("scope 'rest_of_week' only patches the active week, not the whole program", async () => {
    await db.doc(workoutPlanPath(USER_ID, "current")).set(makeWorkoutPlan());
    const result = await maybeCreatePlanAdjustmentProposal({
      db,
      userId: USER_ID,
      content: "I need to skip today.",
      structuredAnswer: { kind: "workout_plan_adjustment", dayKey: "Tue" },
    });

    await acceptPlanAdjustmentProposal(db, USER_ID, {
      proposalId: result!.proposalId,
      scope: "rest_of_week",
    });

    const programSnap = await db.doc(trainingProgramPath(USER_ID)).get();
    const weeks = programSnap.data()?.weeks as Array<{ weekIndex: number; days: Record<string, { name: string }> }>;
    const activeWeek = weeks.find((week) => week.weekIndex === programSnap.data()?.activeWeekIndex);
    const otherWeeks = weeks.filter((week) => week.weekIndex !== programSnap.data()?.activeWeekIndex);

    expect(activeWeek?.days.Tue).toMatchObject({ name: "Rest · Skipped" });
    for (const week of otherWeeks) {
      expect(week.days.Tue).toMatchObject({ name: "Pull" });
    }
  });

  it("accepting a proposal writes a confirmed plan_change memory fact", async () => {
    await db.doc(workoutPlanPath(USER_ID, "current")).set(makeWorkoutPlan());
    const result = await maybeCreatePlanAdjustmentProposal({
      db,
      userId: USER_ID,
      content: "I need to skip today.",
      structuredAnswer: { kind: "workout_plan_adjustment", dayKey: "Tue" },
    });

    await acceptPlanAdjustmentProposal(db, USER_ID, {
      proposalId: result!.proposalId,
      scope: "today",
    });

    const factSnap = await db.doc(memoryFactPath(USER_ID, `plan_change_${result!.proposalId}`)).get();
    expect(factSnap.exists).toBe(true);
    expect(factSnap.data()).toMatchObject({
      userId: USER_ID,
      category: "plan_change",
      source: "coach_inferred",
      state: "confirmed",
      userEditable: true,
    });
    expect(factSnap.data()?.content).toContain("Tue");
    expect(factSnap.data()?.content).toContain("I need to skip today.");
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
        exercises: [
          { name: "Barbell Bench Press", sets: 3, reps: 8, weight: 95 },
          { name: "Incline Dumbbell Press", sets: 3, reps: 10, weight: 40 },
          { name: "Lateral Raise", sets: 3, reps: 12, weight: 15 },
        ],
      },
      Tue: {
        name: "Pull",
        muscles: ["Back"],
        exercises: [{ name: "Pull-Up", sets: 3, reps: 8, weight: 0 }],
      },
    },
  };
}
