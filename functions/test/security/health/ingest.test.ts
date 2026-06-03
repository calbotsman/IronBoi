import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import {
  FieldValue,
  getFirestore,
  type Firestore,
} from "firebase-admin/firestore";
import { ingestHealthSamples } from "../../../src/health/ingest.js";
import {
  consentRecordPath,
  healthSamplePath,
  userRoot,
} from "../../../src/paths.js";

const USER = "health-ingest-user";
const ISO = "2026-06-02T12:00:00.000Z";

let app: App;
let db: Firestore;

function consent(category: string, granted: boolean, extra: Record<string, unknown> = {}) {
  const base: Record<string, unknown> = {
    userId: USER,
    recordId: `c-${category}`,
    category,
    purpose: "wellness_coaching",
    granted,
    scope: { read: true, write: false, share: false, retrieval: true },
    policyVersion: "v1",
  };
  if (granted) base.grantedAt = ISO;
  return { ...base, ...extra };
}

function sample(category: string, sampleHash: string, value = 1) {
  return {
    category: category as never,
    value,
    unit: category === "steps" ? "count" : "kg",
    startDate: ISO,
    endDate: ISO,
    sampleHash,
  };
}

describe("ingestHealthSamples", () => {
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

  it("ingest_rejects_samples_without_consent", async () => {
    // No consent records exist for this user — every sample should be rejected.
    const result = await ingestHealthSamples(db, USER, {
      samples: [sample("steps", "hash-steps-1"), sample("body_weight_kg", "hash-bw-1", 80)],
    });

    expect(result.inserted).toBe(0);
    expect(result.duplicates).toBe(0);
    expect(result.rejectedNoConsent).toEqual(["hash-steps-1", "hash-bw-1"]);

    const samples = await db.collection(`${userRoot(USER)}/healthSamples`).get();
    expect(samples.size).toBe(0);
  });

  it("ingest_writes_only_samples_with_granted_consent", async () => {
    // Steps consent granted; body_weight not.
    await db.doc(consentRecordPath(USER, "c-healthkit_steps")).set(
      consent("healthkit_steps", true),
    );
    await db.doc(consentRecordPath(USER, "c-healthkit_body_weight")).set(
      consent("healthkit_body_weight", false),
    );

    const result = await ingestHealthSamples(db, USER, {
      samples: [
        sample("steps", "hash-steps-1"),
        sample("body_weight_kg", "hash-bw-1", 80),
      ],
    });

    expect(result.inserted).toBe(1);
    expect(result.duplicates).toBe(0);
    expect(result.rejectedNoConsent).toEqual(["hash-bw-1"]);

    const stepsDoc = await db.doc(healthSamplePath(USER, "hash-steps-1")).get();
    expect(stepsDoc.exists).toBe(true);
    expect(stepsDoc.data()?.userId).toBe(USER);
    expect(stepsDoc.data()?.category).toBe("steps");
    expect(stepsDoc.data()?.ingestedAt).toBeTypeOf("string");

    const bwDoc = await db.doc(healthSamplePath(USER, "hash-bw-1")).get();
    expect(bwDoc.exists).toBe(false);
  });

  it("ingest_dedupes_by_sampleHash_across_calls", async () => {
    await db.doc(consentRecordPath(USER, "c-healthkit_steps")).set(
      consent("healthkit_steps", true),
    );

    const first = await ingestHealthSamples(db, USER, {
      samples: [sample("steps", "hash-dup-1")],
    });
    expect(first.inserted).toBe(1);
    expect(first.duplicates).toBe(0);

    // Same sampleHash → should be a duplicate, no write.
    const second = await ingestHealthSamples(db, USER, {
      samples: [sample("steps", "hash-dup-1"), sample("steps", "hash-new-1")],
    });
    expect(second.inserted).toBe(1);
    expect(second.duplicates).toBe(1);
  });

  it("ingest_honors_revoked_consent", async () => {
    // Consent record exists but is revoked — must be treated as no-consent.
    await db.doc(consentRecordPath(USER, "c-healthkit_steps")).set(
      consent("healthkit_steps", true, { revokedAt: ISO }),
    );

    const result = await ingestHealthSamples(db, USER, {
      samples: [sample("steps", "hash-revoked-1")],
    });

    expect(result.inserted).toBe(0);
    expect(result.rejectedNoConsent).toEqual(["hash-revoked-1"]);
  });

  it("ingest_handles_empty_after_consent_filter_without_writing", async () => {
    // Make sure we don't call batch.commit() with zero writes.
    const result = await ingestHealthSamples(db, USER, {
      samples: [sample("steps", "h-1"), sample("hrv_ms", "h-2")],
    });
    expect(result.inserted).toBe(0);
    expect(result.duplicates).toBe(0);
    expect(result.rejectedNoConsent.length).toBe(2);
  });
});
