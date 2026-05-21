import { doc, getDoc, setDoc, updateDoc } from "firebase/firestore";
import { afterAll, beforeEach, describe, it } from "vitest";
import { userScopedCollections } from "../../../src/firestore/userScopedCollections.js";
import {
  assertFails,
  assertSucceeds,
  authedDb,
  cleanupTestEnv,
  clearFirestore,
  withAdminDb,
} from "../fixtures/emulator.js";
import { USER_A, USER_B, baseProfile, withUserId } from "../fixtures/users.js";

const iso = "2026-05-08T00:00:00.000Z";

function userMessage(extra = {}) {
  return {
    messageId: "m1",
    role: "user",
    content: "hello",
    timestamp: iso,
    toolCallIds: [],
    status: "queued",
    ...extra,
  };
}

function proposal(extra = {}) {
  return {
    userId: USER_A,
    proposalId: "p1",
    proposedChange: { title: "Increase bench" },
    decision: "pending",
    createdAt: iso,
    ...extra,
  };
}

function planAdjustmentProposal(extra = {}) {
  return {
    userId: USER_A,
    proposalId: "a1",
    source: "coach_chat",
    decision: "pending",
    category: "injury_pain",
    riskLevel: "high",
    originalUserText: "I hurt my ankle. Adjust today.",
    summary: "User reported pain or injury and needs a safety-first adjustment.",
    rationale: "Pain reports require avoiding aggravating movements and gathering more context.",
    appliesTo: {
      planId: "current",
      dayKey: "Mon",
    },
    proposedPlanPatch: {
      type: "review_only",
      title: "Ask one follow-up before changing the plan",
      changes: ["Keep the current plan unchanged until the missing context is clear."],
    },
    sourceCorpusEntryIds: ["myo_pain_injury_adjustment_v1"],
    safetyNotes: ["Do not diagnose injuries or prescribe rehab protocols."],
    requiresFollowUp: true,
    createdAt: iso,
    ...extra,
  };
}

