import { createRequire } from "node:module";
import { randomUUID } from "node:crypto";
import type { CollectionReference, DocumentReference } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { defineSecret } from "firebase-functions/params";
import { SynthesizeSpeechRequest, synthesizeSpeech, ttsAllowedForSignInProvider } from "./voice/speech.js";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { z } from "zod";
import { db } from "./firebase.js";
import { orchestrateCoachTurn } from "./coach/orchestrate.js";
import {
  IosCoachMessageRequest,
  handleSendCoachMessage,
  isRecord,
} from "./coach/sendMessage.js";
import { sweepCoachFollowUps } from "./followups/sweep.js";
import { recomputeProgressSummaryIfStale } from "./progress/store.js";
import type { CoachConfig } from "./coach/prompt.js";
import {
  CoachMemoryFact,
  CoachTips,
  CoachTone,
  ConsentRecord,
  DailyCheck,
  IngestHealthSamplesRequest,
  UserHealthProfile,
  WorkoutLog,
  WorkoutPlan,
} from "./contracts/coach-agent.js";
import { ingestHealthSamples as ingestHealthKitSamples } from "./health/ingest.js";
import {
  recordAuditEvent,
  recordAuditEventBestEffort,
} from "./audit/log.js";
import { getAuth } from "firebase-admin/auth";
import {
  coachSessionPath,
  consentRecordPath,
  dailyCheckPath,
  deletedAccountPath,
  memoryFactPath,
  profilePath,
  userRoot,
  workoutPlanPath,
  workoutLogPath,
} from "./paths.js";
import {
  FinishWorkoutSessionRequest,
  AbandonWorkoutSessionRequest,
  abandonWorkoutSession,
  StartWorkoutSessionRequest,
  finishWorkoutSession,
  startWorkoutSession,
} from "./workouts/activeWorkout.js";
import {
  AcceptPlanAdjustmentProposalRequest,
  acceptPlanAdjustmentProposal as acceptPlanAdjustmentProposalCore,
  expireStalePendingProposals,
} from "./workouts/planAdjustments.js";
import {
  GetExerciseSwapOptionsRequest,
  SwapExerciseRequest,
  getExerciseSwapOptions,
  swapExercise,
} from "./workouts/exerciseSwap.js";
import { ApplyExerciseBaselinesRequest } from "./workouts/exerciseBaselines.js";
import { applyExerciseBaselines } from "./workouts/rebaseline.js";
import { writeRegeneratedPlanAndProgram } from "./workouts/program.js";
import { rolloverTrainingPrograms } from "./workouts/rollover.js";
import { safeLogger } from "./logging/safeLogger.js";
import { checkDailyTtsCap, recordTtsUsage } from "./usage/cap.js";

// Phase 3 Task 3.2 — App Check enforcement (env-gated).
//
// Enforcement is driven by IRONBOI_ENFORCE_APP_CHECK and defaults OFF.
// It was disabled because a Debug build whose debug token wasn't
// registered had every callable — including profile save — rejected with
// app:INVALID while auth was VALID. Auth still protects every function.
// See docs/audits/myo-engineering-qa-2026-06-23.md.
//
// TO FLIP IT ON (console prerequisites first — full steps in
// docs/operations/appcheck-enable-runbook.md):
//   1. Register the iOS app for App Attest in Firebase Console → App Check,
//      and register developer debug tokens.
//   2. Add IRONBOI_ENFORCE_APP_CHECK=true to functions/.env.<project>.
//   3. Run a FULL `firebase deploy --only functions --project <project>`.
// Never flip it per-service with `gcloud run services update` — one flag
// gates every callable across all services; flipping one creates a
// split-brain, and the next firebase deploy silently clobbers gcloud-set
// env anyway (same rule as IRONBOI_COACH_TOOL_LOOP_ENABLED).
//
// When enforced, every callable REQUIRES a valid App Check token: iOS vends
// them via AppAttestProvider (Release) or AppCheckDebugProvider (Debug) and
// the Firebase SDK ships them automatically. consumeAppCheckToken makes each
// token one-shot (no replay).
//
// The onCall surface is the ONLY surface: the bearer-token *Http twins
// that the iOS app used before the callable migration (and that never
// verified App Check) were retired on 2026-10-07, so flipping this flag
// protects all real traffic. Before flipping it, confirm in the logs that
// app_check_presence reports outcome:present from a current build — as of
// 2026-10-07 build 34 the tokens it sends fail to decode (App Attest is
// not yet registered in the console), and enforcement would reject every
// call.
export function callableOpts(env: NodeJS.ProcessEnv = process.env) {
  const enforced = env.IRONBOI_ENFORCE_APP_CHECK === "true";
  // Consumption is a SEPARATE opt-in: one-shot tokens + the iOS SDK's
  // cached-token reuse means high-frequency callable traffic (which the
  // client migration makes the norm) would replay-reject every call after
  // the first within a token lifetime. Only enable after the client adopts
  // limited-use tokens (HTTPSCallableOptions(requireLimitedUseAppCheckTokens))
  // — see docs/operations/appcheck-enable-runbook.md.
  const consume = env.IRONBOI_CONSUME_APP_CHECK === "true";
  return {
    region: "us-central1",
    enforceAppCheck: enforced,
    consumeAppCheckToken: enforced && consume,
  } as const;
}

