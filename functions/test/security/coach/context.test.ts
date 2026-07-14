import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { loadCoachContext } from "../../../src/coach/context.js";
import { planAdjustmentProposalPath, profilePath } from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

const USER_ID = "context-user-a";
const SESSION_ID = "session-a";

let app: App;
let db: Firestore;

function makeAcceptedProposal(overrides: Record<string, unknown> = {}) {
  return {
    userId: USER_ID,
    proposalId: "p-1",
    source: "coach_chat",
    decision: "accepted",
    category: "time_limit",
    riskLevel: "low",
    originalUserText: "short on time",
    summary: "User needs a shorter workout option.",
    rationale: "Shortening should preserve the highest-value movements.",
    appliesTo: { planId: "current", dayKey: "Mon" },
    proposedPlanPatch: { type: "shorten_workout", title: "Shorten today's workout", changes: [] },
    sourceCorpusEntryIds: [],
    safetyNotes: [],
    requiresFollowUp: false,
    createdAt: "2026-05-20T00:00:00.000Z",
    decidedAt: "2026-05-20T00:05:00.000Z",
    ...overrides,
  };
}

describe("loadCoachContext", () => {
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

  it("includes only accepted proposals, most recent first, capped at 5", async () => {
    await db.doc(planAdjustmentProposalPath(USER_ID, "p-1")).set(
      makeAcceptedProposal({ proposalId: "p-1", decidedAt: "2026-05-18T00:00:00.000Z" }),
    );
    await db.doc(planAdjustmentProposalPath(USER_ID, "p-2")).set(
      makeAcceptedProposal({ proposalId: "p-2", decidedAt: "2026-05-20T00:00:00.000Z" }),
    );
    const { decidedAt: _decidedAt, ...pendingProposal } = makeAcceptedProposal({
      proposalId: "p-3-pending",
      decision: "pending",
    });
    await db.doc(planAdjustmentProposalPath(USER_ID, "p-3-pending")).set(pendingProposal);

    const context = await loadCoachContext(db, USER_ID, SESSION_ID, {
      includePlanChanges: true,
    });

    expect(context.recentPlanChanges).toHaveLength(2);
    expect(context.recentPlanChanges[0]).toMatchObject({ proposalId: "p-2" });
    expect(context.recentPlanChanges[1]).toMatchObject({ proposalId: "p-1" });
  });

  it("returns an empty array when nothing has been accepted yet", async () => {
    const context = await loadCoachContext(db, USER_ID, SESSION_ID, {
      includePlanChanges: true,
    });
    expect(context.recentPlanChanges).toEqual([]);
  });

  it("skips the plan-change read entirely when the option is off (flag-off invariance)", async () => {
    await db.doc(planAdjustmentProposalPath(USER_ID, "p-1")).set(
      makeAcceptedProposal({ proposalId: "p-1" }),
    );
    const context = await loadCoachContext(db, USER_ID, SESSION_ID);
    expect(context.recentPlanChanges).toEqual([]);
  });
});
