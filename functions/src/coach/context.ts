import type { DocumentData, Firestore } from "firebase-admin/firestore";
import {
  coachSessionPath,
  profilePath,
  progressSummaryPath,
  userRoot,
} from "../paths.js";

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
  // Derived progress rollup (derivedSummaries/progress_current, built by
  // progress/store.ts). Null when the doc doesn't exist yet, the read
  // failed, or the includeProgress option is off.
  progressSummary: DocumentData | null;
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
  options: { includePlanChanges?: boolean; includeProgress?: boolean } = {},
): Promise<CoachLoadedContext> {
  // The plan-change read needs a composite index (decision asc, decidedAt
  // desc). It's advisory context, never load-bearing — so it's (a) gated
  // behind the tool-loop feature bundle and (b) degraded to [] on failure
  // rather than turning an index-still-building window into a full coach
  // outage for every user.
  const recentPlanChangesPromise = options.includePlanChanges
    ? db
        .collection(`${userRoot(userId)}/planAdjustmentProposals`)
        .where("decision", "==", "accepted")
        .orderBy("decidedAt", "desc")
        .limit(5)
        .get()
        .then((snap) => snap.docs.map((doc) => doc.data()))
        .catch(() => [] as DocumentData[])
    : Promise.resolve([] as DocumentData[]);

  // Derived progress rollup — same posture as the plan-change read: gated
  // behind the tool-loop feature bundle, degraded to null on any failure
  // (missing doc, read error) so progress can never take down a coach turn.
  const progressSummaryPromise = options.includeProgress
    ? db
        .doc(progressSummaryPath(userId))
        .get()
        .then((snap) => (snap.exists ? snap.data() ?? null : null))
        .catch(() => null)
    : Promise.resolve(null);

  const [
    profileSnap,
    recentFactsSnap,
    recentLogsSnap,
    sessionHistorySnap,
    recentPlanChanges,
    progressSummary,
  ] =
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
      recentPlanChangesPromise,
      progressSummaryPromise,
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
    recentPlanChanges,
    progressSummary,
  };
}