export const CALLABLE_OPTS = callableOpts();
import {
  AcceptProgramProposalRequest,
  OnboardingAnswerRequest,
  acceptProgramProposal as acceptProgramProposalCore,
  buildWorkoutPlanFromProfile,
  processOnboardingAnswer,
} from "./onboarding/flow.js";

const require = createRequire(import.meta.url);

// Cast at the JSON boundary — validate-phase0 enforces the JSON conforms
// to CoachAgentContract at build time, so we trust the shape downstream
// and carry a real type through. Avoids `as never` later.
const coach = require("./coach/ironboi-coach.v0.json") as CoachConfig;
const seed = require("./domain/ironlab-seed.json");
const geminiApiKey = defineSecret("GEMINI_API_KEY");
const openRouterApiKey = defineSecret("OPENROUTER_API_KEY");

// A malformed payload must surface as invalid-argument (not opaque
// INTERNAL) and leave an operator log breadcrumb (issue paths, never
// values).
function parseCallablePayload<T>(schema: { parse(input: unknown): T }, data: unknown, endpoint: string): T {
  try {
    return schema.parse(data ?? {});
  } catch (error) {
    if (error instanceof z.ZodError) {
      safeLogger.warn("Callable rejected invalid request", {
        event: "callable_invalid_request",
        errorCode: endpoint,
        errorDetail: error.issues
          .slice(0, 5)
          .map((issue) => `${issue.path.join(".")}:${issue.code}`)
          .join(","),
      });
      throw new HttpsError("invalid-argument", "invalid_request");
    }
    throw error;
  }
}

// Pre-enforcement telemetry for the App Check flip
// (docs/operations/appcheck-enable-runbook.md). With enforcement off, a
// missing token costs nothing — so nothing tells us whether the app's
// Release builds are actually minting valid App Attest tokens. This logs
// what enforcement WOULD have seen on a few high-traffic callables; flip
// IRONBOI_ENFORCE_APP_CHECK only after real device traffic shows
// outcome:present here. Deliberately not on every callable — three
// endpoints the app hits constantly is signal enough, and `request.app`
// is only populated for VALID tokens, which is exactly the question.
function logAppCheckPresence(endpoint: string, hasApp: boolean, userId: string) {
  safeLogger.info("App Check token presence", {
    event: "app_check_presence",
    userId,
    errorCode: endpoint,
    outcome: hasApp ? "present" : "absent",
  });
}

function requireUserId(auth?: { uid?: string }) {
  if (!auth?.uid) {
    throw new HttpsError("unauthenticated", "Sign in is required.");
  }
  return auth.uid;
}

function stripUserId<T extends Record<string, unknown>>(value: T, userId: string) {
  return { ...value, userId };
}

function requireAdmin(auth?: { token?: Record<string, unknown>; uid?: string }) {
  requireUserId(auth);
  if (auth?.token?.admin !== true) {
    throw new HttpsError("permission-denied", "Admin access is required.");
  }
}

// maybeApplyWorkoutPlanAdjustment and the shared coach-message handler
// live in ./coach/sendMessage.ts so the logic is unit-testable in the
// emulator suite.

async function deleteDocumentTree(ref: DocumentReference, keep: ReadonlySet<string> = new Set()) {
  const collections = await ref.listCollections();
  await Promise.all(collections.filter((c) => !keep.has(c.id)).map(deleteCollectionTree));
  if (keep.size === 0) await ref.delete();
}

// "Start over" must not reset the day's spend counters: with usage/ inside
// users/{uid}/**, a plain wipe let any account zero its message, token and
// spoken-character caps between bursts. deleteAccount still removes
// everything (the account is gone; the caps die with it).
const RESET_KEEPS: ReadonlySet<string> = new Set(["usage"]);

async function deleteCollectionTree(collection: CollectionReference) {
  const snapshot = await collection.get();
  for (const doc of snapshot.docs) {
    await deleteDocumentTree(doc.ref);
  }
}

