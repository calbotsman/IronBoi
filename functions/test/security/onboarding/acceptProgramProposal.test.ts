import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { FieldValue, getFirestore, type Firestore } from "firebase-admin/firestore";
import { acceptProgramProposal } from "../../../src/onboarding/flow.js";
import { profilePath, programProposalPath, workoutPlanPath } from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

const clientDecidedAt = "2001-01-01T00:00:00.000Z";
const ACCEPT_USER = "accept-proposal-user-a";

let app: App;
let db: Firestore;

describe("acceptProgramProposal", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });

  beforeEach(async () => {
    await Promise.allSettled([
      db.recursiveDelete(db.doc(`users/${ACCEPT_USER}`)),
    ]);
  });

  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  it("atomically accepts the proposal with server-owned timestamps", async () => {
    await db.doc(programProposalPath(ACCEPT_USER, "proposal-1")).set({
      ...makeProposal(),
      serverCreatedAt: FieldValue.serverTimestamp(),
    });

    const result = await acceptProgramProposal(db, ACCEPT_USER, {
      proposalId: "proposal-1",
      decidedAt: clientDecidedAt,
    });

    const [profileSnap, planSnap, proposalSnap] = await Promise.all([
      db.doc(profilePath(ACCEPT_USER)).get(),
      db.doc(workoutPlanPath(ACCEPT_USER, "current")).get(),
      db.doc(programProposalPath(ACCEPT_USER, "proposal-1")).get(),
    ]);

    expect(result.ok).toBe(true);
    expect(result.proposalId).toBe("proposal-1");
    expect(result.decidedAt).not.toBe(clientDecidedAt);

    expect(profileSnap.data()).toMatchObject({
      userId: ACCEPT_USER,
      onboardingStatus: "complete",
      onboardingStep: "complete",
      activeProgramProposalId: "proposal-1",
      updatedAt: result.decidedAt,
    });
    expect(profileSnap.data()?.source).toBeUndefined();
    expect(profileSnap.data()?.decision).toBeUndefined();
    expect(profileSnap.data()?.nutritionTargets).toBeUndefined();
    expect(planSnap.data()).toMatchObject({
      userId: ACCEPT_USER,
      planId: "current",
      source: "coach_generated",
      updatedAt: result.decidedAt,
    });
    expect(proposalSnap.data()).toMatchObject({
      userId: ACCEPT_USER,
      proposalId: "proposal-1",
      decision: "accepted",
      decidedAt: result.decidedAt,
      clientDecidedAt,
    });
    expect(proposalSnap.data()?.serverDecidedAt).toBeTruthy();
  });

  it("rejects non-pending proposals without activating a plan", async () => {
    await db.doc(programProposalPath(ACCEPT_USER, "proposal-1")).set(
      makeProposal({ decision: "accepted" }),
    );

    await expect(
      acceptProgramProposal(db, ACCEPT_USER, { proposalId: "proposal-1" }),
    ).rejects.toThrow("program_proposal_not_pending");

    const [profileSnap, planSnap] = await Promise.all([
      db.doc(profilePath(ACCEPT_USER)).get(),
      db.doc(workoutPlanPath(ACCEPT_USER, "current")).get(),
    ]);

    expect(profileSnap.exists).toBe(false);
    expect(planSnap.exists).toBe(false);
  });
});

function makeProposal(extra: Record<string, unknown> = {}) {
  const now = "2026-05-11T00:00:00.000Z";
  return {
    userId: ACCEPT_USER,
    proposalId: "proposal-1",
    source: "onboarding",
    decision: "pending",
    profile: {
      ...baseProfile,
      userId: ACCEPT_USER,
      onboardingStatus: "proposal_ready",
      onboardingStep: "review_plan",
      onboardingMissingFields: [],
    },
    workoutPlan: {
      userId: ACCEPT_USER,
      planId: "proposal-1",
      source: "coach_generated",
      updatedAt: now,
      days: {
        Mon: {
          name: "Push",
          muscles: ["Chest"],
          exercises: [{ name: "Barbell Bench Press", sets: 3, reps: 8, weight: 95 }],
        },
      },
    },
    nutritionTargets: {
      calories: { min: 2200, max: 2400, note: "Estimate range only." },
      proteinGrams: { min: 120, max: 165 },
      assumptions: ["Starter estimate."],
      safetyNotes: ["General wellness guidance only."],
    },
    createdAt: now,
    ...extra,
  };
}