describe("Firestore rules isolation", () => {
  beforeEach(async () => {
    await clearFirestore();
  });

  afterAll(async () => {
    await cleanupTestEnv();
  });

  it("profile_owner_can_read", async () => {
    await withAdminDb(async (admin) => {
      await setDoc(doc(admin, `users/${USER_A}/profile/current`), baseProfile);
    });
    const db = await authedDb(USER_A);
    await assertSucceeds(getDoc(doc(db, `users/${USER_A}/profile/current`)));
  });

  it("profile_owner_write_denied_if_server_only", async () => {
    const db = await authedDb(USER_A);
    await assertFails(setDoc(doc(db, `users/${USER_A}/profile/current`), baseProfile));
  });

  it("profile_owner_cannot_poison_onboarding_state", async () => {
    const db = await authedDb(USER_A);
    await assertFails(
      setDoc(doc(db, `users/${USER_A}/profile/current`), {
        ...baseProfile,
        onboardingStatus: "complete",
        onboardingStep: "complete",
        activeProgramProposalId: "attacker-controlled",
      }),
    );
  });

  it("profile_cross_user_read_denied", async () => {
    await withAdminDb(async (admin) => {
      await setDoc(doc(admin, `users/${USER_B}/profile/current`), withUserId(baseProfile, USER_B));
    });
    const userA = await authedDb(USER_A);
    await assertFails(getDoc(doc(userA, `users/${USER_B}/profile/current`)));
  });

  it("memoryFacts_owner_write_denied_if_server_only", async () => {
    const db = await authedDb(USER_A);
    await assertFails(
      setDoc(doc(db, `users/${USER_A}/memoryFacts/f1`), {
        userId: USER_A,
        factId: "f1",
        content: "Prefers morning workouts",
      }),
    );
  });

  it("coachMessage_owner_create_user_role_queued", async () => {
    const db = await authedDb(USER_A);
    await assertSucceeds(
      setDoc(doc(db, `users/${USER_A}/coachSessions/s1/messages/m1`), userMessage()),
    );
  });

  it("coachMessage_owner_create_with_input_mode_and_structured_answer", async () => {
    const db = await authedDb(USER_A);
    await assertSucceeds(
      setDoc(
        doc(db, `users/${USER_A}/coachSessions/s1/messages/m1`),
        userMessage({
          inputMode: "tap",
          structuredAnswer: { goals: ["muscle_gain"] },
          turnId: "turn_1",
        }),
      ),
    );
  });

  it("coachMessage_owner_invalid_input_mode_denied", async () => {
    const db = await authedDb(USER_A);
    await assertFails(
      setDoc(
        doc(db, `users/${USER_A}/coachSessions/s1/messages/m1`),
        userMessage({ inputMode: "admin_override" }),
      ),
    );
  });

  it("coachMessage_owner_create_coach_role_denied", async () => {
    const db = await authedDb(USER_A);
    await assertFails(
      setDoc(
        doc(db, `users/${USER_A}/coachSessions/s1/messages/m1`),
        userMessage({ role: "coach" }),
      ),
    );
  });

  it("coachMessage_owner_extra_fields_denied", async () => {
    const db = await authedDb(USER_A);
    await assertFails(
      setDoc(
        doc(db, `users/${USER_A}/coachSessions/s1/messages/m1`),
        userMessage({ injectedTool: "x" }),
      ),
    );
  });

  it("coachMessage_forgery_sweep", async () => {
    const db = await authedDb(USER_A);
    const attempts = [
      { role: "coach", status: "queued", content: "fake" },
      { role: "coach", status: "complete", content: "fake" },
      { role: "user", status: "complete", content: "fake" },
      { role: "user", status: "streaming", content: "fake" },
      { role: "system", status: "complete", content: "fake" },
      { role: "user", status: "queued", content: "fake", toolResults: [] },
      { role: "user", status: "queued", content: "fake", citations: [] },
    ];

    for (const [index, attempt] of attempts.entries()) {
      await assertFails(
        setDoc(
          doc(db, `users/${USER_A}/coachSessions/s1/messages/f${index}`),
          userMessage({ ...attempt, messageId: `f${index}` }),
        ),
      );
    }
  });

  it("programProposals_owner_can_set_decision", async () => {
    await withAdminDb(async (admin) => {
      await setDoc(doc(admin, `users/${USER_A}/programProposals/p1`), proposal());
    });
    const owner = await authedDb(USER_A);
    await assertSucceeds(
      updateDoc(doc(owner, `users/${USER_A}/programProposals/p1`), {
        decision: "accepted",
        decidedAt: iso,
      }),
    );
  });

  it("programProposals_owner_cannot_modify_content", async () => {
    await withAdminDb(async (admin) => {
      await setDoc(doc(admin, `users/${USER_A}/programProposals/p1`), proposal());
    });
    const owner = await authedDb(USER_A);
    await assertFails(
      updateDoc(doc(owner, `users/${USER_A}/programProposals/p1`), {
        proposedChange: { title: "Tampered" },
      }),
    );
  });

  it("planAdjustmentProposals_owner_can_read_and_set_decision", async () => {
    await withAdminDb(async (admin) => {
      await setDoc(
        doc(admin, `users/${USER_A}/planAdjustmentProposals/a1`),
        planAdjustmentProposal(),
      );
    });
    const owner = await authedDb(USER_A);
    await assertSucceeds(getDoc(doc(owner, `users/${USER_A}/planAdjustmentProposals/a1`)));
    await assertSucceeds(
      updateDoc(doc(owner, `users/${USER_A}/planAdjustmentProposals/a1`), {
        decision: "rejected",
        decidedAt: iso,
      }),
    );
  });

  it("planAdjustmentProposals_owner_cannot_create_or_modify_content", async () => {
    const owner = await authedDb(USER_A);
    await assertFails(
      setDoc(
        doc(owner, `users/${USER_A}/planAdjustmentProposals/a1`),
        planAdjustmentProposal(),
      ),
    );

    await withAdminDb(async (admin) => {
      await setDoc(
        doc(admin, `users/${USER_A}/planAdjustmentProposals/a1`),
        planAdjustmentProposal(),
      );
    });

    await assertFails(
      updateDoc(doc(owner, `users/${USER_A}/planAdjustmentProposals/a1`), {
        proposedPlanPatch: {
          type: "replace_day_focus",
          title: "Tampered",
          changes: ["Do unsafe stuff"],
        },
      }),
    );
  });

  it("corpus_authed_user_can_read", async () => {
    const db = await authedDb(USER_A);
    await assertSucceeds(getDoc(doc(db, "corpus/example")));
  });

  it("corpus_authed_user_write_denied", async () => {
    const db = await authedDb(USER_A);
    await assertFails(setDoc(doc(db, "corpus/example"), { title: "Nope" }));
  });

  it("usage_owner_can_read_but_not_write", async () => {
    await withAdminDb(async (admin) => {
      await setDoc(doc(admin, `users/${USER_A}/usage/2026-05-11`), {
        messageCount: 1,
        inputTokens: 10,
        outputTokens: 5,
        capReached: false,
      });
    });

    const db = await authedDb(USER_A);
    await assertSucceeds(getDoc(doc(db, `users/${USER_A}/usage/2026-05-11`)));
    await assertFails(
      setDoc(doc(db, `users/${USER_A}/usage/2026-05-11`), {
        messageCount: 999,
      }),
    );
  });

  it("activeWorkout_owner_can_read_but_not_write", async () => {
    await withAdminDb(async (admin) => {
      await setDoc(doc(admin, `users/${USER_A}/activeWorkout/current`), {
        userId: USER_A,
        sessionId: "s1",
        status: "active",
      });
    });

    const db = await authedDb(USER_A);
    await assertSucceeds(getDoc(doc(db, `users/${USER_A}/activeWorkout/current`)));
    await assertFails(
      setDoc(doc(db, `users/${USER_A}/activeWorkout/current`), {
        userId: USER_A,
        sessionId: "tampered",
      }),
    );
  });

  it("workoutSessions_owner_can_read_but_not_write", async () => {
    await withAdminDb(async (admin) => {
      await setDoc(doc(admin, `users/${USER_A}/workoutSessions/s1`), {
        userId: USER_A,
        sessionId: "s1",
        status: "active",
      });
    });

    const db = await authedDb(USER_A);
    await assertSucceeds(getDoc(doc(db, `users/${USER_A}/workoutSessions/s1`)));
    await assertFails(
      setDoc(doc(db, `users/${USER_A}/workoutSessions/s1`), {
        userId: USER_A,
        sessionId: "tampered",
      }),
    );
  });

  it("isolation_full_sweep", async () => {
    const userA = await authedDb(USER_A);
    for (const path of userScopedCollections) {
      await assertFails(getDoc(doc(userA, `users/${USER_B}/${path}`)));
      await assertFails(setDoc(doc(userA, `users/${USER_B}/${path}`), { test: true }));
    }
  });
});
