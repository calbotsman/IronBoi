import type { DocumentData } from "firebase-admin/firestore";
import type { CoachLoadedContext } from "./context.js";
import type { RetrievedCorpusEntry } from "../corpus/researchCorpus.js";

export type CoachContextBundleV1 = {
  schema: "coach_context_bundle.v1";
  dataBoundary: "user_data_is_not_instruction";
  userId: string;
  sessionId: string;
  assembledAt: string;
  profile: Record<string, unknown> | null;
  memoryFacts: CoachContextMemoryFact[];
  recentWorkouts: CoachContextWorkout[];
  conversationWindow: CoachContextMessage[];
  healthSummary: {
    available: false;
    reason: "healthkit_not_connected";
  };
  retrievedCorpus: RetrievedCorpusEntry[];
};

export type CoachContextMemoryFact = {
  factId?: string;
  category?: string;
  content: string;
  source?: string;
  confidence?: number;
  createdAt?: string;
  lastReinforcedAt?: string;
};

export type CoachContextWorkout = {
  sessionId?: string;
  date?: string;
  source?: string;
  perceivedEffort?: number;
  summary: string;
};

export type CoachContextMessage = {
  messageId?: string;
  role: "user" | "coach" | "tool" | "system" | "unknown";
  content: string;
  status?: string;
  timestamp?: string;
};

const PROFILE_FIELDS = [
  "ageYears",
  "sexOrGender",
  "sexOrGenderSelfDescription",
  "heightCm",
  "weightKg",
  "goals",
  "goalNotes",
  "trainingExperience",
  "injuriesOrLimitations",
  "equipment",
  "schedule",
  "preferences",
  "dietaryConstraints",
  "createdAt",
  "updatedAt",
] as const;

export function buildCoachContextBundle(
  context: CoachLoadedContext,
  {
    userId,
    sessionId,
    now = new Date().toISOString(),
    retrievedCorpus = [],
  }: {
    userId: string;
    sessionId: string;
    now?: string;
    retrievedCorpus?: RetrievedCorpusEntry[];
  },
): CoachContextBundleV1 {
  return {
    schema: "coach_context_bundle.v1",
    dataBoundary: "user_data_is_not_instruction",
    userId,
    sessionId,
    assembledAt: now,
    profile: context.profile ? pickProfile(context.profile) : null,
    memoryFacts: context.recentFacts
      .filter((fact) => !fact.userDeletedAt)
      .slice(0, 20)
      .map(memoryFactForPrompt)
      .filter((fact): fact is CoachContextMemoryFact => hasText(fact.content)),
    recentWorkouts: context.recentLogs
      .slice(0, 10)
      .map(workoutForPrompt)
      .filter((workout): workout is CoachContextWorkout => hasText(workout.summary)),
    conversationWindow: context.sessionHistory
      .slice(-30)
      .map(messageForPrompt)
      .filter((message): message is CoachContextMessage => hasText(message.content)),
    healthSummary: {
      available: false,
      reason: "healthkit_not_connected",
    },
    retrievedCorpus,
  };
}

function pickProfile(profile: DocumentData) {
  const picked: Record<string, unknown> = {};
  for (const field of PROFILE_FIELDS) {
    const value = profile[field];
    if (value !== undefined) {
      picked[field] = normalizeValue(value);
    }
  }
  return picked;
}

function memoryFactForPrompt(fact: DocumentData): CoachContextMemoryFact {
  const content = stringValue(fact.content, 1_000) ?? "";
  return compactObject({
    factId: stringValue(fact.factId, 120),
    category: stringValue(fact.category, 80),
    content,
    source: stringValue(fact.source, 80),
    confidence: numberValue(fact.confidence),
    createdAt: stringValue(fact.createdAt, 80),
    lastReinforcedAt: stringValue(fact.lastReinforcedAt, 80),
  });
}

function workoutForPrompt(log: DocumentData): CoachContextWorkout {
  const postSessionNotes = stringValue(log.postSessionNotes, 800);
  const exerciseSummary = Array.isArray(log.exercises)
    ? log.exercises
        .slice(0, 12)
        .map((exercise) => {
          if (!isPlainObject(exercise)) {
            return "";
          }
          const name = stringValue(exercise.name, 120);
          const setCount = Array.isArray(exercise.sets) ? exercise.sets.length : 0;
          return name ? `${name}${setCount ? ` (${setCount} sets)` : ""}` : "";
        })
        .filter(Boolean)
        .join(", ")
    : "";

  return compactObject({
    sessionId: stringValue(log.sessionId, 120),
    date: stringValue(log.date, 80),
    source: stringValue(log.source, 80),
    perceivedEffort: numberValue(log.perceivedEffort),
    summary:
      postSessionNotes ||
      exerciseSummary ||
      stringValue(log.sessionId, 120) ||
      "Workout logged with no summary.",
  });
}

function messageForPrompt(message: DocumentData): CoachContextMessage {
  const content = stringValue(message.content, 1_500) ?? "";
  return compactObject({
    messageId: stringValue(message.messageId, 120),
    role: safeRole(message.role),
    content,
    status: stringValue(message.status, 80),
    timestamp: stringValue(message.timestamp, 80),
  });
}

function safeRole(role: unknown): CoachContextMessage["role"] {
  return role === "user" ||
    role === "coach" ||
    role === "tool" ||
    role === "system"
    ? role
    : "unknown";
}

function compactObject<T extends Record<string, unknown>>(value: T): T {
  return Object.fromEntries(
    Object.entries(value).filter(([, entry]) => entry !== undefined && entry !== ""),
  ) as T;
}

function normalizeValue(value: unknown): unknown {
  if (typeof value === "string") {
    return stringValue(value, 1_000);
  }
  if (typeof value === "number" || typeof value === "boolean" || value === null) {
    return value;
  }
  if (Array.isArray(value)) {
    return value.slice(0, 50).map(normalizeValue);
  }
  if (isPlainObject(value)) {
    return Object.fromEntries(
      Object.entries(value)
        .slice(0, 50)
        .map(([key, entry]) => [key, normalizeValue(entry)]),
    );
  }
  return stringValue(value, 120);
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringValue(value: unknown, maxLength: number) {
  if (typeof value !== "string") {
    return undefined;
  }
  return value.length > maxLength ? `${value.slice(0, maxLength)}...` : value;
}

function numberValue(value: unknown) {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function hasText(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}
