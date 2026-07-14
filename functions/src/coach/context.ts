import type { DocumentData, Firestore } from "firebase-admin/firestore";
import { coachSessionPath, profilePath, userRoot } from "../paths.js";

export type CoachLoadedContext = {
  profile: DocumentData | null;
  recentFacts: DocumentData[];
  recentLogs: DocumentData[];
  sessionHistory: DocumentData[];
  // Phase 2 Task 2.3 — count of proposed-but-unconfirmed memory facts.
  // Surfaced to the bundle so the coach knows there are pending items
  // waiting for user review, without those items influencing this reply.
  pendingProposalCount: number;
  // Recently accepted plan-adjustment proposals — lets the coach reference
  // a past change ("since we shortened Tuesday's session...") instead of
  // re-asking. See workouts/planAdjustments.ts acceptPlanAdjustmentProposal.
  recentPlanChanges: DocumentData[];
};

// A fact is "confirmed-for-prompt" if either:
//   - state === "confirmed" (Phase 2 Task 2.3+), OR
//   - state is undefined (legacy facts predating the proposal-queue change
//     are grandfathered in as confirmed; they were already in the prompt).
function isConfirmedForPrompt(fact: DocumentData): boolean {
  return fact.state === undefined || fact.state === "confirmed";
}

export async function loadCoachContext(
  db: Firestore,
  userId: string,
  sessionId: string,
): Promise<CoachLoadedContext> {
  const [profileSnap, recentFactsSnap, recentLogsSnap, sessionHistorySnap, recentPlanChangesSnap] =
    await Promise.all([
      db.doc(profilePath(userId)).get(),
      db
        .collection(`${userRoot(userId)}/memoryFacts`)
        .orderBy("createdAt", "desc")
        .limit(50)
        .get(),
      db
        .collection(`${userRoot(userId)}/workoutLogs`)
        .orderBy("date", "desc")
        .limit(14)
        .get(),
      db
        .collection(`${coachSessionPath(userId, sessionId)}/messages`)
        .orderBy("serverCreatedAt", "asc")
        .limit(40)
        .get(),
      db
        .collection(`${userRoot(userId)}/planAdjustmentProposals`)
        .where("decision", "==", "accepted")
        .orderBy("decidedAt", "desc")
        .limit(5)
        .get(),
    ]);

  const allFacts = recentFactsSnap.docs
    .map((doc) => doc.data())
    .filter((fact) => !fact.userDeletedAt);

  const confirmedFacts = allFacts.filter(isConfirmedForPrompt);
  const pendingProposalCount = allFacts.filter(
    (fact) => fact.state === "proposed",
  ).length;

  return {
    profile: profileSnap.exists ? profileSnap.data() ?? null : null,
    recentFacts: confirmedFacts,
    recentLogs: recentLogsSnap.docs.map((doc) => doc.data()),
    sessionHistory: sessionHistorySnap.docs.map((doc) => doc.data()),
    pendingProposalCount,
    recentPlanChanges: recentPlanChangesSnap.docs.map((doc) => doc.data()),
  };
}
