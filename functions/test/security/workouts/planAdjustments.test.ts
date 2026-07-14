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

  it("scope 'today' writes a dailyOverride keyed to the TARGET day's date and records the applied scope", async () => {
    await db.doc(workoutPlanPath(USER_ID, "current")).set(makeWorkoutPlan());
    const result = await maybeCreatePlanAdjustmentProposal({
      db,
      userId: USER_ID,
      content: "I need to skip today.",
      structuredAnswer: { kind: "workout_plan_adjustment", dayKey: "Tue" },
    });

    // 2026-07-15 is a Wednesday — the proposal targets Tue, so the override
    // must land on the NEXT Tuesday (2026-07-21), not on the accept date.
    const acceptResult = await acceptPlanAdjustmentProposal(db, USER_ID, {
      proposalId: result!.proposalId,
      scope: "today",
      clientDate: "2026-07-15",
    });
    expect(acceptResult.ok).toBe(true);

    const [planSnap, proposalSnap] = await Promise.all([
      db.doc(workoutPlanPath(USER_ID, "current")).get(),
      db.doc(planAdjustmentProposalPath(USER_ID, result!.proposalId)).get(),
    ]);
    const data = planSnap.data()!;
    // Template day is untouched — only a dailyOverride was written.
    expect(data.days.Tue).toMatchObject({ name: "Pull" });
    expect(Object.keys(data.dailyOverrides ?? {})).toEqual(["2026-07-21"]);
    expect(data.dailyOverrides["2026-07-21"]).toMatchObject({ name: "Rest · Skipped" });

    // The applied scope must land NESTED in appliesTo (a dotted key in
    // set+merge would write a literal top-level "appliesTo.scope" field).
    expect(proposalSnap.data()?.appliesTo).toMatchObject({ dayKey: "Tue", scope: "today" });
    expect(proposalSnap.data()?.["appliesTo.scope"]).toBeUndefined();
  });

  it("scope 'today' accepted on the target weekday keys the override to that same date and prunes stale overrides", async () => {
    await db.doc(workoutPlanPath(USER_ID, "current")).set({
      ...makeWorkoutPlan(),
      dailyOverrides: {
        "2026-07-01": { name: "Stale Past Override", muscles: [], exercises: [] },
      },
    });
    const result = await maybeCreatePlanAdjustmentProposal({
      db,
      userId: USER_ID,
      content: "I need to skip today.",
      structuredAnswer: { kind: "workout_plan_adjustment", dayKey: "Tue" },
    });

    // 2026-07-21 IS a Tuesday — override lands on the accept date itself,
    // and the past-dated override is pruned on the same write.
    await acceptPlanAdjustmentProposal(db, USER_ID, {
      proposalId: result!.proposalId,
      scope: "today",
      clientDate: "2026-07-21",
    });

    const planSnap = await db.doc(workoutPlanPath(USER_ID, "current")).get();
    expect(Object.keys(planSnap.data()?.dailyOverrides ?? {})).toEqual(["2026-07-21"]);
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

  it("scope 'today' does NOT create a trainingPrograms doc (program only needed for cascades)", async () => {
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
      clientDate: "2026-07-21",
    });

    const programSnap = await db.doc(trainingProgramPath(USER_ID)).get();
    expect(programSnap.exists).toBe(false);
  });

  it("today-scope accepts succeed even when the legacy plan has malformed exercises", async () => {
    // A legacy_pwa-written plan with garbage in an exercise would fail a
    // strict TrainingProgram backfill parse — the today path must never
    // touch the program, so this accept has to succeed regardless.
    const plan = makeWorkoutPlan() as Record<string, unknown>;
    (plan.days as Record<string, { exercises: unknown[] }>).Mon.exercises.push({
      name: "Corrupted",
      sets: "three",
      reps: null,
      bogusField: true,
    });
    await db.doc(workoutPlanPath(USER_ID, "current")).set(plan);

    const result = await maybeCreatePlanAdjustmentProposal({
      db,
      userId: USER_ID,
      content: "I need to skip today.",
      structuredAnswer: { kind: "workout_plan_adjustment", dayKey: "Tue" },
    });

    const acceptResult = await acceptPlanAdjustmentProposal(db, USER_ID, {
      proposalId: result!.proposalId,
      scope: "today",
      clientDate: "2026-07-21",
    });
    expect(acceptResult.ok).toBe(true);
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
      clientDate: "2026-07-21",
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
    // Server-generated content ONLY — the user's/model's free text must NOT
    // be laundered into confirmed memory (it never appears on the approval
    // card, so the human gate can't vet it).
    expect(factSnap.data()?.content).not.toContain("I need to skip today.");
    expect(factSnap.data()?.evidenceExcerpt).toBeUndefined();
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