// Regenerate the user's workoutPlans/current doc from their CURRENT
// profile and the seed default plan. Useful when:
//   - The plan-generation rules change (e.g. the M/W/F vs Mon-Wed
//     distribution fix in commit 449862b — existing plans don't get
//     rewritten automatically)
//   - The user updates preferences on the You tab and wants the plan
//     to reflect them without re-running the chat-based onboarding
//
// Overwrites the existing plan doc. The iOS UI puts a confirm step in
// front of this — the callable itself doesn't second-guess.
// Throws HttpsError("failed-precondition") when the profile is missing.
export async function handleRegenerateWorkoutPlan(userId: string) {
  const profileSnap = await db.doc(profilePath(userId)).get();
  if (!profileSnap.exists) {
    throw new HttpsError("failed-precondition", "profile_not_found");
  }
  const profileData = profileSnap.data() ?? {};
  // We only need schedule.daysPerWeek + schedule.preferredDays. Coerce a
  // minimal object so this works for partial profiles too — a user who
  // edited daysPerWeek alone on the You tab still gets a plan.
  const profile = {
    schedule: {
      daysPerWeek: typeof profileData.schedule?.daysPerWeek === "number"
        ? profileData.schedule.daysPerWeek
        : 3,
      preferredDays: Array.isArray(profileData.schedule?.preferredDays)
        ? (profileData.schedule.preferredDays as string[])
        : [],
    },
  };

  const now = new Date().toISOString();
  const plan = buildWorkoutPlanFromProfile(
    userId,
    profile,
    seed.DEFAULT_PLAN,
    now,
  );

  // Overwrites both workoutPlans/current and trainingPrograms/current — old
  // days/weeks that were dropped should go.
  await writeRegeneratedPlanAndProgram(db, userId, plan.days, now);

  await recordAuditEventBestEffort(db, {
    userId,
    eventType: "memory_fact_written", // closest existing audit category
    actor: "user",
    payload: { source: "regenerate_plan", daysPerWeek: profile.schedule.daysPerWeek },
  });

  return { ok: true as const, daysPerWeek: profile.schedule.daysPerWeek };
}

export const regenerateWorkoutPlan = onCall(CALLABLE_OPTS, async (request) => {
  const userId = requireUserId(request.auth);
  return handleRegenerateWorkoutPlan(userId);
});

// Phase 3 Task 3.1 — Account deletion.
//
// User-initiated wipe. Writes a tombstone at deletedAccounts/{uid} BEFORE
// the destructive ops (so the audit trail survives the deletion of the
// user's data), then recursively deletes users/{uid}/**, then revokes all
// refresh tokens so any signed-in clients can't keep using the session.
//
// Required by Apple App Store guideline 5.1.1(v) and CCPA/GDPR Article 17.
export const deleteAccount = onCall(
  CALLABLE_OPTS,
  async (request) => {
    const userId = requireUserId(request.auth);

    // Tombstone first — this is the audit-of-record for deletion and must
    // outlive the user's data. Use a separate path collection outside
    // users/ so it survives the recursive delete below.
    const now = new Date().toISOString();
    await db.doc(deletedAccountPath(userId)).set({
      userId,
      deletedAt: now,
      requestedBy: "user",
    });

    // Then the audit log inside the user tree (this entry will be wiped
    // along with everything else, but it's worth writing so any external
    // pipeline watching audit events gets a deletion signal too).
    await recordAuditEventBestEffort(db, {
      userId,
      eventType: "account_deletion_requested",
      actor: "user",
    });

    // Recursive delete of all user-scoped data.
    await deleteDocumentTree(db.doc(userRoot(userId)));

    // Finally, revoke refresh tokens so any active client sessions
    // can't continue making authenticated calls.
    await getAuth().revokeRefreshTokens(userId);

    return { ok: true, userId, deletedAt: now };
  },
);

export const getCoachBootstrap = onCall(CALLABLE_OPTS, async (request) => {
  requireUserId(request.auth);
  return {
    coach,
    seed: {
      muscleGroups: seed.MUSCLE_GROUPS,
      exerciseLibrary: seed.EXERCISE_LIBRARY,
      exerciseDb: seed.EXERCISE_DB,
      swapOptions: seed.SWAP_OPTIONS,
      defaultPlan: seed.DEFAULT_PLAN,
      dailyHabits: seed.DAILY_HABITS,
      philosophy: seed.PHILOSOPHY,
    },
  };
});

// Wipes users/{uid}/** but (unlike
// deleteAccount) keeps the auth user and writes no tombstone: this is
// "start over", not "delete my account". The parity audit
// (claude/callable-migration) found no callable existed for this endpoint.
export const resetMyData = onCall(CALLABLE_OPTS, async (request) => {
  const userId = requireUserId(request.auth);
  await deleteDocumentTree(db.doc(userRoot(userId)), RESET_KEEPS);
  return { ok: true, userId };
});


