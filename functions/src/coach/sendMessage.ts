import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { z } from "zod";
import { CoachInputMode } from "../contracts/coach-agent.js";
import {
  coachSessionMessagePath,
  coachSessionPath,
  workoutPlanPath,
} from "../paths.js";
import {
  maybeCreatePlanAdjustmentProposal,
  weekdayOfISODate,
} from "../workouts/planAdjustments.js";
import { isCoachToolLoopEnabled } from "./orchestrate.js";
import { safeLogger } from "../logging/safeLogger.js";

// The request shape the iOS app actually sends (previously only accepted by
// sendCoachMessageHttp). Shared by BOTH the onCall callable and the *Http
// wrapper so the two surfaces cannot drift again.
export const IosCoachMessageRequest = z.object({
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

export type IosCoachMessage = z.infer<typeof IosCoachMessageRequest>;

const WorkoutPlanAdjustmentStructuredAnswer = z
  .object({
    kind: z.literal("workout_plan_adjustment"),
    dayKey: z.string().min(1),
    exerciseName: z.string().min(1),
  })
  .passthrough();

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseRequestedPounds(content: string) {
  // LAST match wins: the workout-sheet context prefix ("currently 3x8 at
  // 135 lb.") precedes the user's actual request ("make it 155 lb"), so
  // first-match kept re-applying the CURRENT weight (live-audit finding,
  // fixed in the hardening PR and re-ported here after the extraction).
  const matches = [...content.matchAll(/\b(\d+(?:\.\d+)?)\s*(?:lb|lbs|pound|pounds)\b/gi)];
  const match = matches[matches.length - 1];
  if (!match) return null;
  const value = Number(match[1]);
  return Number.isFinite(value) && value >= 0 ? value : null;
}

function normalizeExerciseName(value: unknown) {
  return typeof value === "string"
    ? value.trim().toLowerCase().replace(/[^a-z0-9]+/g, " ")
    : "";
}

export async function maybeApplyWorkoutPlanAdjustment(
  db: Firestore,
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

// Shared coach-message handler — the single implementation behind BOTH
// sendCoachMessage (onCall) and sendCoachMessageHttp (onRequest). Preserves
// the full *Http behavior the iOS app depends on:
//   1. Upserts the session doc (the app never calls createCoachSession).
//   2. Writes the message with clientDate/turnId/structuredAnswer so the
//      onUserCoachMessageCreated trigger sees them.
//   3. Runs the deterministic weight-update path
//      (maybeApplyWorkoutPlanAdjustment) unconditionally.
//   4. Runs the keyword classifier only when the LLM tool loop is off —
//      flag on = the loop owns proposal creation; running both would
//      double-create proposals for the same message.
export async function handleSendCoachMessage(
  db: Firestore,
  userId: string,
  parsed: IosCoachMessage,
) {
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
    db,
    userId,
    parsed.content,
    parsed.structuredAnswer,
  );
  // Flag on = the LLM tool loop owns proposal creation; the direct
  // weight-update path stays either way — it's deterministic and narrower
  // than anything the loop does.
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

  return {
    ok: true as const,
    userId,
    sessionId: parsed.sessionId,
    messageId: parsed.messageId,
    planAdjustment,
  };
}
