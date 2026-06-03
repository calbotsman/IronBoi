// Phase 2 Task 2.1 — single source of truth for user-scoped data layout.
//
// This module names every collection under `users/{uid}/...` and declares:
//   - read tier (who can read it)
//   - write tier (who can write it, and which fields are allowed)
//   - the Zod schema for client_owner writes
//   - whether the collection feeds the coach context bundle
//
// Why this exists:
//   Before, the relationship between contract Zod schemas, the actual
//   Firestore rules, and the callable handler validation was implicit. Three
//   places to look, three places to drift. This module pins them together so
//   a drift test can fail loudly if any one moves without the others.
//
// Phase 2 Task 2.2 uses `clientOwnerWriteKeys(...)` to derive the
// `request.resource.data.keys().hasOnly([...])` allowlist enforced by
// firestore.rules. The list of keys is whatever the Zod schema declares —
// adding/removing a field in contracts/ ripples here automatically.

import type { ZodObject, ZodRawShape } from "zod";
import {
  ConsentRecord,
  DailyCheck,
  MetricSnapshot,
  WorkoutLog,
  WorkoutPlan,
} from "../contracts/coach-agent.js";

export type ReadTier =
  // Owner is the only one who can read documents at this path.
  | "owner"
  // Any signed-in user can read; used for shared resources like /corpus.
  | "signed_in";

export type WriteTier =
  // Owner can create/update; client write goes through Firestore rules
  // plus runtime Zod parsing in the callable handler. Allowed keys come
  // from the runtimeSchema.
  | { kind: "client_owner"; runtimeSchema: ZodObject<ZodRawShape> }
  // No client writes — only Firebase Functions (admin SDK) can write.
  | { kind: "server_only" }
  // Owner can update only the listed keys (used for accept/reject flows
  // on server-created proposal docs).
  | { kind: "owner_decision"; allowedKeys: readonly string[] };

export type ContextRole =
  // Feeds the coach context bundle directly.
  | "primary"
  // Used by other systems but not surfaced to the coach.
  | "internal";

export type UserScopedCollection = {
  // Path pattern with {uid} placeholder and document-id placeholders.
  pathPattern: string;
  read: ReadTier;
  write: WriteTier;
  contextRole: ContextRole;
};