export const getUserState = onCall(CALLABLE_OPTS, async (request) => {
  const userId = requireUserId(request.auth);
  const today = z
    .object({ today: z.string().date().optional() })
    .parse(request.data ?? {}).today;

  const [profileSnap, planSnap, dailySnap, logsSnap] = await Promise.all([
    db.doc(profilePath(userId)).get(),
    db.doc(workoutPlanPath(userId)).get(),
    today ? db.doc(dailyCheckPath(userId, today)).get() : Promise.resolve(null),
    db
      .collection(`${userRoot(userId)}/workoutLogs`)
      .orderBy("date", "desc")
      .limit(30)
      .get(),
  ]);

  return {
    profile: profileSnap.exists ? profileSnap.data() : null,
    plan: planSnap.exists ? planSnap.data() : null,
    daily: dailySnap?.exists ? dailySnap.data() : null,
    recentLogs: logsSnap.docs.map((doc) => doc.data()),
  };
});

// Implementation behind upsertProfile. createdAt/updatedAt are required by the schema but
// server-owned — the client never sends them. Inject here: preserve the
// original createdAt on updates, stamp updatedAt now. (The pre-migration
// onCall demanded them from the client and so rejected every real iOS
// payload — drift found by the parity audit on claude/callable-migration.)
export async function handleUpsertProfile(userId: string, rawData: unknown) {
  const now = new Date().toISOString();
  const existing = await db.doc(profilePath(userId)).get();
  const createdAt =
    existing.exists && typeof existing.data()?.createdAt === "string"
      ? (existing.data()!.createdAt as string)
      : now;
  const body = isRecord(rawData) ? rawData : {};
  const parsed = UserHealthProfile.parse({
    ...stripUserId(body, userId),
    createdAt,
    updatedAt: now,
  });

  await db.doc(profilePath(userId)).set(
    {
      ...parsed,
      serverUpdatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  return { ok: true as const, userId };
}

export const upsertProfile = onCall(CALLABLE_OPTS, async (request) => {
  const userId = requireUserId(request.auth);
  return handleUpsertProfile(userId, request.data);
});

export const recordConsent = onCall(CALLABLE_OPTS, async (request) => {
  const userId = requireUserId(request.auth);
  const parsed = ConsentRecord.parse(stripUserId(request.data, userId));

  await db.doc(consentRecordPath(userId, parsed.recordId)).set({
    ...parsed,
    serverRecordedAt: FieldValue.serverTimestamp(),
  });

  // Phase 3.4 — audit log. Best-effort: a failed audit must not block the
  // consent write that just succeeded.
  await recordAuditEventBestEffort(db, {
    userId,
    eventType: parsed.granted ? "consent_granted" : "consent_revoked",
    actor: "user",
    payload: {
      recordId: parsed.recordId,
      category: parsed.category,
      granted: parsed.granted,
    },
  });

  return { ok: true, recordId: parsed.recordId };
});

export const logWorkout = onCall(CALLABLE_OPTS, async (request) => {
  const userId = requireUserId(request.auth);
  const parsed = WorkoutLog.parse(stripUserId(request.data, userId));

  await db.doc(workoutLogPath(userId, parsed.sessionId)).set({
    ...parsed,
    serverRecordedAt: FieldValue.serverTimestamp(),
  });

  return { ok: true, sessionId: parsed.sessionId };
});

export const upsertWorkoutPlan = onCall(
  CALLABLE_OPTS,
  async (request) => {
    const userId = requireUserId(request.auth);
    const parsed = WorkoutPlan.parse(stripUserId(request.data, userId));

    await db.doc(workoutPlanPath(userId, parsed.planId)).set(
      {
        ...parsed,
        serverUpdatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    return { ok: true, planId: parsed.planId };
  },
);

export const recordDailyCheck = onCall(
  CALLABLE_OPTS,
  async (request) => {
    const userId = requireUserId(request.auth);
    const parsed = DailyCheck.parse(stripUserId(request.data, userId));

    await db.doc(dailyCheckPath(userId, parsed.date)).set(
      {
        ...parsed,
        serverUpdatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    return { ok: true, date: parsed.date };
  },
);

export const startWorkoutSessionCallable = onCall(
  CALLABLE_OPTS,
  async (request) => {
    const userId = requireUserId(request.auth);
    logAppCheckPresence("startWorkoutSession", request.app !== undefined, userId);
    const parsed = StartWorkoutSessionRequest.parse(request.data ?? {});
    const activeWorkout = await startWorkoutSession(db, userId, parsed, seed.DEFAULT_PLAN);
    return { ok: true, activeWorkout };
  },
);

export const finishWorkoutSessionCallable = onCall(
  CALLABLE_OPTS,
  async (request) => {
    const userId = requireUserId(request.auth);
    logAppCheckPresence("finishWorkoutSession", request.app !== undefined, userId);
    const parsed = FinishWorkoutSessionRequest.parse(request.data ?? {});
    const result = await finishWorkoutSession(db, userId, parsed);
    return { ok: true, ...result };
  },
);

// Coach's spoken voice — one sentence or two of a reply as WAV audio.
//
// Metered per user per day (usage/cap.ts) because Cloud TTS is billed per
// character on the project's own service account and any signed-in user —
// including an anonymous one minted with the public web API key — can call
// this. Over the cap the app falls back to the on-device voice, so the
// user still hears the reply; only the bill stops. Text replies are never
// affected (the message/token caps are separate).
export const synthesizeSpeechCallable = onCall(
  { ...CALLABLE_OPTS, timeoutSeconds: 30, memory: "256MiB" },
  async (request) => {
    const userId = requireUserId(request.auth);
    const signInProvider = (request.auth?.token as { firebase?: { sign_in_provider?: string } } | undefined)
      ?.firebase?.sign_in_provider;
    if (!ttsAllowedForSignInProvider(signInProvider)) {
      throw new HttpsError("permission-denied", "tts_requires_sign_in");
    }
    const parsed = parseCallablePayload(SynthesizeSpeechRequest, request.data, "synthesizeSpeech");
    const cap = await checkDailyTtsCap(db, userId, parsed.text.length);
    if (!cap.allowed) {
      safeLogger.warn("Spoken-reply cap reached", {
        event: "tts_cap_reached",
        userId,
        errorCode: cap.reason,
        ttsChars: cap.usage.ttsChars,
      });
      // Same audit-of-record as the message/token caps (orchestrate.ts), so
      // the privacy policy's "every spend-cap hit is in your audit log"
      // stays true for the voice budget.
      await recordAuditEventBestEffort(db, {
        userId,
        eventType: "daily_spend_cap_reached",
        actor: "system",
        payload: { reason: cap.reason, dateKey: cap.dateKey },
      });
      throw new HttpsError("resource-exhausted", cap.reason);
    }
    const speech = await synthesizeSpeech(parsed);
    // Count only audio that was actually produced; a failed synthesis
    // costs nothing and should not eat the budget.
    await recordTtsUsage(db, userId, cap.dateKey, parsed.text.length);
    return { ok: true, ...speech };
  },
);

// Throw away an unfinished session (started, never finished). No log written.
export const abandonWorkoutSessionCallable = onCall(CALLABLE_OPTS, async (request) => {
  const userId = requireUserId(request.auth);
  const parsed = AbandonWorkoutSessionRequest.parse(request.data ?? {});
  const result = await abandonWorkoutSession(db, userId, parsed);
  return { ok: true, ...result };
});

// --- Exercise swaps & weight rebaselining ------------------------------
//
// These mutate the plan WITHOUT a review card, under the narrow-deterministic-
// edit carve-out in docs/plans/myo-flexible-workout-adaptation-plan.md ("one-off
// workout changes can be applied to the active session after user confirmation";
// "narrow deterministic edits ... scoped to one exercise" may auto-apply). The
// user's tap IS the confirmation, the change is bounded to a single exercise,
// and both write an audit event since there's no proposal doc to look back at.

export const getExerciseSwapOptionsCallable = onCall(CALLABLE_OPTS, async (request) => {
  const userId = requireUserId(request.auth);
  const parsed = GetExerciseSwapOptionsRequest.parse(request.data ?? {});
  return await getExerciseSwapOptions(db, userId, parsed);
});

export const swapExerciseCallable = onCall(CALLABLE_OPTS, async (request) => {
  const userId = requireUserId(request.auth);
  const parsed = SwapExerciseRequest.parse(request.data ?? {});
  return await swapExercise(db, userId, parsed);
});

export const applyExerciseBaselinesCallable = onCall(CALLABLE_OPTS, async (request) => {
  const userId = requireUserId(request.auth);
  const parsed = ApplyExerciseBaselinesRequest.parse(request.data ?? {});
  return await applyExerciseBaselines(db, userId, parsed);
});

// Phase 2 Task 2.3 — proposal queue.
// 14-day TTL for unconfirmed proposed facts. Long enough that a returning
// user can review what the coach inferred while they were gone; short
// enough that stale guesses don't accumulate forever.
const PROPOSED_FACT_TTL_MS = 14 * 24 * 60 * 60 * 1_000;

export const upsertMemoryFact = onCall(CALLABLE_OPTS, async (request) => {
  const userId = requireUserId(request.auth);
  const parsed = CoachMemoryFact.parse(stripUserId(request.data, userId));

  // Server decides the state — never trust the client/model on this.
  // user_stated → confirmed (they told us themselves).
  // everything else → proposed with a 14-day expiry, even if the client
  //                   sent state: "confirmed". A client cannot self-confirm
  //                   coach-inferred memory; only confirmMemoryFact can.
  const now = new Date();
  const decidedState =
    parsed.source === "user_stated" ? "confirmed" : "proposed";

  const writeData: Record<string, unknown> = {
    ...parsed,
    state: decidedState,
    serverUpdatedAt: FieldValue.serverTimestamp(),
  };

  if (decidedState === "confirmed") {
    if (!parsed.lastConfirmedAt) {
      writeData.lastConfirmedAt = now.toISOString();
    }
    // Confirmed facts don't expire; clear any prior expiresAt if upgrading.
    writeData.expiresAt = FieldValue.delete();
  } else {
    if (!parsed.expiresAt) {
      writeData.expiresAt = new Date(
        now.getTime() + PROPOSED_FACT_TTL_MS,
      ).toISOString();
    }
  }

  await db.doc(memoryFactPath(userId, parsed.factId)).set(writeData, {
    merge: true,
  });

  // Phase 3.4 — audit log. Actor is "user" for user_stated upserts, "coach"
  // for everything else (coach_inferred, log_derived, healthkit_derived).
  // We hash {factId, category, source, state} — never the content.
  await recordAuditEventBestEffort(db, {
    userId,
    eventType: "memory_fact_written",
    actor: parsed.source === "user_stated" ? "user" : "coach",
    payload: {
      factId: parsed.factId,
      category: parsed.category,
      source: parsed.source,
      state: decidedState,
    },
  });

  return { ok: true, factId: parsed.factId, state: decidedState };
});

export const confirmMemoryFact = onCall(
  CALLABLE_OPTS,
  async (request) => {
    const userId = requireUserId(request.auth);
    const parsed = z
      .object({ factId: z.string().min(1) })
      .parse(request.data);

    // Idempotent: even if already confirmed, refresh lastConfirmedAt and
    // clear any expiresAt that lingered from a prior proposed state.
    await db.doc(memoryFactPath(userId, parsed.factId)).set(
      {
        state: "confirmed",
        lastConfirmedAt: new Date().toISOString(),
        expiresAt: FieldValue.delete(),
        serverUpdatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    await recordAuditEventBestEffort(db, {
      userId,
      eventType: "memory_fact_confirmed",
      actor: "user",
      payload: { factId: parsed.factId },
    });

    return { ok: true, factId: parsed.factId };
  },
);

export const deleteMemoryFact = onCall(CALLABLE_OPTS, async (request) => {
  const userId = requireUserId(request.auth);
  const parsed = z.object({ factId: z.string().min(1) }).parse(request.data);

  await db.doc(memoryFactPath(userId, parsed.factId)).set(
    {
      userDeletedAt: new Date().toISOString(),
      serverDeletedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  await recordAuditEventBestEffort(db, {
    userId,
    eventType: "memory_fact_deleted",
    actor: "user",
    payload: { factId: parsed.factId },
  });

  return { ok: true, factId: parsed.factId };
});

// Phase 2 Task 2.4 — HealthKit sample ingestion.
// iOS posts samples in batches (max 500); server gates on per-category
// consent, dedupes via sampleHash as the doc ID, batch-writes the new ones.
// Returns { inserted, duplicates, rejectedNoConsent: [hash,...] } so the
// client can surface state without re-reading.
export const ingestHealthSamples = onCall(
  CALLABLE_OPTS,
  async (request) => {
    const userId = requireUserId(request.auth);
    const parsed = IngestHealthSamplesRequest.parse(request.data);
    const result = await ingestHealthKitSamples(db, userId, {
      samples: parsed.samples,
    });

    // Phase 3.4 — audit log per batch (not per sample). Counts only.
    await recordAuditEventBestEffort(db, {
      userId,
      eventType: "health_samples_ingested",
      actor: "user",
      payload: {
        inserted: result.inserted,
        duplicates: result.duplicates,
        rejectedCount: result.rejectedNoConsent.length,
      },
    });

    return { ok: true, ...result };
  },
);

export const revokeConsent = onCall(CALLABLE_OPTS, async (request) => {
  const userId = requireUserId(request.auth);
  const parsed = z.object({ recordId: z.string().min(1) }).parse(request.data);

  await db.doc(consentRecordPath(userId, parsed.recordId)).set(
    {
      userId,
      recordId: parsed.recordId,
      granted: false,
      revokedAt: new Date().toISOString(),
      serverRecordedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  await recordAuditEventBestEffort(db, {
    userId,
    eventType: "consent_revoked",
    actor: "user",
    payload: { recordId: parsed.recordId },
  });

  return { ok: true, recordId: parsed.recordId };
});

export const createCoachSession = onCall(
  CALLABLE_OPTS,
  async (request) => {
    const userId = requireUserId(request.auth);
    const parsed = z
      .object({
        sessionId: z.string().min(1),
        startedAt: z.string().datetime(),
      })
      .parse(request.data);

    await db.doc(coachSessionPath(userId, parsed.sessionId)).set(
      {
        userId,
        sessionId: parsed.sessionId,
        startedAt: parsed.startedAt,
        outcome: "active",
        serverCreatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    return { ok: true, sessionId: parsed.sessionId };
  },
);

// Parity-audited against the retired sendCoachMessageHttp. Pre-migration this
// callable parsed CoachMessage.extend(...) STRICT — so the clientDate and
// startedAt the iOS app sends were REJECTED — and it skipped the session
// upsert and the deterministic weight-update path
// (maybeApplyWorkoutPlanAdjustment). Both wrappers now parse the same
// IosCoachMessageRequest and call the same handleSendCoachMessage.
export const sendCoachMessage = onCall(CALLABLE_OPTS, async (request) => {
  const userId = requireUserId(request.auth);
  logAppCheckPresence("sendCoachMessage", request.app !== undefined, userId);
  const parsed = parseCallablePayload(IosCoachMessageRequest, request.data, "sendCoachMessage");
  return handleSendCoachMessage(db, userId, parsed);
});


// Same OnboardingAnswerRequest schema, processOnboardingAnswer core and
// response shape as the retired sendOnboardingAnswerHttp. The parity audit
// found no callable existed for this endpoint.
export const sendOnboardingAnswer = onCall(CALLABLE_OPTS, async (request) => {
  const userId = requireUserId(request.auth);
  const parsed = parseCallablePayload(OnboardingAnswerRequest, request.data, "sendOnboardingAnswer");
  return processOnboardingAnswer(db, userId, parsed, seed.DEFAULT_PLAN);
});

// Same schema, core and response shape as the retired
// acceptProgramProposalHttp. The parity audit found no callable existed for
// this endpoint.
export const acceptProgramProposal = onCall(CALLABLE_OPTS, async (request) => {
  const userId = requireUserId(request.auth);
  const parsed = parseCallablePayload(AcceptProgramProposalRequest, request.data, "acceptProgramProposal");
  return acceptProgramProposalCore(db, userId, parsed);
});

// Same as the retired acceptPlanAdjustmentProposalHttp — same schema (including
// the scope + clientDate fields the iOS proposal card sends), same core,
// same response shape. The parity audit found no callable existed for this
// endpoint.
export const acceptPlanAdjustmentProposal = onCall(
  CALLABLE_OPTS,
  async (request) => {
    const userId = requireUserId(request.auth);
    const parsed = parseCallablePayload(AcceptPlanAdjustmentProposalRequest, request.data, "acceptPlanAdjustmentProposal");
    try {
      return await acceptPlanAdjustmentProposalCore(db, userId, parsed);
    } catch (error) {
      throw acceptPlanAdjustmentHttpsError(error, userId, parsed.proposalId);
    }
  },
);

// The accept core signals every outcome with a plain `new Error(code)`.
// firebase-functions turns any non-HttpsError throw into a bare 500
// "INTERNAL", and the iOS SDK surfaces that verbatim — so a proposal that
// was simply superseded by a newer one read to the user as an app crash,
// identical to a real infrastructure failure. (The retired *Http twin never
// had this problem; it returned named codes. The callable migration
// flattened them.)
// Mapping them here restores a distinguishable, actionable error per case
// without leaking anything user-specific: every message below is a fixed
// string chosen by us, never model or user text.
const ACCEPT_ERROR_STATUS: Record<string, { code: "not-found" | "failed-precondition" | "permission-denied"; message: string }> = {
  plan_adjustment_proposal_not_found: { code: "not-found", message: "proposal_not_found" },
  workout_plan_not_found: { code: "not-found", message: "workout_plan_not_found" },
  plan_adjustment_user_mismatch: { code: "permission-denied", message: "proposal_not_yours" },
  plan_adjustment_not_pending: { code: "failed-precondition", message: "proposal_no_longer_pending" },
  plan_adjustment_requires_review: { code: "failed-precondition", message: "proposal_requires_review" },
  plan_adjustment_target_day_not_found: { code: "failed-precondition", message: "target_day_not_found" },
  plan_adjustment_patch_not_supported: { code: "failed-precondition", message: "patch_not_supported" },
  plan_adjustment_patch_removed_all_exercises: { code: "failed-precondition", message: "patch_empties_day" },
  plan_adjustment_ramp_produced_no_days: { code: "failed-precondition", message: "ramp_no_longer_applies" },
  training_program_not_loaded_for_cascade: { code: "failed-precondition", message: "program_not_ready" },
};

function acceptPlanAdjustmentHttpsError(error: unknown, userId: string, proposalId: string) {
  const raw = error instanceof Error ? error.message : "";
  const mapped = ACCEPT_ERROR_STATUS[raw];
  if (mapped) {
    safeLogger.info("Plan adjustment accept rejected", {
      event: "plan_adjustment_accept_rejected",
      userId,
      proposalId,
      errorCode: mapped.message,
    });
    return new HttpsError(mapped.code, mapped.message);
  }
  // Genuinely unexpected (Firestore ABORTED, ZodError on a stored doc, a
  // bug): keep it opaque to the client but make it findable in logs.
  safeLogger.error("Plan adjustment accept failed", {
    event: "plan_adjustment_accept_error",
    userId,
    proposalId,
    errorCode: "accept_failed",
    errorDetail: raw.slice(0, 200),
  });
  return new HttpsError("internal", "accept_failed");
}






const SafetyEvalResult = z.object({
  caseId: z.string().min(1),
  passed: z.boolean(),
  notes: z.string().optional(),
});

export const recordSafetyEvalResult = onCall(
  CALLABLE_OPTS,
  async (request) => {
    requireAdmin(request.auth);
    const userId = request.auth?.uid ?? "unknown";
    const parsed = SafetyEvalResult.parse(request.data);

    await db
      .collection("internalSafetyEvalResults")
      .doc(`${parsed.caseId}_${Date.now()}`)
      .set({
        ...parsed,
        recordedBy: userId,
        recordedAt: FieldValue.serverTimestamp(),
      });

    return { ok: true };
  },
);

export const onUserCoachMessageCreated = onDocumentCreated(
  {
    region: "us-central1",
    document: "users/{userId}/coachSessions/{sessionId}/messages/{messageId}",
    secrets: [geminiApiKey, openRouterApiKey],
    // Bill protection + sanity. A chat turn should never need more than 60s.
    // maxInstances caps a runaway client at ~20 concurrent coach turns.
    // retry:false because we never want a coach turn to silently re-run
    // (would double-bill the model and write conflicting assistant messages).
    timeoutSeconds: 60,
    maxInstances: 20,
    concurrency: 1,
    cpu: 1,
    memory: "512MiB",
    retry: false,
  },
  async (event) => {
    const data = event.data?.data();
    if (!data || data.role !== "user" || data.status !== "queued") return;

    const { userId, sessionId, messageId } = event.params;
    const turnId = randomUUID();

    await orchestrateCoachTurn({
      db,
      coach,
      userId,
      sessionId,
      messageId,
      turnId,
      userContent: data.content,
      clientDate: typeof data.clientDate === "string" ? data.clientDate : undefined,
      inputMode: typeof data.inputMode === "string" ? data.inputMode : undefined,
      coachTips: CoachTips.safeParse(data.coachTips).data,
      coachTone: CoachTone.safeParse(data.coachTone).data,
      geminiApiKey: geminiApiKey.value() || process.env.GEMINI_API_KEY,
      openRouterApiKey: openRouterApiKey.value() || process.env.OPENROUTER_API_KEY,
    });
  },
);

// MYO progress layer — a finished session is the natural heartbeat for the
// derived progress doc (users/{uid}/derivedSummaries/progress_current).
// Debounce (≤1 rebuild/hour, keyed off the doc's computedAt) lives in
// recomputeProgressSummaryIfStale so the emulator suite can exercise it
// directly. retry:false + swallow-and-warn because the summary is derived
// advisory context: the next log (or any later trigger) heals it, and a
// rebuild failure must never look like a failed workout log to the platform.
export const onWorkoutLogCreated = onDocumentCreated(
  {
    region: "us-central1",
    document: "users/{userId}/workoutLogs/{sessionId}",
    timeoutSeconds: 60,
    maxInstances: 10,
    retry: false,
  },
  async (event) => {
    const { userId } = event.params;
    try {
      await recomputeProgressSummaryIfStale(db, userId);
    } catch (error) {
      safeLogger.warn("Progress summary recompute failed", {
        event: "progress_summary_recompute_failed",
        userId,
        errorCode: error instanceof Error ? error.name : "unknown_error",
        errorDetail:
          error instanceof Error ? error.message.slice(0, 180) : "unknown_error",
      });
    }
  },
);

// Recovery-arc delivery — see coach/followUps.ts for the sweep itself.
export const dailyCoachFollowUps = onSchedule(
  {
    schedule: "every day 14:00",
    timeZone: "America/New_York",
    region: "us-central1",
    retryCount: 1,
  },
  async () => {
    await sweepCoachFollowUps(db);
  },
);

// Week rollover — see workouts/rollover.ts. Scheduled DAILY (shortly after
// midnight ET) rather than weekly because users start programs on any
// weekday, so every user's week boundary falls on a different calendar day;
// programs already on the right week are a no-op read.
export const weeklyProgramRollover = onSchedule(
  {
    schedule: "every day 00:30",
    timeZone: "America/New_York",
    region: "us-central1",
    retryCount: 1,
  },
  async () => {
    await rolloverTrainingPrograms(db);
    // Piggybacks on the same daily schedule (one scheduler, two sweeps —
    // cheaper than a third onSchedule): retire pending plan-adjustment
    // proposals older than 7 days. Both sweeps are idempotent, so the
    // scheduler retry re-running the pair is safe.
    await expireStalePendingProposals(db);
  },
);
