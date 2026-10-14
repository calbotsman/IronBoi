import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { coachSessionMessagePath, coachSessionPath } from "../paths.js";

const GENERAL_SESSION_ID = "general";

/**
 * Writes a coach line into the app's one conversation ("general"), the same
 * way follow-ups/sweep.ts does, so the chat listener shows it and it stays in
 * history. Deterministic ids: a retried call overwrites, never duplicates.
 */
export async function writeGeneralCoachMessage(
  db: Firestore,
  userId: string,
  messageId: string,
  content: string,
  now: string,
) {
  const sessionRef = db.doc(coachSessionPath(userId, GENERAL_SESSION_ID));
  const sessionSnap = await sessionRef.get();
  if (!sessionSnap.exists) {
    await sessionRef.set({
      userId,
      sessionId: GENERAL_SESSION_ID,
      startedAt: now,
      outcome: "active",
      serverCreatedAt: FieldValue.serverTimestamp(),
    });
  }
  await db.doc(coachSessionMessagePath(userId, GENERAL_SESSION_ID, messageId)).set({
    messageId,
    role: "coach",
    content,
    timestamp: now,
    riskLevel: "low",
    toolCallIds: [],
    status: "complete",
    turnId: messageId,
    serverCreatedAt: FieldValue.serverTimestamp(),
    serverCompletedAt: FieldValue.serverTimestamp(),
  });
}