// The actual table. Every collection under users/{uid}/... goes here. Adding
// a new collection requires adding an entry; drift tests will fail loudly
// otherwise.
export const USER_SCOPED = {
  profile: {
    pathPattern: "users/{uid}/profile/current",
    read: "owner",
    write: { kind: "server_only" },
    contextRole: "primary",
  },
  memoryFacts: {
    pathPattern: "users/{uid}/memoryFacts/{factId}",
    read: "owner",
    write: { kind: "server_only" },
    contextRole: "primary",
  },
  workoutLogs: {
    pathPattern: "users/{uid}/workoutLogs/{logId}",
    read: "owner",
    write: { kind: "client_owner", runtimeSchema: WorkoutLog },
    contextRole: "primary",
  },
  workoutPlans: {
    pathPattern: "users/{uid}/workoutPlans/{planId}",
    read: "owner",
    write: { kind: "client_owner", runtimeSchema: WorkoutPlan },
    contextRole: "internal",
  },
  dailyChecks: {
    pathPattern: "users/{uid}/dailyChecks/{date}",
    read: "owner",
    write: { kind: "client_owner", runtimeSchema: DailyCheck },
    contextRole: "internal",
  },
  activeWorkout: {
    pathPattern: "users/{uid}/activeWorkout/{docId}",
    read: "owner",
    write: { kind: "server_only" },
    contextRole: "internal",
  },
  workoutSessions: {
    pathPattern: "users/{uid}/workoutSessions/{sessionId}",
    read: "owner",
    write: { kind: "server_only" },
    contextRole: "internal",
  },
  metricSnapshots: {
    pathPattern: "users/{uid}/metricSnapshots/{snapshotId}",
    read: "owner",
    write: { kind: "client_owner", runtimeSchema: MetricSnapshot },
    contextRole: "internal",
  },
  // Phase 2 Task 2.4 — raw HealthKit samples. Server-only write because
  // the ingestion path enforces consent gating, dedupe via sampleHash as
  // doc ID, and provenance fields. iOS calls ingestHealthSamples instead
  // of writing directly.
  healthSamples: {
    pathPattern: "users/{uid}/healthSamples/{sampleHash}",
    read: "owner",
    write: { kind: "server_only" },
    contextRole: "primary",
  },
  // Phase 2 Task 2.4 — daily rollups. Doc id is "healthContext_{date}".
  // Rebuilt by a follow-up rollup function from the raw samples.
  derivedSummaries: {
    pathPattern: "users/{uid}/derivedSummaries/{summaryId}",
    read: "owner",
    write: { kind: "server_only" },
    contextRole: "primary",
  },
  // Phase 3 Task 3.4 — audit log. Owner reads, server writes only.
  // Records sensitive events (memory writes, consent changes, health
  // ingestion, spend cap hits) for FTC HBNR / CCPA transparency.
  auditLog: {
    pathPattern: "users/{uid}/auditLog/{eventId}",
    read: "owner",
    write: { kind: "server_only" },
    contextRole: "internal",
  },
  consentRecords: {
    pathPattern: "users/{uid}/consentRecords/{recordId}",
    read: "owner",
    write: { kind: "client_owner", runtimeSchema: ConsentRecord },
    contextRole: "internal",
  },
  usage: {
    pathPattern: "users/{uid}/usage/{date}",
    read: "owner",
    write: { kind: "server_only" },
    contextRole: "internal",
  },
  coachSessions: {
    pathPattern: "users/{uid}/coachSessions/{sessionId}",
    read: "owner",
    write: { kind: "server_only" },
    contextRole: "internal",
  },
  // Coach messages have their own bespoke shape rule in firestore.rules
  // (validUserCoachMessage) — that predates this module and is treated as
  // grandfathered. Listed here for completeness; rules generation skips it.
  coachMessages: {
    pathPattern:
      "users/{uid}/coachSessions/{sessionId}/messages/{messageId}",
    read: "owner",
    write: { kind: "server_only" },
    contextRole: "internal",
  },
  programProposals: {
    pathPattern: "users/{uid}/programProposals/{proposalId}",
    read: "owner",
    write: {
      kind: "owner_decision",
      allowedKeys: ["decision", "decidedAt"] as const,
    },
    contextRole: "internal",
  },
  planAdjustmentProposals: {
    pathPattern: "users/{uid}/planAdjustmentProposals/{proposalId}",
    read: "owner",
    write: {
      kind: "owner_decision",
      allowedKeys: ["decision", "decidedAt"] as const,
    },
    contextRole: "internal",
  },
} as const satisfies Record<string, UserScopedCollection>;

export type UserScopedCollectionKey = keyof typeof USER_SCOPED;

// Helper: for a client_owner collection, return the keys that the schema
// declares — exactly the set firestore.rules should allow via hasOnly().
//
// This is the integration point between the Zod schemas in contracts/ and
// the field-allowlist enforced by Firestore rules. Drift between them is
// what Phase 2.2's drift test exists to catch.
export function clientOwnerWriteKeys(
  key: UserScopedCollectionKey,
): readonly string[] {
  const collection = USER_SCOPED[key];
  if (collection.write.kind !== "client_owner") {
    throw new Error(
      `clientOwnerWriteKeys called on non-client-owner collection "${key}"`,
    );
  }
  // Zod 4 stores the field map on `.shape`. Object.keys gives us the
  // declared field names in source order.
  return Object.keys(collection.write.runtimeSchema.shape);
}

export function listClientWritableCollections(): UserScopedCollectionKey[] {
  return (Object.keys(USER_SCOPED) as UserScopedCollectionKey[]).filter(
    (key) => USER_SCOPED[key].write.kind === "client_owner",
  );
}
