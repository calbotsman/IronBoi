import { createRequire } from "node:module";
import { randomUUID } from "node:crypto";
import type { CollectionReference, DocumentReference } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { defineSecret } from "firebase-functions/params";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { HttpsError, onCall, onRequest } from "firebase-functions/v2/https";
import { z } from "zod";
import { auth, db } from "./firebase.js";
import { isCoachToolLoopEnabled, orchestrateCoachTurn } from "./coach/orchestrate.js";
import { sweepCoachFollowUps } from "./followups/sweep.js";
import type { CoachConfig } from "./coach/prompt.js";
import {
  CoachMemoryFact,
  CoachInputMode,
  CoachMessage,
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
  coachSessionMessagePath,
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
  StartWorkoutSessionRequest,
  finishWorkoutSession,
  startWorkoutSession,
} from "./workouts/activeWorkout.js";
import {
  AcceptPlanAdjustmentProposalRequest,
  acceptPlanAdjustmentProposal,
  maybeCreatePlanAdjustmentProposal,
  weekdayOfISODate,
} from "./workouts/planAdjustments.js";
import { writeRegeneratedPlanAndProgram } from "./workouts/program.js";
import { safeLogger } from "./logging/safeLogger.js";

// Phase 3 Task 3.2 — App Check enforcement (env-gated).
//
// Enforcement is driven by IRONBOI_ENFORCE_APP_CHECK and defaults OFF.
// It was disabled because it was the only thing enforced on the onCall
// surface (the *Http endpoints never enforced it), so a Debug build whose
// debug token wasn't registered had every callable — including profile
// save — rejected with app:INVALID while auth was VALID. Auth still
// protects every function. See docs/audits/myo-engineering-qa-2026-06-23.md.
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
// SCOPE CAVEAT: this gates the onCall surface only. The iOS app reaches the
// backend almost entirely through the *Http onRequest endpoints (bearer
// ID-token auth; the X-Firebase-AppCheck header it sends is never verified
// server-side), so flipping this protects little by itself. Before public
// launch, ALSO migrate the client off the *Http endpoints or add
// getAppCheck().verifyToken(...) inside each onRequest handler.
export function callableOpts(env: NodeJS.ProcessEnv = process.env) {
  const enforced = env.IRONBOI_ENFORCE_APP_CHECK === "true";
  return {
    region: "us-central1",
    enforceAppCheck: enforced,
    consumeAppCheckToken: enforced,
  } as const;
}

