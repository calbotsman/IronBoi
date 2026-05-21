import type { DocumentData, Firestore } from "firebase-admin/firestore";
import { coachSessionPath, profilePath, userRoot } from "../paths.js";

export type CoachLoadedContext = {
  profile: DocumentData | null;
  recentFacts: DocumentData[];
  recentLogs: DocumentData[];
  sessionHistory: DocumentData[];
};

export async function loadCoachContext(
  db: Firestore,
  userId: string,
  sessionId: string,
): Promise<CoachLoadedContext> {
  const [profileSnap, recentFactsSnap, recentLogsSnap, sessionHistorySnap] =
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
    ]);

  return {
    profile: profileSnap.exists ? profileSnap.data() ?? null : null,
    recentFacts: recentFactsSnap.docs
      .map((doc) => doc.data())
      .filter((fact) => !fact.userDeletedAt),
    recentLogs: recentLogsSnap.docs.map((doc) => doc.data()),
    sessionHistory: sessionHistorySnap.docs.map((doc) => doc.data()),
  };
}
