import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { coachSessionMessagePath, coachSessionPath } from "../paths.js";
import { safeLogger } from "../logging/safeLogger.js";

// Recovery-arc delivery: injury adjustments schedule a coachFollowUps doc on
// accept; this sweep turns due ones into a coach check-in message ("been a
// few days — feeling better? want to ramp back up?"). The message lands in
// the app's single fixed session ("general"), so the existing chat listener
// surfaces it the next time the user opens the Coach tab. The user's natural
// reply flows through the normal tool loop, where the coach proposes the
// ramp-up (clear_plan_overrides / adapt_plan).
//
// Extracted from the onSchedule wrapper so the emulator suite can exercise
// it directly.
export async function sweepCoachFollowUps(db: Firestore, nowISO?: string) {
  const now = nowISO ?? new Date().toISOString();
  const due = await db
    .collectionGroup("coachFollowUps")
    .where("status", "==", "scheduled")
    .where("dueAt", "<=", now)
    .limit(200)
    .get();

  let sent = 0;
  let failed = 0;
  for (const doc of due.docs) {
    try {
    const data = doc.data();
    const userId = typeof data.userId === "string" ? data.userId : "";
    if (!userId) {
      await doc.ref.set(
        { status: "cancelled", serverUpdatedAt: FieldValue.serverTimestamp() },
        { merge: true },
      );
      continue;
    }
    const sessionId = "general";
    // Deterministic message id — a retried sweep overwrites, not duplicates.
    const messageId = `followup_${doc.id}`;
    const context =
      typeof data.context === "string" && data.context.length > 0
        ? data.context
        : "we eased your training off a few days ago.";
    const sessionRef = db.doc(coachSessionPath(userId, sessionId));
    const sessionSnap = await sessionRef.get();
    if (!sessionSnap.exists) {
      await sessionRef.set({
        userId,
        sessionId,
        startedAt: now,
        outcome: "active",
        serverCreatedAt: FieldValue.serverTimestamp(),
      });
    }
    await db.doc(coachSessionMessagePath(userId, sessionId, messageId)).set({
      messageId,
      role: "coach",
      content: `Checking in — ${context} How is it feeling now? If you're pain-free, say the word and I'll bring your plan back up to full strength. If it still hurts, tell me and we'll keep it easy (or get it looked at).`,
      timestamp: now,
      riskLevel: "low",
      toolCallIds: [],
      status: "complete",
      turnId: `followup_${doc.id}`,
      serverCreatedAt: FieldValue.serverTimestamp(),
      serverCompletedAt: FieldValue.serverTimestamp(),
    });
    await doc.ref.set(
      { status: "sent", sentAt: now, serverUpdatedAt: FieldValue.serverTimestamp() },
      { merge: true },
    );
    sent += 1;
    } catch (error) {
      // One bad doc must not starve every other user's check-in. Retry up
      // to 3 sweeps, then park it as `failed` so a deterministic poison doc
      // can't jam the head of the dueAt-ordered queue forever.
      failed += 1;
      safeLogger.warn("Coach follow-up delivery failed", {
        event: "coach_followup_delivery_failed",
        followUpId: doc.id,
        errorDetail: error instanceof Error ? error.message.slice(0, 200) : "unknown_error",
      });
      try {
        const attempts = (typeof doc.data().deliveryAttempts === "number" ? doc.data().deliveryAttempts : 0) + 1;
        await doc.ref.set(
          {
            deliveryAttempts: attempts,
            ...(attempts >= 3 ? { status: "failed" } : {}),
            serverUpdatedAt: FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      } catch {
        // Best-effort bookkeeping; the outer log already recorded the failure.
      }
    }
  }

  safeLogger.info("Coach follow-ups swept", {
    event: "coach_followups_swept",
    outcome: `sent_${sent}_failed_${failed}_of_${due.size}`,
  });
  return { sent, failed, due: due.size };
}
