// MYO progress layer — storage side of the pure builder (progress/build.ts).
//
// writeProgressSummary loads the builder's inputs (last-42-day workoutLogs,
// body-weight healthSamples + manual metricSnapshots, the plan/program, the
// profile), runs the pure builder, and overwrites
// users/{uid}/derivedSummaries/progress_current. Server-only write —
// derivedSummaries is registered server_only in access/userScopedSchema.ts
// and firestore.rules denies client writes.
//
// recomputeProgressSummaryIfStale is the debounced wrapper the workoutLog
// trigger (index.ts onWorkoutLogCreated) calls: at most one recompute per
// hour per user, keyed off the doc's own computedAt. Extracted from the
// trigger wrapper so the emulator suite can exercise the debounce directly
// (same pattern as followups/sweep.ts).

import type { DocumentData, Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import type { ProgressSummary } from "../contracts/coach-agent.js";
import { safeLogger } from "../logging/safeLogger.js";
import {
  profilePath,
  progressSummaryPath,
  trainingProgramPath,
  userRoot,
  workoutPlanPath,
} from "../paths.js";
import { PROGRESS_WINDOW_DAYS, buildProgressSummary } from "./build.js";

// Debounce window for trigger-driven recomputes. A finished session is the
// natural heartbeat; a user logging three sessions in a burst still only
// costs one rebuild an hour.
export const PROGRESS_RECOMPUTE_MIN_INTERVAL_MS = 60 * 60 * 1_000;

// Generous read caps — 42 days of data for one user sits far below these;
// they exist so a pathological account can't make the rebuild unbounded.
const MAX_LOGS = 300;
const MAX_WEIGHT_SAMPLES = 500;
const MAX_METRIC_SNAPSHOTS = 200;

export async function writeProgressSummary(
  db: Firestore,
  userId: string,
  todayISO = new Date().toISOString(),
): Promise<ProgressSummary> {
  const windowStartDate = isoDateDaysBefore(todayISO, PROGRESS_WINDOW_DAYS - 1);
  const windowStartISO = `${windowStartDate}T00:00:00.000Z`;

  // The body_weight_kg read needs a composite index (category asc,
  // startDate asc — declared in firestore.indexes.json). Weight is advisory
  // context, never load-bearing, so it degrades to [] rather than turning an
  // index-still-building window into a failed rebuild — same posture as the
  // plan-change read in coach/context.ts. The metricSnapshots read is a
  // single-field range but gets the same tolerance for symmetry.
  const weightSamplesPromise = db
    .collection(`${userRoot(userId)}/healthSamples`)
    .where("category", "==", "body_weight_kg")
    .where("startDate", ">=", windowStartISO)
    .orderBy("startDate", "asc")
    .limit(MAX_WEIGHT_SAMPLES)
    .get()
    .then((snap) => snap.docs.map((doc) => doc.data()))
    .catch((error: unknown) => {
      logDegradedRead(userId, "health_samples", error);
      return [] as DocumentData[];
    });

  const metricSnapshotsPromise = db
    .collection(`${userRoot(userId)}/metricSnapshots`)
    .where("capturedAt", ">=", windowStartISO)
    .orderBy("capturedAt", "asc")
    .limit(MAX_METRIC_SNAPSHOTS)
    .get()
    .then((snap) => snap.docs.map((doc) => doc.data()))
    .catch((error: unknown) => {
      logDegradedRead(userId, "metric_snapshots", error);
      return [] as DocumentData[];
    });

  const [logsSnap, weightSamples, metricSnapshots, programSnap, planSnap, profileSnap] =
    await Promise.all([
      db
        .collection(`${userRoot(userId)}/workoutLogs`)
        .where("date", ">=", windowStartDate)
        .orderBy("date", "asc")
        .limit(MAX_LOGS)
        .get(),
      weightSamplesPromise,
      metricSnapshotsPromise,
      db.doc(trainingProgramPath(userId)).get(),
      db.doc(workoutPlanPath(userId)).get(),
      db.doc(profilePath(userId)).get(),
    ]);

  const summary = buildProgressSummary({
    logs: logsSnap.docs.map((doc) => doc.data()),
    healthSamples: [
      ...weightSamples,
      ...manualWeightEntries(metricSnapshots),
    ],
    program: programSnap.exists ? programSnap.data() ?? null : null,
    plan: planSnap.exists ? planSnap.data() ?? null : null,
    profile: profileSnap.exists ? profileSnap.data() ?? null : null,
    userId,
    todayISO,
  });

  // Full overwrite, NOT merge: the doc is entirely derived, and merging
  // would both resurrect stale branches and walk into the
  // set(merge)+empty-map deletion gotcha for no benefit.
  await db.doc(progressSummaryPath(userId)).set({
    ...summary,
    serverUpdatedAt: FieldValue.serverTimestamp(),
  });

  return summary;
}

export type RecomputeProgressResult =
  | { recomputed: false; reason: "fresh" }
  | { recomputed: true; summary: ProgressSummary };

export async function recomputeProgressSummaryIfStale(
  db: Firestore,
  userId: string,
  todayISO = new Date().toISOString(),
): Promise<RecomputeProgressResult> {
  const snap = await db.doc(progressSummaryPath(userId)).get();
  const computedAt = snap.exists ? snap.data()?.computedAt : undefined;
  if (typeof computedAt === "string") {
    const ageMs = Date.parse(todayISO) - Date.parse(computedAt);
    // A doc "from the future" (clock skew, fixture) counts as fresh too —
    // never let bad timestamps cause a rebuild storm.
    if (Number.isFinite(ageMs) && ageMs < PROGRESS_RECOMPUTE_MIN_INTERVAL_MS) {
      return { recomputed: false, reason: "fresh" };
    }
  }
  const summary = await writeProgressSummary(db, userId, todayISO);
  return { recomputed: true, summary };
}

// Manual weigh-ins typed into the app land as metricSnapshots (source
// "manual", metrics.bodyWeightKg). Normalize them into the same shape the
// builder reads for HealthKit samples so it sees one weight stream.
// HealthKit-sourced snapshots are skipped — those days already flow in at
// sample granularity via healthSamples, and double-counting would bias the
// daily average toward the lossier legacy pathway.
function manualWeightEntries(snapshots: DocumentData[]): DocumentData[] {
  const entries: DocumentData[] = [];
  for (const snapshot of snapshots) {
    if (snapshot?.source !== "manual") continue;
    const metrics = snapshot.metrics;
    const kg =
      metrics && typeof metrics === "object" && !Array.isArray(metrics)
        ? (metrics as Record<string, unknown>).bodyWeightKg
        : undefined;
    if (typeof kg !== "number" || !Number.isFinite(kg) || kg <= 0) continue;
    if (typeof snapshot.capturedAt !== "string") continue;
    entries.push({
      category: "body_weight_kg",
      value: kg,
      startDate: snapshot.capturedAt,
    });
  }
  return entries;
}

function logDegradedRead(userId: string, source: string, error: unknown) {
  safeLogger.warn("Progress summary input read degraded to empty", {
    event: "progress_input_read_degraded",
    userId,
    outcome: source,
    errorCode: error instanceof Error ? error.name : "unknown_error",
    errorDetail: error instanceof Error ? error.message.slice(0, 180) : "unknown_error",
  });
}

function isoDateDaysBefore(todayISO: string, days: number): string {
  const ms = Date.parse(todayISO);
  if (!Number.isFinite(ms)) {
    throw new Error(`writeProgressSummary: unparseable todayISO "${todayISO}"`);
  }
  return new Date(ms - days * 86_400_000).toISOString().slice(0, 10);
}
