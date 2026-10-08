import type { DocumentReference, Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { userRoot } from "../paths.js";

export type DailyUsageCaps = {
  messagesPerDay: number;
  inputTokensPerDay: number;
  outputTokensPerDay: number;
  /** Characters of coach speech synthesized per user per UTC day. */
  ttsCharsPerDay: number;
};

export type DailyUsage = {
  messageCount: number;
  inputTokens: number;
  outputTokens: number;
  ttsChars: number;
  capReached: boolean;
};

export type UsageCapCheck =
  | { allowed: true; usage: DailyUsage; dateKey: string }
  | { allowed: false; usage: DailyUsage; dateKey: string; reason: "daily_message_cap" | "daily_input_token_cap" | "daily_output_token_cap" };

/**
 * A cap read from the environment. A typo ("abc" → NaN) must not switch a
 * cap OFF (every `>= NaN` comparison is false), and an empty string must
 * not switch it to zero (which blocks everyone); either falls back to the
 * default. Exported for the unit test.
 */
export function capFromEnv(raw: string | undefined, fallback: number): number {
  if (raw === undefined) return fallback;
  const parsed = Number(raw.trim());
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

export const DEFAULT_DAILY_USAGE_CAPS: DailyUsageCaps = {
  messagesPerDay: capFromEnv(process.env.IRONBOI_MESSAGES_PER_DAY_CAP, 200),
  inputTokensPerDay: capFromEnv(process.env.IRONBOI_INPUT_TOKENS_PER_DAY_CAP, 1_000_000),
  outputTokensPerDay: capFromEnv(process.env.IRONBOI_OUTPUT_TOKENS_PER_DAY_CAP, 200_000),
  // Cloud TTS bills ~$30 per million characters, a spoken reply is 1–3
  // sentences (≈150–300 chars), and one call is capped at 600. 60k chars is
  // a few hundred spoken replies — far beyond a day of real use, and a hard
  // ceiling of ~$1.80 per account per day if someone scripts it.
  ttsCharsPerDay: capFromEnv(process.env.IRONBOI_TTS_CHARS_PER_DAY_CAP, 60_000),
};

export function usagePath(userId: string, dateKey: string) {
  return `${userRoot(userId)}/usage/${dateKey}`;
}

export function todayUtcDateKey(now = new Date()) {
  return now.toISOString().slice(0, 10);
}

export function normalizeDailyUsage(data: FirebaseFirestore.DocumentData | undefined): DailyUsage {
  return {
    messageCount: numberOrZero(data?.messageCount),
    inputTokens: numberOrZero(data?.inputTokens),
    outputTokens: numberOrZero(data?.outputTokens),
    ttsChars: numberOrZero(data?.ttsChars),
    capReached: data?.capReached === true,
  };
}

export function evaluateUsageCap(
  usage: DailyUsage,
  dateKey: string,
  caps: DailyUsageCaps = DEFAULT_DAILY_USAGE_CAPS,
): UsageCapCheck {
  if (usage.messageCount >= caps.messagesPerDay) {
    return { allowed: false, usage, dateKey, reason: "daily_message_cap" };
  }
  if (usage.inputTokens >= caps.inputTokensPerDay) {
    return { allowed: false, usage, dateKey, reason: "daily_input_token_cap" };
  }
  if (usage.outputTokens >= caps.outputTokensPerDay) {
    return { allowed: false, usage, dateKey, reason: "daily_output_token_cap" };
  }
  return { allowed: true, usage, dateKey };
}

export async function checkDailyUsageCap(
  db: Firestore,
  userId: string,
  now = new Date(),
  caps: DailyUsageCaps = DEFAULT_DAILY_USAGE_CAPS,
) {
  const dateKey = todayUtcDateKey(now);
  const snap = await db.doc(usagePath(userId, dateKey)).get();
  return evaluateUsageCap(normalizeDailyUsage(snap.data()), dateKey, caps);
}

export type TtsCapCheck =
  | { allowed: true; usage: DailyUsage; dateKey: string }
  | { allowed: false; usage: DailyUsage; dateKey: string; reason: "daily_tts_char_cap" };

/**
 * Spoken-reply cap. Separate from evaluateUsageCap on purpose: a user who
 * has talked all day should still get TEXT replies when the voice budget
 * runs out (the app falls back to the on-device voice), and the message
 * and token caps must not start failing because of audio.
 */
export function evaluateTtsCap(
  usage: DailyUsage,
  requestedChars: number,
  dateKey: string,
  caps: DailyUsageCaps = DEFAULT_DAILY_USAGE_CAPS,
): TtsCapCheck {
  if (usage.ttsChars + Math.max(0, requestedChars) > caps.ttsCharsPerDay) {
    return { allowed: false, usage, dateKey, reason: "daily_tts_char_cap" };
  }
  return { allowed: true, usage, dateKey };
}

export async function checkDailyTtsCap(
  db: Firestore,
  userId: string,
  requestedChars: number,
  now = new Date(),
  caps: DailyUsageCaps = DEFAULT_DAILY_USAGE_CAPS,
) {
  const dateKey = todayUtcDateKey(now);
  const snap = await db.doc(usagePath(userId, dateKey)).get();
  return evaluateTtsCap(normalizeDailyUsage(snap.data()), requestedChars, dateKey, caps);
}

export async function recordTtsUsage(
  db: Firestore,
  userId: string,
  dateKey: string,
  chars: number,
) {
  await db.doc(usagePath(userId, dateKey)).set(
    {
      ttsChars: FieldValue.increment(Math.max(0, Math.floor(chars))),
      serverUpdatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
}

export async function markDailyUsageCapReached(
  usageRef: DocumentReference,
  reason: UsageCapCheck extends infer T ? T extends { allowed: false; reason: infer R } ? R : never : never,
) {
  await usageRef.set(
    {
      capReached: true,
      capReason: reason,
      serverUpdatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
}

export async function recordCoachTurnUsage(
  db: Firestore,
  userId: string,
  dateKey: string,
  usage: { inputTokens: number; outputTokens: number },
) {
  await db.doc(usagePath(userId, dateKey)).set(
    {
      messageCount: FieldValue.increment(1),
      inputTokens: FieldValue.increment(Math.max(0, Math.floor(usage.inputTokens))),
      outputTokens: FieldValue.increment(Math.max(0, Math.floor(usage.outputTokens))),
      capReached: false,
      serverUpdatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
}

function numberOrZero(value: unknown) {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}
