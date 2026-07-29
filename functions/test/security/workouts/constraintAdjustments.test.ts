import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import {
  acceptPlanAdjustmentProposal,
  createPlanAdjustmentProposalFromTool,
  publishDraftProposals,
} from "../../../src/workouts/planAdjustments.js";
import { planAdjustmentProposalPath, profilePath, workoutPlanPath } from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

const USER_ID = "constraint-adjustment-user-a";
// A Wednesday. Pinned so rest_of_week's keep-filter never runs against the real
// clock — the calendar time bomb this suite has been bitten by twice.
const WEDNESDAY = "2026-07-15";

const SUBSTITUTE_PATCH = [
  {
    dayKey: "Wed" as const,
    dayName: "Push · no overhead",
    replacementExercises: [
      { name: "Landmine Press", sets: 4, reps: 8, weight: 45 },
      { name: "Incline Dumbbell Press", sets: 3, reps: 10, weight: 40 },
    ],
  },
];

let app: App;
let db: Firestore;

describe("space + difficulty adjustments are appliable, not dead ends", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });

  beforeEach(async () => {
    await Promise.allSettled([db.recursiveDelete(db.doc(`users/${USER_ID}`))]);
    await db.doc(profilePath(USER_ID)).set({ ...baseProfile, userId: USER_ID });
    await db.doc(workoutPlanPath(USER_ID, "current")).set({
      userId: USER_ID,
      planId: "current",
      source: "generated",
      createdAt: new Date().toISOString(),
      days: {
        Wed: {
          name: "Push",
          muscles: ["chest", "shoulders"],
          exercises: [
            { name: "Overhead Press", sets: 4, reps: 8, weight: 95 },
            { name: "Bench Press", sets: 3, reps: 8, weight: 135 },
          ],
        },
      },
    });
  });

  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  async function proposeAndPublish(
    reason: "equipment_unavailable" | "too_hard" | "too_easy",
    dayPatches: typeof SUBSTITUTE_PATCH | undefined,
    rawUserText: string,
  ) {
    const result = await createPlanAdjustmentProposalFromTool({
      db,
      userId: USER_ID,
      reason,
      userNote: rawUserText,
      scope: "today",
      dayPatches,
      rawUserText,
      clientDate: WEDNESDAY,
    });
    if (result.proposalId) {
      await publishDraftProposals(db, USER_ID, [result.proposalId]);
    }
    return result;
  }

  // The reported bug: "I don't have the vertical height in my basement for
  // overhead press." The model understood it and proposed a substitution; the
  // server refused it regardless, because equipment_limit required follow-up
  // unconditionally. No phrasing could get past that.
  it("applies an equipment/space swap when the coach supplies real substitutes", async () => {
    const result = await proposeAndPublish(
      "equipment_unavailable",
      SUBSTITUTE_PATCH,
      "my basement ceiling is too low to press overhead",
    );

    expect(result).toMatchObject({
      category: "equipment_limit",
      riskLevel: "low",
      requiresFollowUp: false,
    });

    await acceptPlanAdjustmentProposal(db, USER_ID, {
      proposalId: result.proposalId!,
      scope: "today",
      clientDate: WEDNESDAY,
    });

    const plan = (await db.doc(workoutPlanPath(USER_ID, "current")).get()).data();
    expect(plan?.dailyOverrides?.[WEDNESDAY]?.exercises?.[0]).toMatchObject({
      name: "Landmine Press",
    });
    // A today-scope swap must not rewrite the repeating template.
    expect(plan?.days?.Wed?.exercises?.[0]).toMatchObject({ name: "Overhead Press" });
  });

  it.each(["too_hard", "too_easy"] as const)(
    "applies a %s adjustment when the coach supplies real substitutes",
    async (reason) => {
      const result = await proposeAndPublish(reason, SUBSTITUTE_PATCH, "this session is off for me");
      expect(result).toMatchObject({ riskLevel: "low", requiresFollowUp: false });

      await acceptPlanAdjustmentProposal(db, USER_ID, {
        proposalId: result.proposalId!,
        scope: "today",
        clientDate: WEDNESDAY,
      });
      const snap = await db.doc(planAdjustmentProposalPath(USER_ID, result.proposalId!)).get();
      expect(snap.data()?.decision).toBe("accepted");
    },
  );

  // The other half of the rule. Without concrete content the card has nothing
  // for the user to read, so it must still be held for review — the original
  // behaviour, preserved.
  it.each(["equipment_unavailable", "too_hard", "too_easy"] as const)(
    "still holds a %s proposal for review when there is nothing concrete to approve",
    async (reason) => {
      const result = await proposeAndPublish(reason, undefined, "this isn't working for me");
      expect(result.requiresFollowUp).toBe(true);

      await expect(
        acceptPlanAdjustmentProposal(db, USER_ID, {
          proposalId: result.proposalId!,
          scope: "today",
          clientDate: WEDNESDAY,
        }),
      ).rejects.toThrow("plan_adjustment_requires_review");
    },
  );

  it("does not let concrete content lower a HIGH-risk proposal", async () => {
    // The escape hatch is about reviewability, not risk. A pain report still
    // has to go through triage no matter how concrete the substitution is.
    const result = await createPlanAdjustmentProposalFromTool({
      db,
      userId: USER_ID,
      reason: "equipment_unavailable",
      userNote: "can't press overhead",
      scope: "today",
      dayPatches: SUBSTITUTE_PATCH,
      rawUserText: "my shoulder hurts when I press overhead",
      clientDate: WEDNESDAY,
    });
    expect(result).toMatchObject({
      category: "injury_pain",
      riskLevel: "high",
      requiresFollowUp: true,
    });
  });
});
