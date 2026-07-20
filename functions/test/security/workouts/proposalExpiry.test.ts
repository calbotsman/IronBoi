import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import {
  acceptPlanAdjustmentProposal,
  expireStalePendingProposals,
  findLatestPendingProposal,
  maybeCreatePlanAdjustmentProposal,
} from "../../../src/workouts/planAdjustments.js";
import { planAdjustmentProposalPath, profilePath, workoutPlanPath } from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

// Unique per-file user ids — the emulator DB is shared across the suite. The
// expiry sweep scans collectionGroup("planAdjustmentProposals"), so it can
// also touch leftovers from other test files; every doc-level assertion is
// scoped to these users, and sweep counters are only checked with >=.
const USER_STALE = "proposal-expiry-user-a";
const USER_FRESH = "proposal-expiry-user-b";
const USER_DECIDED = "proposal-expiry-user-c";
const ALL_USERS = [USER_STALE, USER_FRESH, USER_DECIDED];

// Pinned dates everywhere (no wall clock): the sweep takes an injected
// nowISO, and every proposal's createdAt is overwritten to a fixed date, so
// nothing here depends on the day the suite runs.
//   cutoff = PINNED_NOW - 7 days = 2026-07-08T12:00:00.000Z
const PINNED_NOW = "2026-07-15T12:00:00.000Z";
const STALE_CREATED = "2026-07-07T11:00:00.000Z"; // 8 days old → expires
const FRESH_CREATED = "2026-07-09T12:00:00.000Z"; // 6 days old → survives

let app: App;
let db: Firestore;

// Every weekday present with 2+ exercises: maybeCreatePlanAdjustmentProposal
// keys a time_limit proposal to the CURRENT weekday (server clock), and needs
// at least 2 exercises on that day to stay auto-appliable — covering all 7
// keys keeps this file green regardless of which day it runs.
function makeWorkoutPlan(userId: string) {
  const day = (name: string) => ({
    name,
    muscles: ["Full Body"],
    exercises: [
      { name: "Goblet Squat", sets: 3, reps: 10, weight: 40 },
      { name: "Push-Up", sets: 3, reps: 12, weight: 0 },
      { name: "Plank", sets: 3, reps: 30, weight: 0 },
    ],
  });
  return {
    userId,
    planId: "current",
    source: "coach_generated",
    updatedAt: "2026-07-01T00:00:00.000Z",
    days: {
      Sun: day("Sun Session"),
      Mon: day("Mon Session"),
      Tue: day("Tue Session"),
      Wed: day("Wed Session"),
      Thu: day("Thu Session"),
      Fri: day("Fri Session"),
      Sat: day("Sat Session"),
    },
  };
}

// A real, low-risk, auto-appliable pending proposal (time_limit →
// shorten_workout), then createdAt backdated to the pinned fixture date —
// persistPlanAdjustmentProposal stamps the wall clock, which would defeat
// date pinning.
async function createPendingProposal(userId: string, createdAt: string) {
  const created = await maybeCreatePlanAdjustmentProposal({
    db,
    userId,
    content: "I only have 25 minutes today, can you shorten the workout?",
  });
  expect(created).toMatchObject({ category: "time_limit", riskLevel: "low", requiresFollowUp: false });
  await db
    .doc(planAdjustmentProposalPath(userId, created!.proposalId))
    .set({ createdAt }, { merge: true });
  return created!.proposalId;
}

describe("pending plan-adjustment proposal TTL", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });

  beforeEach(async () => {
    await Promise.allSettled(
      ALL_USERS.map((userId) => db.recursiveDelete(db.doc(`users/${userId}`))),
    );
    await Promise.all(
      ALL_USERS.map(async (userId) => {
        await db.doc(profilePath(userId)).set({ ...baseProfile, userId });
        await db.doc(workoutPlanPath(userId, "current")).set(makeWorkoutPlan(userId));
      }),
    );
  });

  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  it("flips pending proposals older than 7 days to expired and leaves fresh ones pending", async () => {
    const staleId = await createPendingProposal(USER_STALE, STALE_CREATED);
    const freshId = await createPendingProposal(USER_FRESH, FRESH_CREATED);

    const result = await expireStalePendingProposals(db, PINNED_NOW);
    expect(result.expired).toBeGreaterThanOrEqual(1);
    expect(result.failed).toBe(0);

    const staleSnap = await db.doc(planAdjustmentProposalPath(USER_STALE, staleId)).get();
    expect(staleSnap.data()).toMatchObject({ decision: "expired", decidedAt: PINNED_NOW });

    const freshSnap = await db.doc(planAdjustmentProposalPath(USER_FRESH, freshId)).get();
    expect(freshSnap.data()?.decision).toBe("pending");
    expect(freshSnap.data()?.decidedAt).toBeUndefined();

    // The expired proposal no longer counts as pending anywhere — the card
    // resolver skips it, the fresh user's card is untouched.
    expect(await findLatestPendingProposal(db, USER_STALE)).toBeNull();
    expect((await findLatestPendingProposal(db, USER_FRESH))?.docId).toBe(freshId);

    // Idempotent: a second sweep finds nothing new for these users.
    await expireStalePendingProposals(db, PINNED_NOW);
    const staleAgain = await db.doc(planAdjustmentProposalPath(USER_STALE, staleId)).get();
    expect(staleAgain.data()).toMatchObject({ decision: "expired", decidedAt: PINNED_NOW });
  });

  it("leaves already-decided old proposals untouched", async () => {
    const decidedId = await createPendingProposal(USER_DECIDED, STALE_CREATED);
    await db
      .doc(planAdjustmentProposalPath(USER_DECIDED, decidedId))
      .set({ decision: "accepted", decidedAt: "2026-07-08T00:00:00.000Z" }, { merge: true });

    await expireStalePendingProposals(db, PINNED_NOW);

    const snap = await db.doc(planAdjustmentProposalPath(USER_DECIDED, decidedId)).get();
    expect(snap.data()).toMatchObject({
      decision: "accepted",
      decidedAt: "2026-07-08T00:00:00.000Z",
    });
  });

  it("an expired proposal can no longer be accepted", async () => {
    const staleId = await createPendingProposal(USER_STALE, STALE_CREATED);
    await expireStalePendingProposals(db, PINNED_NOW);

    await expect(
      acceptPlanAdjustmentProposal(db, USER_STALE, {
        proposalId: staleId,
        scope: "today",
        clientDate: "2026-07-15",
      }),
    ).rejects.toThrow("plan_adjustment_not_pending");
  });
});
