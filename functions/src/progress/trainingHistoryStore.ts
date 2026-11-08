// Training history — storage side of the pure builder (progress/trainingHistory.ts).
//
// writeTrainingHistory loads about a year of workout logs, the plan, the
// program, anchors, progression events and the profile, runs the builder,
// and overwrites users/{uid}/derivedSummaries/training_history (server-only
// write; owner reads, the app listens to it).
//
// Rebuilt at the end of every finished workout (activeWorkout.ts), and
// lazily: refreshTrainingHistoryIfStale is what the workout-log trigger, the
// coach's context load and the app's refresh call use. The doc is about "this
// week" and "today", so it goes stale on the clock as well as on new data:
// older than an hour, or built for a different local date, means rebuild.

import type { DocumentData, Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import type { TrainingHistory } from "../contracts/coach-agent.js";
import {
  profilePath,
  progressionEventsCollection,
  trainingHistoryPath,
  trainingProgramPath,
  userRoot,
  workoutPlanPath,
} from "../paths.js";
import { loadBaselines } from "../workouts/exerciseBaselines.js";
import { addDays, buildTrainingHistory, HISTORY_WEEKS, normalizeSessions, type Session } from "./trainingHistory.js";
import { safeLogger } from "../logging/safeLogger.js";

export const TRAINING_HISTORY_MAX_AGE_MS = 60 * 60 * 1_000;
// A year of training for one person sits well below these; they keep a
// pathological account's rebuild bounded.
const MAX_LOGS = 500;
const MAX_EVENTS = 400;

export type TrainingHistoryBuild = {
  history: TrainingHistory;
  // Every log the build saw, normalized (oldest first), so the finish
  // recap can reuse them instead of reading again.
  sessions: Session[];
};

export async function writeTrainingHistory(
  db: Firestore,
  userId: string,
  today: string,
  now = new Date(),
): Promise<TrainingHistoryBuild> {
  // One extra day of slack: localDate can sit a day before the UTC date.
  const since = addDays(today, -7 * HISTORY_WEEKS - 1);
  const [logsSnap, planSnap, programSnap, profileSnap, baselines, eventsSnap] = await Promise.all([
    db.collection(`${userRoot(userId)}/workoutLogs`).where("date", ">=", since).orderBy("date", "desc").limit(MAX_LOGS).get(),
    db.doc(workoutPlanPath(userId, "current")).get(),
    db.doc(trainingProgramPath(userId)).get(),
    db.doc(profilePath(userId)).get(),
    loadBaselines(db, userId),
    // Events are History's "why"; a failed read costs the timeline, never the doc.
    db.collection(progressionEventsCollection(userId)).orderBy("date", "desc").limit(MAX_EVENTS).get()
      .then((snap) => snap.docs.map((doc) => doc.data()))
      .catch(() => [] as DocumentData[]),
  ]);
  // Newest MAX_LOGS (desc), back in date order for the builder.
  const logs = logsSnap.docs.map((doc) => doc.data()).reverse();
  const history = buildTrainingHistory({
    userId,
    today,
    now: now.toISOString(),
    logs,
    plan: planSnap.exists ? planSnap.data() ?? null : null,
    program: programSnap.exists ? programSnap.data() ?? null : null,
    baselines,
    events: eventsSnap,
    profile: profileSnap.exists ? profileSnap.data() ?? null : null,
  });
  // Full overwrite: the doc is entirely derived.
  await db.doc(trainingHistoryPath(userId)).set({ ...history, serverUpdatedAt: FieldValue.serverTimestamp() });
  return { history, sessions: normalizeSessions(logs) };
}

export function trainingHistoryIsFresh(data: DocumentData | undefined | null, today: string, now = new Date()): boolean {
  if (!data || data.today !== today || typeof data.computedAt !== "string") return false;
  const age = now.getTime() - Date.parse(data.computedAt);
  // A doc "from the future" (clock skew) counts as fresh: never a rebuild storm.
  return Number.isFinite(age) && age < TRAINING_HISTORY_MAX_AGE_MS;
}

/**
 * The stored doc when it's fresh for `today`, else a rebuilt one. Never
 * throws: on a failed rebuild it returns whatever is stored (or null), so
 * callers on a coach turn or a trigger can't be taken down by it.
 */
export async function refreshTrainingHistoryIfStale(
  db: Firestore,
  userId: string,
  today: string,
  now = new Date(),
): Promise<{ history: DocumentData | null; rebuilt: boolean }> {
  const stored = await db.doc(trainingHistoryPath(userId)).get().then((snap) => (snap.exists ? snap.data() ?? null : null)).catch(() => null);
  if (trainingHistoryIsFresh(stored, today, now)) return { history: stored, rebuilt: false };
  try {
    const { history } = await writeTrainingHistory(db, userId, today, now);
    return { history, rebuilt: true };
  } catch (error) {
    logTrainingHistoryFailure(userId, "refresh", error);
    return { history: stored, rebuilt: false };
  }
}

export function logTrainingHistoryFailure(userId: string, trigger: string, error: unknown) {
  safeLogger.warn("Training history rebuild failed", {
    event: "training_history_rebuild_failed",
    userId,
    trigger,
    errorCode: error instanceof Error ? error.name : "unknown_error",
    errorDetail: error instanceof Error ? error.message.slice(0, 180) : "unknown_error",
  });
}

