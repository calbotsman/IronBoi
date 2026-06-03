import type { Firestore } from "firebase-admin/firestore";
import {
  type HealthSampleCategory,
  type IngestHealthSampleInput,
  type IngestHealthSamplesResult,
} from "../contracts/coach-agent.js";
import { healthSamplePath, userRoot } from "../paths.js";

// Phase 2 Task 2.4 — HealthKit ingestion.
//
// Server-side dedupe (sampleHash = document ID, idempotent writes), per-
// sample consent gating (a consent record must exist for the relevant
// DataCategory with granted === true), batch insert (1 write per new
// sample, no writes for duplicates).
//
// Does NOT build derived summaries — that's a follow-up. Ingesting raw
// samples is the lossy-fix; rolling them up daily can land later.

// HealthSample category → consentRecords.category mapping. The DataCategory
// enum in contracts/coach-agent.ts is canonical; this map binds each
// sample type to the consent it requires.
const CONSENT_CATEGORY: Record<HealthSampleCategory, string> = {
  steps: "healthkit_steps",
  active_energy_kcal: "healthkit_active_energy",
  resting_heart_rate_bpm: "healthkit_resting_heart_rate",
  sleep_duration_min: "healthkit_sleep",
  body_weight_kg: "healthkit_body_weight",
  hrv_ms: "healthkit_hrv",
  workout: "healthkit_workouts",
};

async function loadGrantedConsentCategories(
  db: Firestore,
  userId: string,
): Promise<Set<string>> {
  const snap = await db
    .collection(`${userRoot(userId)}/consentRecords`)
    .get();
  const granted = new Set<string>();
  for (const docSnap of snap.docs) {
    const data = docSnap.data();
    if (typeof data.category === "string" && data.granted === true) {
      // Honor revocation: a record with revokedAt set is NOT live consent.
      if (!data.revokedAt) {
        granted.add(data.category);
      }
    }
  }
  return granted;
}

export type IngestHealthSamplesArgs = {
  samples: IngestHealthSampleInput[];
  now?: Date;
};

export async function ingestHealthSamples(
  db: Firestore,
  userId: string,
  args: IngestHealthSamplesArgs,
): Promise<IngestHealthSamplesResult> {
  const grantedConsent = await loadGrantedConsentCategories(db, userId);
  const now = (args.now ?? new Date()).toISOString();

  // First pass: filter by consent. Anything without live consent gets
  // dropped with the sampleHash recorded in the response so the client can
  // surface "this many samples need consent."
  const accepted: IngestHealthSampleInput[] = [];
  const rejectedNoConsent: string[] = [];
  for (const sample of args.samples) {
    const requiredCategory = CONSENT_CATEGORY[sample.category];
    if (!grantedConsent.has(requiredCategory)) {
      rejectedNoConsent.push(sample.sampleHash);
      continue;
    }
    accepted.push(sample);
  }

  if (accepted.length === 0) {
    return { inserted: 0, duplicates: 0, rejectedNoConsent };
  }

  // Batched existence check via getAll — one round-trip for up to 500 docs
  // (Firestore batched get limit). Cheaper than 500 individual reads.
  const refs = accepted.map((sample) =>
    db.doc(healthSamplePath(userId, sample.sampleHash)),
  );
  const existing = await db.getAll(...refs);

  let inserted = 0;
  let duplicates = 0;
  const batch = db.batch();
  for (let i = 0; i < accepted.length; i++) {
    if (existing[i].exists) {
      duplicates++;
      continue;
    }
    batch.set(refs[i], {
      ...accepted[i],
      userId,
      ingestedAt: now,
    });
    inserted++;
  }

  if (inserted > 0) {
    await batch.commit();
  }

  return { inserted, duplicates, rejectedNoConsent };
}
