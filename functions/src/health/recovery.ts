import type { DocumentData, Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";

// Phase 4 — recovery reads (resting HR, HRV, sleep from Apple Health).
//
// The phone computes the summary and sends it with a coach message as
// liveContext.recovery. The coach trigger needs it on the message doc to
// build that one reply; after that it is deleted, so recovery numbers are
// never kept server-side (legal/privacy-policy.md §2). Best-effort and
// never throws: a failed delete must not fail the coach turn.
export async function forgetTurnRecovery(
  db: Firestore,
  messagePath: string,
  data: DocumentData | undefined,
): Promise<boolean> {
  const liveContext = data?.liveContext;
  if (!liveContext || typeof liveContext !== "object" || !("recovery" in liveContext)) return false;
  try {
    await db.doc(messagePath).update({ "liveContext.recovery": FieldValue.delete() });
    return true;
  } catch {
    return false;
  }
}
