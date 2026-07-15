import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import {
  acceptLatestPlanAdjustmentFromChat,
  createPlanAdjustmentProposalFromTool,
  findLatestPendingProposal,
  rejectLatestPlanAdjustmentFromChat,
} from "../../../src/workouts/planAdjustments.js";
import {
  planAdjustmentProposalPath,
  planAdjustmentProposalsCollectionPath,
  profilePath,
  workoutPlanPath,
} from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

const USER_ID = "chat-decision-user-a";

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
        name: "Push",
        muscles: ["Chest"],
        exercises: [
          { name: "Barbell Bench Press", sets: 3, reps: 8, weight: 95 },
          { name: "Incline Dumbbell Press", sets: 3, reps: 10, weight: 40 },
          { name: "Cable Fly", sets: 3, reps: 12, weight: 25 },
        ],
      },
      Tue: {
        name: "Pull",
        muscles: ["Back"],
        exercises: [{ name: "Deadlift", sets: 3, reps: 5, weight: 185 }],
      },
    },
  };
}

describe("chat-driven plan adjustment decisions", () => {
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

  async function createPendingViaTool(scope?: "today" | "going_forward") {
    return createPlanAdjustmentProposalFromTool({
      db,
      userId: USER_ID,
      reason: "time_constraint",
      userNote: "Only have 20 minutes",
      dayKey: "Mon",
      scope,
    });
  }

  it("chat accept applies the latest pending proposal through the same gate as the card", async () => {
    const created = await createPendingViaTool("going_forward");
    expect(created.proposalId).toBeTruthy();

    const result = await acceptLatestPlanAdjustmentFromChat(db, USER_ID, undefined);
    expect(result).toMatchObject({ ok: true, appliedScope: "going_forward" });

    const proposalSnap = await db
      .doc(planAdjustmentProposalPath(USER_ID, created.proposalId!))
      .get();
    expect(proposalSnap.data()?.decision).toBe("accepted");

    // The plan actually changed (shorten_workout trims accessories).
    const planSnap = await db.doc(workoutPlanPath(USER_ID, "current")).get();
    const monday = planSnap.data()?.days?.Mon;
    expect(monday.exercises.length).toBeLessThan(3);
    expect(planSnap.data()?.source).toBe("user_edited");
  });

  it("chat accept without a known scope returns scope_required and changes nothing", async () => {
    // A scope-less pending doc is what the deterministic keyword classifier
    // produces (the tool path never persists without scope) — write one
    // directly, the way sendCoachMessage's classifier does.
    await db.doc(planAdjustmentProposalPath(USER_ID, "adjustment_scopeless")).set({
      userId: USER_ID,
      proposalId: "adjustment_scopeless",
      source: "coach_chat",
      decision: "pending",
      category: "time_limit",
      riskLevel: "low",
      originalUserText: "Only have 20 minutes",
      summary: "User needs a shorter workout option.",
      rationale: "Shortening should preserve the highest-value movements.",
      appliesTo: { planId: "current", dayKey: "Mon" },
      proposedPlanPatch: {
        type: "shorten_workout",
        title: "Shorten Monday",
        changes: ["Trim accessories"],
        removeExercises: ["Cable Fly"],
        addExercises: [],
      },
      sourceCorpusEntryIds: [],
      safetyNotes: [],
      requiresFollowUp: false,
      createdAt: new Date().toISOString(),
    });

    const result = await acceptLatestPlanAdjustmentFromChat(db, USER_ID, undefined);
    expect(result).toMatchObject({ ok: false, error: "scope_required" });

    const planSnap = await db.doc(workoutPlanPath(USER_ID, "current")).get();
    expect(planSnap.data()?.days?.Mon.exercises).toHaveLength(3);
  });

  it("chat accept refuses when there is no pending proposal", async () => {
    const result = await acceptLatestPlanAdjustmentFromChat(db, USER_ID, "today");
    expect(result).toMatchObject({ ok: false, error: "no_pending_proposal" });
  });

  it("chat accept surfaces the review gate for risky proposals instead of applying", async () => {
    // pain_or_discomfort → injury_pain → high risk + requiresFollowUp.
    const created = await createPlanAdjustmentProposalFromTool({
      db,
      userId: USER_ID,
      reason: "pain_or_discomfort",
      userNote: "my knee hurts",
      dayKey: "Mon",
      scope: "today",
    });
    expect(created.proposalId).toBeTruthy();

    const result = await acceptLatestPlanAdjustmentFromChat(db, USER_ID, "today");
    expect(result).toMatchObject({ ok: false, error: "plan_adjustment_requires_review" });
  });

  it("chat reject marks the latest pending proposal rejected", async () => {
    const created = await createPendingViaTool("today");
    const result = await rejectLatestPlanAdjustmentFromChat(db, USER_ID);
    expect(result).toMatchObject({ ok: true, proposalId: created.proposalId });

    const snap = await db.doc(planAdjustmentProposalPath(USER_ID, created.proposalId!)).get();
    expect(snap.data()?.decision).toBe("rejected");
    expect(snap.data()?.decidedAt).toBeTruthy();
  });

  it("a revised proposal supersedes the previous pending one", async () => {
    const first = await createPendingViaTool("today");
    const second = await createPlanAdjustmentProposalFromTool({
      db,
      userId: USER_ID,
      reason: "schedule_change",
      userNote: "actually just skip Tuesday",
      dayKey: "Tue",
      scope: "today",
    });

    const firstSnap = await db.doc(planAdjustmentProposalPath(USER_ID, first.proposalId!)).get();
    expect(firstSnap.data()?.decision).toBe("superseded");

    const pending = await db
      .collection(planAdjustmentProposalsCollectionPath(USER_ID))
      .where("decision", "==", "pending")
      .get();
    expect(pending.docs).toHaveLength(1);
    expect(pending.docs[0].data().proposalId).toBe(second.proposalId);

    const latest = await findLatestPendingProposal(db, USER_ID);
    expect(latest?.proposalId).toBe(second.proposalId);
  });
});
