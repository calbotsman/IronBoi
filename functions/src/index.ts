import { createRequire } from "node:module";
import { randomUUID } from "node:crypto";
import type { CollectionReference, DocumentReference } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { defineSecret } from "firebase-functions/params";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { HttpsError, onCall, onRequest } from "firebase-functions/v2/https";
import { z } from "zod";
import { auth, db } from "./firebase.js";
import { orchestrateCoachTurn } from "./coach/orchestrate.js";
import type { CoachConfig } from "./coach/prompt.js";
import {
  CoachMemoryFact,
  CoachInputMode,
  CoachMessage,
  ConsentRecord,
  DailyCheck,
  UserHealthProfile,
  WorkoutLog,
  WorkoutPlan,
} from "./contracts/coach-agent.js";
import {
  coachSessionMessagePath,
  coachSessionPath,
  consentRecordPath,
  dailyCheckPath,
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
} from "./workouts/planAdjustments.js";
import { safeLogger } from "./logging/safeLogger.js";
import {
  AcceptProgramProposalRequest,
  OnboardingAnswerRequest,
  acceptProgramProposal,
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

    transaction.set(
      planRef,
      {
        days: nextDays,
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

export const getCoachBootstrap = onCall({ region: "us-central1" }, async (request) => {
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

export const getUserState = onCall({ region: "us-central1" }, async (request) => {
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

export const upsertProfile = onCall({ region: "us-central1" }, async (request) => {
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

export const recordConsent = onCall({ region: "us-central1" }, async (request) => {
  const userId = requireUserId(request.auth);
  const parsed = ConsentRecord.parse(stripUserId(request.data, userId));

  await db.doc(consentRecordPath(userId, parsed.recordId)).set({
    ...parsed,
    serverRecordedAt: FieldValue.serverTimestamp(),
  });

  return { ok: true, recordId: parsed.recordId };
});

export const logWorkout = onCall({ region: "us-central1" }, async (request) => {
  const userId = requireUserId(request.auth);
  const parsed = WorkoutLog.parse(stripUserId(request.data, userId));

  await db.doc(workoutLogPath(userId, parsed.sessionId)).set({
    ...parsed,
    serverRecordedAt: FieldValue.serverTimestamp(),
  });

  return { ok: true, sessionId: parsed.sessionId };
});

export const upsertWorkoutPlan = onCall(
  { region: "us-central1" },
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
  { region: "us-central1" },
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
  { region: "us-central1" },
  async (request) => {
    const userId = requireUserId(request.auth);
    const parsed = StartWorkoutSessionRequest.parse(request.data ?? {});
    const activeWorkout = await startWorkoutSession(db, userId, parsed, seed.DEFAULT_PLAN);
    return { ok: true, activeWorkout };
  },
);

export const finishWorkoutSessionCallable = onCall(
  { region: "us-central1" },
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

export const upsertMemoryFact = onCall({ region: "us-central1" }, async (request) => {
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

  return { ok: true, factId: parsed.factId, state: decidedState };
});

export const confirmMemoryFact = onCall(
  { region: "us-central1" },
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

    return { ok: true, factId: parsed.factId };
  },
);

export const deleteMemoryFact = onCall({ region: "us-central1" }, async (request) => {
  const userId = requireUserId(request.auth);
  const parsed = z.object({ factId: z.string().min(1) }).parse(request.data);

  await db.doc(memoryFactPath(userId, parsed.factId)).set(
    {
      userDeletedAt: new Date().toISOString(),
      serverDeletedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  return { ok: true, factId: parsed.factId };
});

export const revokeConsent = onCall({ region: "us-central1" }, async (request) => {
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

  return { ok: true, recordId: parsed.recordId };
});

export const createCoachSession = onCall(
  { region: "us-central1" },
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

export const sendCoachMessage = onCall({ region: "us-central1" }, async (request) => {
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

  const planAdjustment = await maybeCreatePlanAdjustmentProposal({
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

      await db
        .doc(coachSessionMessagePath(userId, parsed.sessionId, parsed.messageId))
        .set(messageData);
      const directPlanAdjustment = await maybeApplyWorkoutPlanAdjustment(
        userId,
        parsed.content,
        parsed.structuredAnswer,
      );
      const planAdjustment =
        directPlanAdjustment ??
        (await maybeCreatePlanAdjustmentProposal({
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

const SafetyEvalResult = z.object({
  caseId: z.string().min(1),
  passed: z.boolean(),
  notes: z.string().optional(),
});

export const recordSafetyEvalResult = onCall(
  { region: "us-central1" },
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
      geminiApiKey: geminiApiKey.value() || process.env.GEMINI_API_KEY,
    });
  },
);
