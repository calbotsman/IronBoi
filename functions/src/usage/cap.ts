import type { DocumentReference, Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { userRoot } from "../paths.js";

export type DailyUsageCaps = {
  messagesPerDay: number;
  inputTokensPerDay: number;
  outputTokensPerDay: number;
};

export type DailyUsage = {
  messageCount: number;
  inputTokens: number;
  outputTokens: number;
  capReached: boolean;
};

export type UsageCapCheck =
  | { allowed: true; usage: DailyUsage; dateKey: string }
  | { allowed: false; usage: DailyUsage; dateKey: string; reason: "daily_message_cap" | "daily_input_token_cap" | "daily_output_token_cap" };

export const DEFAULT_DAILY_USAGE_CAPS: DailyUsageCaps = {
  messagesPerDay: Number(process.env.IRONBOI_MESSAGES_PER_DAY_CAP ?? 200),
  inputTokensPerDay: Number(process.env.IRONBOI_INPUT_TOKENS_PER_DAY_CAP ?? 1_000_000),
  outputTokensPerDay: Number(process.env.IRONBOI_OUTPUT_TOKENS_PER_DAY_CAP ?? 200_000),
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
