import { createHash, randomUUID } from "node:crypto";
import type { Firestore } from "firebase-admin/firestore";
import type { AuditActor, AuditEventType } from "../contracts/coach-agent.js";
import { safeLogger } from "../logging/safeLogger.js";
import { auditLogPath } from "../paths.js";

// Phase 3 Task 3.4 — Audit logger.
//
// One record per sensitive event, written to users/{uid}/auditLog/{eventId}.
// The audit log is server-only write, owner read — the user can see their
// own change history (FTC HBNR transparency) but cannot mutate it.
//
// Design notes:
//   - Never store the raw payload. Store a 16-char sha256 prefix of
//     JSON(payload) so we can prove "two events refer to the same payload"
//     for forensics without leaking values into a log surface.
//   - eventId is a UUID — collision-free across users and time, useful
//     for correlating an event to a coach turn via turnId.
//   - `recordAuditEvent` THROWS on failure so callers can decide what to
//     do. Most existing call sites should use `recordAuditEventBestEffort`
//     which catches + logs the failure but does not break the user's
//     underlying operation. Use the throwing version only when the
//     audit record is a precondition (e.g. deletion: the tombstone /
//     audit must succeed before destructive ops run).

export type RecordAuditEventArgs = {
  userId: string;
  eventType: AuditEventType;
  actor: AuditActor;
  payload?: unknown;
  turnId?: string;
  correlationId?: string;
};

export async function recordAuditEvent(
  db: Firestore,
  args: RecordAuditEventArgs,
): Promise<{ eventId: string }> {
  const eventId = randomUUID();
  const event: Record<string, unknown> = {
    eventId,
    eventType: args.eventType,
    actor: args.actor,
    timestamp: new Date().toISOString(),
  };
  if (args.payload !== undefined) {
    event.payloadHash = hashPayload(args.payload);
  }
  if (args.turnId) event.turnId = args.turnId;
  if (args.correlationId) event.correlationId = args.correlationId;

  await db.doc(auditLogPath(args.userId, eventId)).set(event);
  return { eventId };
}

// Best-effort variant for hot paths: never throws. If the audit write
// fails, log the failure via safeLogger and return null. The caller's
// real operation (memory write, consent change, etc.) is unaffected.
export async function recordAuditEventBestEffort(
  db: Firestore,
  args: RecordAuditEventArgs,
): Promise<{ eventId: string } | null> {
  try {
    return await recordAuditEvent(db, args);
  } catch (error) {
    safeLogger.warn("Audit event write failed", {
      event: "audit_event_write_failed",
      userId: args.userId,
      outcome: args.eventType,
      errorDetail:
        error instanceof Error ? error.message.slice(0, 200) : "unknown",
    });
    return null;
  }
}

// 16 hex chars = 64 bits of collision resistance. Plenty for "did these two
// events share the same payload" forensics; not invertible.
function hashPayload(payload: unknown): string {
  const json = JSON.stringify(payload) ?? "";
  return createHash("sha256").update(json).digest("hex").slice(0, 16);
}
