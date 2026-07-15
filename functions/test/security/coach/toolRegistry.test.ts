import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { buildCoachToolRegistry } from "../../../src/coach/toolRegistry.js";
import { executeTool } from "../../../src/tools/executor.js";
import { planAdjustmentProposalPath, profilePath, workoutPlanPath } from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

const USER_ID = "tool-registry-user-a";

let app: App;
let db: Firestore;

describe("coach tool registry", () => {
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

  it("adapt_plan without scope analyzes but does NOT persist — needsScopeConfirmation instead", async () => {
    await db.doc(workoutPlanPath(USER_ID, "current")).set({
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
          ],
        },
      },
    });

    const registry = buildCoachToolRegistry(db, { latestPendingProposalId: null });
    const result = (await executeTool(
      registry,
      "adapt_plan",
      { reason: "time_constraint", userNote: "Only have 15 minutes", dayKey: "Mon" },
      { authenticatedUserId: USER_ID },
    )) as Record<string, unknown>;

    expect(result).toMatchObject({
      ok: true,
      category: "time_limit",
      riskLevel: "low",
      requiresFollowUp: false,
      needsScopeConfirmation: true,
      proposalId: null,
      dayKey: "Mon",
    });

    // Nothing persisted — a scope-less call is a question, not a proposal.
    // Persisting here would orphan a pending doc per scope exchange.
    const pending = await db.collection(`users/${USER_ID}/planAdjustmentProposals`).get();
    expect(pending.empty).toBe(true);
  });

  it("adapt_plan does not flag needsScopeConfirmation once scope is supplied", async () => {
    await db.doc(workoutPlanPath(USER_ID, "current")).set({
      userId: USER_ID,
      planId: "current",
      source: "coach_generated",
      updatedAt: "2026-07-06T00:00:00.000Z",
      days: { Mon: { name: "Rest day", muscles: [], exercises: [] } },
    });

    const registry = buildCoachToolRegistry(db, { latestPendingProposalId: null });
    const result = (await executeTool(
      registry,
      "adapt_plan",
      { reason: "missed_session", userNote: "Missed Monday", dayKey: "Mon", scope: "today" },
      { authenticatedUserId: USER_ID },
    )) as Record<string, unknown>;

    expect(result).toMatchObject({ ok: true, needsScopeConfirmation: false, category: "skip_or_reschedule" });

    const proposalSnap = await db.doc(planAdjustmentProposalPath(USER_ID, result.proposalId as string)).get();
    expect(proposalSnap.data()).toMatchObject({ appliesTo: { dayKey: "Mon", scope: "today" } });
  });

  it("adapt_plan rejects a model call carrying an identity-shaped field", async () => {
    const registry = buildCoachToolRegistry(db, { latestPendingProposalId: null });
    await expect(
      executeTool(
        registry,
        "adapt_plan",
        { reason: "time_constraint", userNote: "note", userId: "someone-else" },
        { authenticatedUserId: USER_ID },
      ),
    ).rejects.toThrow(/identity-shaped fields not allowed/);
  });

  it("adapt_plan returns a validation error instead of throwing on malformed args", async () => {
    const registry = buildCoachToolRegistry(db, { latestPendingProposalId: null });
    const result = (await executeTool(
      registry,
      "adapt_plan",
      { reason: "not_a_real_reason" },
      { authenticatedUserId: USER_ID },
    )) as Record<string, unknown>;

    expect(result).toEqual({ ok: false, error: "invalid_adapt_plan_args" });
  });

  it("ask_follow_up_question returns the rendered question", async () => {
    const registry = buildCoachToolRegistry(db, { latestPendingProposalId: null });
    const result = await executeTool(
      registry,
      "ask_follow_up_question",
      { reason: "ambiguous_goal", question: "What's the main goal for this cycle?" },
      { authenticatedUserId: USER_ID },
    );

    expect(result).toEqual({ ok: true, renderedQuestion: "What's the main goal for this cycle?" });
  });
});