export const CALLABLE_OPTS = callableOpts();
import {
  AcceptProgramProposalRequest,
  OnboardingAnswerRequest,
  acceptProgramProposal,
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
const IosCoachMessageRequest = z.object({
  sessionId: z.string().min(1),
  messageId: z.string().min(1),
  content: z.string().min(1),
  timestamp: z.string().datetime(),
  toolCallIds: z.array(z.string()).default([]),
  inputMode: CoachInputMode.default("text"),
  structuredAnswer: z.record(z.string(), z.unknown()).optional(),
  turnId: z.string().min(1).optional(),
  startedAt: z.string().datetime().optional(),
  // The client's local calendar date — lets a chat-driven "yes, just today"
  // accept key its dailyOverride to the user's day, not the server's tz.
  clientDate: z.string().date().optional(),
});
const WorkoutPlanAdjustmentStructuredAnswer = z
  .object({
    kind: z.literal("workout_plan_adjustment"),
    dayKey: z.string().min(1),
    exerciseName: z.string().min(1),
  })
  .passthrough();

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

function bearerTokenFromRequest(request: { header(name: string): string | undefined }) {
  const authorization = request.header("authorization") ?? "";
  const match = authorization.match(/^Bearer (.+)$/i);
  return match?.[1];
}

function writeJsonResponse(
  response: { status(code: number): { json(body: unknown): void } },
  statusCode: number,
  body: unknown,
) {
  response.status(statusCode).json(body);
}

function decodeJwtPayload(token: string) {
  const payload = token.split(".")[1];
  if (!payload) return {};

  try {
    const normalized = payload.replace(/-/g, "+").replace(/_/g, "/");
    const decoded = JSON.parse(Buffer.from(normalized, "base64").toString("utf8")) as {
      aud?: unknown;
      exp?: unknown;
      iss?: unknown;
    };

    return {
      tokenAud: typeof decoded.aud === "string" ? decoded.aud : "unknown",
      tokenExp: typeof decoded.exp === "number" ? decoded.exp : 0,
      tokenIss: typeof decoded.iss === "string" ? decoded.iss : "unknown",
    };
  } catch {
    return {
      tokenAud: "unreadable",
      tokenExp: 0,
      tokenIss: "unreadable",
    };
  }
}

async function verifyBearerUserId(
  request: { header(name: string): string | undefined },
  response: { status(code: number): { json(body: unknown): void } },
) {
  const idToken = bearerTokenFromRequest(request);
  if (!idToken) {
    writeJsonResponse(response, 401, { ok: false, error: "missing_bearer_token" });
    return null;
  }

  try {
    const decoded = await auth.verifyIdToken(idToken);
    return decoded.uid;
  } catch (error) {
    safeLogger.warn("Firebase ID token rejected", {
      event: "firebase_id_token_rejected",
      errorCode: error instanceof Error ? error.name : "unknown_error",
      errorDetail: error instanceof Error ? error.message.slice(0, 180) : "unknown_error",
      ...decodeJwtPayload(idToken),
    });
    writeJsonResponse(response, 401, { ok: false, error: "invalid_token" });
    return null;
  }
}

function writeHttpHandlerError(
  response: { status(code: number): { json(body: unknown): void } },
  error: unknown,
  fallbackError: string,
) {
  if (error instanceof z.ZodError) {
    // Log issue PATHS (never values — they can carry user content) so a
    // chronic validation failure is visible to the operator instead of
    // silently 400ing users forever.
    safeLogger.warn("HTTP function rejected invalid request", {
      event: "http_function_invalid_request",
      errorCode: fallbackError,
      errorDetail: error.issues
        .slice(0, 5)
        .map((issue) => `${issue.path.join(".")}:${issue.code}`)
        .join(","),
    });
    writeJsonResponse(response, 400, { ok: false, error: "invalid_request" });
    return;
  }

  safeLogger.error("HTTP function failed", {
    event: "http_function_failed",
    errorCode: error instanceof Error ? error.name : "unknown_error",
    errorDetail: error instanceof Error ? error.message.slice(0, 180) : "unknown_error",
  });
  writeJsonResponse(response, 500, { ok: false, error: fallbackError });
}

async function maybeApplyWorkoutPlanAdjustment(
  userId: string,
  content: string,
  structuredAnswer: unknown,
) {
  const context = WorkoutPlanAdjustmentStructuredAnswer.safeParse(structuredAnswer);
  if (!context.success) return null;

  const targetWeight = parseRequestedPounds(content);
  if (targetWeight === null) return null;

  const planRef = db.doc(workoutPlanPath(userId, "current"));
  const now = new Date().toISOString();

  return db.runTransaction(async (transaction) => {
    const planSnap = await transaction.get(planRef);
    if (!planSnap.exists) return null;

    const plan = planSnap.data() ?? {};
    const days = isRecord(plan.days) ? plan.days : {};
    const rawDay = days[context.data.dayKey];
    const day = isRecord(rawDay) ? rawDay : null;
    const exercises: unknown[] =
      day && Array.isArray(day.exercises) ? day.exercises : [];
    const exerciseIndex = exercises.findIndex((exercise: unknown) => {
      if (!isRecord(exercise)) return false;
      return normalizeExerciseName(exercise.name) === normalizeExerciseName(context.data.exerciseName);
    });

    if (!day || exerciseIndex < 0) return null;

    const nextExercises = exercises.map((exercise: unknown, index: number) => {
      if (index !== exerciseIndex || !isRecord(exercise)) return exercise;
      return { ...exercise, weight: targetWeight };
    });
    const nextDays = {
      ...days,
      [context.data.dayKey]: {
        ...day,
        exercises: nextExercises,
      },
    };

    // If a dailyOverride is active for this day, the user is LOOKING at the
    // override, not the template — updating only the template would make
    // this weight change invisible. Patch the same exercise inside any
    // override whose weekday matches too.
    const overrides = isRecord(plan.dailyOverrides) ? plan.dailyOverrides : {};
    const nextOverrides = Object.fromEntries(
      Object.entries(overrides).map(([date, rawOverride]) => {
        if (!isRecord(rawOverride) || weekdayOfISODate(date) !== context.data.dayKey) {
          return [date, rawOverride];
        }
        const overrideExercises = Array.isArray(rawOverride.exercises) ? rawOverride.exercises : [];
        return [
          date,
          {
            ...rawOverride,
            exercises: overrideExercises.map((exercise: unknown) =>
              isRecord(exercise) &&
              normalizeExerciseName(exercise.name) === normalizeExerciseName(context.data.exerciseName)
                ? { ...exercise, weight: targetWeight }
                : exercise,
            ),
          },
        ];
      }),
    );

    transaction.set(
      planRef,
      {
        days: nextDays,
        ...(Object.keys(nextOverrides).length > 0 ? { dailyOverrides: nextOverrides } : {}),
        source: "user_edited",
        updatedAt: now,
        serverUpdatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    safeLogger.info("Workout plan adjusted from coach context", {
      event: "workout_plan_adjusted_from_coach_context",
      userId,
      outcome: "weight_updated",
    });

    return {
      dayKey: context.data.dayKey,
      exerciseName: context.data.exerciseName,
      targetWeight,
    };
  });
}

function parseRequestedPounds(content: string) {
  const match = content.match(/\b(\d+(?:\.\d+)?)\s*(?:lb|lbs|pound|pounds)\b/i);
  if (!match) return null;
  const value = Number(match[1]);
  return Number.isFinite(value) && value >= 0 ? value : null;
}

function normalizeExerciseName(value: unknown) {
  return typeof value === "string"
    ? value.trim().toLowerCase().replace(/[^a-z0-9]+/g, " ")
    : "";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function deleteDocumentTree(ref: DocumentReference) {
  const collections = await ref.listCollections();
  await Promise.all(collections.map(deleteCollectionTree));
  await ref.delete();
}

async function deleteCollectionTree(collection: CollectionReference) {
  const snapshot = await collection.get();
  for (const doc of snapshot.docs) {
    await deleteDocumentTree(doc.ref);
  }
}

// Phase 3 Task 3.1 — Account deletion.
//
// User-initiated wipe. Writes a tombstone at deletedAccounts/{uid} BEFORE
// the destructive ops (so the audit trail survives the deletion of the
// user's data), then recursively deletes users/{uid}/**, then revokes all
// refresh tokens so any signed-in clients can't keep using the session.
//
// Required by Apple App Store guideline 5.1.1(v) and CCPA/GDPR Article 17.
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
export const regenerateWorkoutPlan = onCall(CALLABLE_OPTS, async (request) => {
  const userId = requireUserId(request.auth);

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

  return { ok: true, daysPerWeek: profile.schedule.daysPerWeek };
});

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

export const resetMyDataHttp = onRequest(
  { region: "us-central1", invoker: "public" },
  async (request, response) => {
    response.set("Access-Control-Allow-Origin", "*");
    response.set("Access-Control-Allow-Headers", "Authorization, Content-Type");
    response.set("Access-Control-Allow-Methods", "POST, OPTIONS");

    if (request.method === "OPTIONS") {
      response.status(204).send("");
      return;
    }

    if (request.method !== "POST") {
      writeJsonResponse(response, 405, { ok: false, error: "method_not_allowed" });
      return;
    }

    const userId = await verifyBearerUserId(request, response);
    if (!userId) return;

    try {
      await deleteDocumentTree(db.doc(userRoot(userId)));
      writeJsonResponse(response, 200, { ok: true, userId });
    } catch (error) {
      writeHttpHandlerError(response, error, "reset_my_data_failed");
    }
  },
);

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

export const upsertProfile = onCall(CALLABLE_OPTS, async (request) => {
  const userId = requireUserId(request.auth);
  const parsed = UserHealthProfile.parse(stripUserId(request.data, userId));

  await db.doc(profilePath(userId)).set(
    {
      ...parsed,
      serverUpdatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  return { ok: true, userId };
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
    const parsed = StartWorkoutSessionRequest.parse(request.data ?? {});
    const activeWorkout = await startWorkoutSession(db, userId, parsed, seed.DEFAULT_PLAN);
    return { ok: true, activeWorkout };
  },
);

export const finishWorkoutSessionCallable = onCall(
  CALLABLE_OPTS,
  async (request) => {
    const userId = requireUserId(request.auth);
    const parsed = FinishWorkoutSessionRequest.parse(request.data ?? {});
    const result = await finishWorkoutSession(db, userId, parsed);
    return { ok: true, ...result };
  },
);

export const startWorkoutSessionHttp = onRequest(
  { region: "us-central1", invoker: "public" },
  async (request, response) => {
    response.set("Access-Control-Allow-Origin", "*");
    response.set("Access-Control-Allow-Headers", "Authorization, Content-Type");
    response.set("Access-Control-Allow-Methods", "POST, OPTIONS");

    if (request.method === "OPTIONS") {
      response.status(204).send("");
      return;
    }

    if (request.method !== "POST") {
      writeJsonResponse(response, 405, { ok: false, error: "method_not_allowed" });
      return;
    }

    const userId = await verifyBearerUserId(request, response);
    if (!userId) return;

    try {
      const parsed = StartWorkoutSessionRequest.parse(request.body?.data ?? request.body);
      const activeWorkout = await startWorkoutSession(
        db,
        userId,
        parsed,
        seed.DEFAULT_PLAN,
      );
      writeJsonResponse(response, 200, { ok: true, activeWorkout });
    } catch (error) {
      writeHttpHandlerError(response, error, "start_workout_failed");
    }
  },
);

export const finishWorkoutSessionHttp = onRequest(
  { region: "us-central1", invoker: "public" },
  async (request, response) => {
    response.set("Access-Control-Allow-Origin", "*");
    response.set("Access-Control-Allow-Headers", "Authorization, Content-Type");
    response.set("Access-Control-Allow-Methods", "POST, OPTIONS");

    if (request.method === "OPTIONS") {
      response.status(204).send("");
      return;
    }

    if (request.method !== "POST") {
      writeJsonResponse(response, 405, { ok: false, error: "method_not_allowed" });
      return;
    }

    const userId = await verifyBearerUserId(request, response);
    if (!userId) return;

    try {
      const parsed = FinishWorkoutSessionRequest.parse(request.body?.data ?? request.body);
      const result = await finishWorkoutSession(db, userId, parsed);
      writeJsonResponse(response, 200, { ok: true, ...result });
    } catch (error) {
      writeHttpHandlerError(response, error, "finish_workout_failed");
    }
  },
);

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

export const sendCoachMessage = onCall(CALLABLE_OPTS, async (request) => {
  const userId = requireUserId(request.auth);
  const parsed = CoachMessage.extend({
    sessionId: z.string().min(1),
    role: z.literal("user"),
  }).parse(stripUserId(request.data, userId));

  await db.doc(coachSessionMessagePath(userId, parsed.sessionId, parsed.messageId)).set({
    ...parsed,
    status: "queued",
    serverCreatedAt: FieldValue.serverTimestamp(),
  });

  // Flag on = the LLM tool loop (orchestrate.ts) owns proposal creation;
  // running the keyword classifier too would double-create proposals for
  // the same message.
  const planAdjustment = isCoachToolLoopEnabled()
    ? null
    : await maybeCreatePlanAdjustmentProposal({
        db,
        userId,
        content: parsed.content,
        structuredAnswer: parsed.structuredAnswer,
      });

  return { ok: true, messageId: parsed.messageId, planAdjustment };
});

export const sendCoachMessageHttp = onRequest(
  { region: "us-central1", invoker: "public" },
  async (request, response) => {
    response.set("Access-Control-Allow-Origin", "*");
    response.set("Access-Control-Allow-Headers", "Authorization, Content-Type");
    response.set("Access-Control-Allow-Methods", "POST, OPTIONS");

    if (request.method === "OPTIONS") {
      response.status(204).send("");
      return;
    }

    if (request.method !== "POST") {
      writeJsonResponse(response, 405, { ok: false, error: "method_not_allowed" });
      return;
    }

    const userId = await verifyBearerUserId(request, response);
    if (!userId) return;

    try {
      const parsed = IosCoachMessageRequest.parse(request.body?.data ?? request.body);
      const startedAt = parsed.startedAt ?? parsed.timestamp;

      await db.doc(coachSessionPath(userId, parsed.sessionId)).set(
        {
          userId,
          sessionId: parsed.sessionId,
          startedAt,
          outcome: "active",
          serverCreatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );

      const messageData: Record<string, unknown> = {
        userId,
        sessionId: parsed.sessionId,
        messageId: parsed.messageId,
        role: "user",
        content: parsed.content,
        timestamp: parsed.timestamp,
        toolCallIds: parsed.toolCallIds,
        inputMode: parsed.inputMode,
        status: "queued",
        serverCreatedAt: FieldValue.serverTimestamp(),
      };
      if (parsed.structuredAnswer !== undefined) {
        messageData.structuredAnswer = parsed.structuredAnswer;
      }
      if (parsed.turnId !== undefined) {
        messageData.turnId = parsed.turnId;
      }
      if (parsed.clientDate !== undefined) {
        messageData.clientDate = parsed.clientDate;
      }

      await db
        .doc(coachSessionMessagePath(userId, parsed.sessionId, parsed.messageId))
        .set(messageData);
      const directPlanAdjustment = await maybeApplyWorkoutPlanAdjustment(
        userId,
        parsed.content,
        parsed.structuredAnswer,
      );
      // Flag on = the LLM tool loop owns proposal creation (see
      // sendCoachMessage above); the direct weight-update path stays either
      // way — it's deterministic and narrower than anything the loop does.
      const planAdjustment =
        directPlanAdjustment ??
        (isCoachToolLoopEnabled()
          ? null
          : await maybeCreatePlanAdjustmentProposal({
              db,
              userId,
              content: parsed.content,
              structuredAnswer: parsed.structuredAnswer,
            }));

      writeJsonResponse(response, 200, {
        ok: true,
        userId,
        sessionId: parsed.sessionId,
        messageId: parsed.messageId,
        planAdjustment,
      });
    } catch (error) {
      writeHttpHandlerError(response, error, "send_coach_message_failed");
    }
  },
);

export const sendOnboardingAnswerHttp = onRequest(
  { region: "us-central1", invoker: "public" },
  async (request, response) => {
    response.set("Access-Control-Allow-Origin", "*");
    response.set("Access-Control-Allow-Headers", "Authorization, Content-Type");
    response.set("Access-Control-Allow-Methods", "POST, OPTIONS");

    if (request.method === "OPTIONS") {
      response.status(204).send("");
      return;
    }

    if (request.method !== "POST") {
      writeJsonResponse(response, 405, { ok: false, error: "method_not_allowed" });
      return;
    }

    const userId = await verifyBearerUserId(request, response);
    if (!userId) return;

    try {
      const parsed = OnboardingAnswerRequest.parse(request.body?.data ?? request.body);
      const result = await processOnboardingAnswer(db, userId, parsed, seed.DEFAULT_PLAN);
      writeJsonResponse(response, 200, result);
    } catch (error) {
      writeHttpHandlerError(response, error, "send_onboarding_answer_failed");
    }
  },
);

export const acceptProgramProposalHttp = onRequest(
  { region: "us-central1", invoker: "public" },
  async (request, response) => {
    response.set("Access-Control-Allow-Origin", "*");
    response.set("Access-Control-Allow-Headers", "Authorization, Content-Type");
    response.set("Access-Control-Allow-Methods", "POST, OPTIONS");

    if (request.method === "OPTIONS") {
      response.status(204).send("");
      return;
    }

    if (request.method !== "POST") {
      writeJsonResponse(response, 405, { ok: false, error: "method_not_allowed" });
      return;
    }

    const userId = await verifyBearerUserId(request, response);
    if (!userId) return;

    try {
      const parsed = AcceptProgramProposalRequest.parse(request.body?.data ?? request.body);
      const result = await acceptProgramProposal(db, userId, parsed);
      writeJsonResponse(response, 200, result);
    } catch (error) {
      writeHttpHandlerError(response, error, "accept_program_proposal_failed");
    }
  },
);

export const acceptPlanAdjustmentProposalHttp = onRequest(
  { region: "us-central1", invoker: "public" },
  async (request, response) => {
    response.set("Access-Control-Allow-Origin", "*");
    response.set("Access-Control-Allow-Headers", "Authorization, Content-Type");
    response.set("Access-Control-Allow-Methods", "POST, OPTIONS");

    if (request.method === "OPTIONS") {
      response.status(204).send("");
      return;
    }

    if (request.method !== "POST") {
      writeJsonResponse(response, 405, { ok: false, error: "method_not_allowed" });
      return;
    }

    const userId = await verifyBearerUserId(request, response);
    if (!userId) return;

    try {
      const parsed = AcceptPlanAdjustmentProposalRequest.parse(
        request.body?.data ?? request.body,
      );
      const result = await acceptPlanAdjustmentProposal(db, userId, parsed);
      writeJsonResponse(response, 200, result);
    } catch (error) {
      writeHttpHandlerError(response, error, "accept_plan_adjustment_failed");
    }
  },
);

// HTTP mirror of the upsertProfile onCall. The iOS app attaches a broken
// App Check token, and onCall callables reject an invalid token even with
// enforceAppCheck:false. This onRequest endpoint only verifies the Firebase
// Auth bearer token, matching the resilient pattern of the other *Http
// endpoints. Same behavior as upsertProfile: userId is always injected from
// the verified bearer token, never trusted from the body.
export const upsertProfileHttp = onRequest(
  { region: "us-central1", invoker: "public" },
  async (request, response) => {
    response.set("Access-Control-Allow-Origin", "*");
    response.set("Access-Control-Allow-Headers", "Authorization, Content-Type");
    response.set("Access-Control-Allow-Methods", "POST, OPTIONS");

    if (request.method === "OPTIONS") {
      response.status(204).send("");
      return;
    }

    if (request.method !== "POST") {
      writeJsonResponse(response, 405, { ok: false, error: "method_not_allowed" });
      return;
    }

    const userId = await verifyBearerUserId(request, response);
    if (!userId) return;

    try {
      // createdAt/updatedAt are required by the schema but server-owned — the
      // client never sends them. Inject here: preserve the original createdAt
      // on updates, stamp updatedAt now. (Without this, every save failed
      // schema validation, masked until now behind the App Check rejection.)
      const now = new Date().toISOString();
      const existing = await db.doc(profilePath(userId)).get();
      const createdAt =
        existing.exists && typeof existing.data()?.createdAt === "string"
          ? (existing.data()!.createdAt as string)
          : now;
      const parsed = UserHealthProfile.parse({
        ...stripUserId(request.body?.data ?? request.body, userId),
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

      writeJsonResponse(response, 200, { ok: true, userId });
    } catch (error) {
      writeHttpHandlerError(response, error, "upsert_profile_failed");
    }
  },
);

// HTTP mirror of the regenerateWorkoutPlan onCall. Same App Check rationale
// as upsertProfileHttp above. Rebuilds workoutPlans/current from the user's
// current profile and the seed default plan.
export const regenerateWorkoutPlanHttp = onRequest(
  { region: "us-central1", invoker: "public" },
  async (request, response) => {
    response.set("Access-Control-Allow-Origin", "*");
    response.set("Access-Control-Allow-Headers", "Authorization, Content-Type");
    response.set("Access-Control-Allow-Methods", "POST, OPTIONS");

    if (request.method === "OPTIONS") {
      response.status(204).send("");
      return;
    }

    if (request.method !== "POST") {
      writeJsonResponse(response, 405, { ok: false, error: "method_not_allowed" });
      return;
    }

    const userId = await verifyBearerUserId(request, response);
    if (!userId) return;

    try {
      const profileSnap = await db.doc(profilePath(userId)).get();
      if (!profileSnap.exists) {
        writeJsonResponse(response, 400, { ok: false, error: "profile_not_found" });
        return;
      }
      const profileData = profileSnap.data() ?? {};
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

      await writeRegeneratedPlanAndProgram(db, userId, plan.days, now);

      await recordAuditEventBestEffort(db, {
        userId,
        eventType: "memory_fact_written",
        actor: "user",
        payload: { source: "regenerate_plan", daysPerWeek: profile.schedule.daysPerWeek },
      });

      writeJsonResponse(response, 200, { ok: true, daysPerWeek: profile.schedule.daysPerWeek });
    } catch (error) {
      writeHttpHandlerError(response, error, "regenerate_workout_plan_failed");
    }
  },
);

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
    secrets: [geminiApiKey],
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
      geminiApiKey: geminiApiKey.value() || process.env.GEMINI_API_KEY,
    });
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
