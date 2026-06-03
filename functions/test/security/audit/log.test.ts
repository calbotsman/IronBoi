import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import {
  recordAuditEvent,
  recordAuditEventBestEffort,
} from "../../../src/audit/log.js";
import { auditLogPath, userRoot } from "../../../src/paths.js";

const USER = "audit-log-user";

let app: App;
let db: Firestore;

describe("recordAuditEvent", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });

  beforeEach(async () => {
    await db.recursiveDelete(db.doc(`users/${USER}`));
  });

  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  it("audit_event_lands_at_expected_path_with_required_fields", async () => {
    const result = await recordAuditEvent(db, {
      userId: USER,
      eventType: "memory_fact_written",
      actor: "coach",
    });

    expect(result.eventId).toBeTypeOf("string");
    const doc = await db.doc(auditLogPath(USER, result.eventId)).get();
    expect(doc.exists).toBe(true);
    expect(doc.data()).toMatchObject({
      eventId: result.eventId,
      eventType: "memory_fact_written",
      actor: "coach",
    });
    expect(doc.data()?.timestamp).toBeTypeOf("string");
  });

  it("audit_event_hashes_payload_never_stores_raw", async () => {
    const sensitivePayload = {
      content: "User is in active eating disorder treatment",
      category: "safety_note",
    };
    const result = await recordAuditEvent(db, {
      userId: USER,
      eventType: "memory_fact_written",
      actor: "coach",
      payload: sensitivePayload,
    });

    const doc = await db.doc(auditLogPath(USER, result.eventId)).get();
    const data = doc.data();

    expect(data?.payloadHash).toBeTypeOf("string");
    expect(data?.payloadHash.length).toBe(16);
    // The raw payload's keys/values must NOT appear anywhere in the doc.
    const serialized = JSON.stringify(data);
    expect(serialized).not.toContain("active eating disorder");
    expect(serialized).not.toContain("content");
    expect(serialized).not.toContain("safety_note");
  });

  it("audit_event_hash_is_stable_for_identical_payloads", async () => {
    const payload = { recordId: "r-1", category: "healthkit_steps" };
    const a = await recordAuditEvent(db, {
      userId: USER,
      eventType: "consent_granted",
      actor: "user",
      payload,
    });
    const b = await recordAuditEvent(db, {
      userId: USER,
      eventType: "consent_granted",
      actor: "user",
      payload,
    });

    const docA = await db.doc(auditLogPath(USER, a.eventId)).get();
    const docB = await db.doc(auditLogPath(USER, b.eventId)).get();
    expect(docA.data()?.payloadHash).toBe(docB.data()?.payloadHash);
    // But eventIds are different — they're distinct events.
    expect(a.eventId).not.toBe(b.eventId);
  });

  it("audit_event_includes_turnId_and_correlationId_when_provided", async () => {
    const result = await recordAuditEvent(db, {
      userId: USER,
      eventType: "daily_spend_cap_reached",
      actor: "system",
      turnId: "turn-abc",
      correlationId: "corr-xyz",
    });
    const doc = await db.doc(auditLogPath(USER, result.eventId)).get();
    expect(doc.data()).toMatchObject({
      turnId: "turn-abc",
      correlationId: "corr-xyz",
    });
  });

  it("audit_event_omits_turnId_and_correlationId_when_not_provided", async () => {
    const result = await recordAuditEvent(db, {
      userId: USER,
      eventType: "memory_fact_deleted",
      actor: "user",
    });
    const doc = await db.doc(auditLogPath(USER, result.eventId)).get();
    const data = doc.data() ?? {};
    expect(data.turnId).toBeUndefined();
    expect(data.correlationId).toBeUndefined();
    expect(data.payloadHash).toBeUndefined();
  });
});

describe("recordAuditEventBestEffort", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });

  beforeEach(async () => {
    await db.recursiveDelete(db.doc(`users/${USER}`));
  });

  it("audit_best_effort_returns_eventId_on_success", async () => {
    const result = await recordAuditEventBestEffort(db, {
      userId: USER,
      eventType: "consent_revoked",
      actor: "user",
      payload: { recordId: "r-1" },
    });
    expect(result).not.toBeNull();
    expect(result?.eventId).toBeTypeOf("string");
    const snap = await db.collection(`${userRoot(USER)}/auditLog`).get();
    expect(snap.size).toBe(1);
  });

  it("audit_best_effort_returns_null_on_failure_does_not_throw", async () => {
    // Force a failure by giving an empty userId — auditLogPath produces
    // `users//auditLog/...` which Firestore rejects.
    const result = await recordAuditEventBestEffort(db, {
      userId: "",
      eventType: "consent_revoked",
      actor: "user",
    });
    expect(result).toBeNull();
  });
});
