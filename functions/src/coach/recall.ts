import type { DocumentData, Firestore } from "firebase-admin/firestore";
import { userRoot } from "../paths.js";
import { normalizeExerciseKey } from "../workouts/exerciseCatalog.js";

/**
 * Deep recall: "what did I bench last spring?" — a structured look-up over
 * the user's own workoutLogs, only when the coach asks for it. The memory
 * brief (memoryBrief.ts) covers the recent picture; this reaches back
 * further. Dates and exercise names are enough for the questions people
 * ask about their training, so no vector search: see the PR for why.
 */
const SCAN_MAX = 200;
const SESSIONS_MAX = 20;
const LB_PER_KG = 2.20462;

export type RecallArgs = {
  exerciseName?: string;
  from?: string;
  to?: string;
  limit?: number;
};

type RecalledSet = { reps?: number; lb?: number; seconds?: number };
type RecalledExercise = { name: string; sets: RecalledSet[] };
type RecalledSession = { date: string; exercises: RecalledExercise[]; perceivedEffort?: number; notes?: string };

/** Matches "bench" to "Barbell Bench Press" and "DB bench" to "DB Bench Press": every word of the query, in any order. */
function stem(word: string): string {
  if (word.endsWith("sses")) return word.slice(0, -2);
  if (word.endsWith("ss")) return word;
  return word.replace(/s$/, "");
}

export function exerciseMatches(query: string, name: string): boolean {
  const want = normalizeExerciseKey(query).split("_").filter(Boolean).map(stem);
  const have = new Set(normalizeExerciseKey(name).split("_").map(stem));
  return want.length > 0 && want.every((word) => have.has(word));
}

function setsOf(exercise: DocumentData): RecalledSet[] {
  return (Array.isArray(exercise.sets) ? exercise.sets : [])
    .filter((set: unknown): set is Record<string, unknown> => typeof set === "object" && set !== null)
    .map((set: Record<string, unknown>) => {
      const out: RecalledSet = {};
      if (typeof set.reps === "number") out.reps = set.reps;
      if (typeof set.loadKg === "number" && set.loadKg > 0) out.lb = Math.round(set.loadKg * LB_PER_KG);
      if (typeof set.durationSec === "number") out.seconds = set.durationSec;
      return out;
    });
}

export async function recallTrainingHistory(db: Firestore, userId: string, args: RecallArgs) {
  if (args.from && args.to && args.from > args.to) {
    return { ok: false, error: "from_after_to", hint: "`from` must be on or before `to`." };
  }
  let query = db.collection(`${userRoot(userId)}/workoutLogs`).orderBy("date", "desc");
  if (args.from) query = query.where("date", ">=", args.from);
  if (args.to) query = query.where("date", "<=", args.to);
  const snap = await query.limit(SCAN_MAX).get();

  const limit = Math.min(args.limit ?? 10, SESSIONS_MAX);
  const matched: RecalledSession[] = [];
  let best: { date: string; exercise: string; lb: number; reps?: number } | null = null;
  for (const doc of snap.docs) {
    const log = doc.data();
    if (typeof log.date !== "string") continue;
    const exercises = (Array.isArray(log.exercises) ? log.exercises : [])
      .filter((exercise: DocumentData) => typeof exercise?.name === "string")
      .filter((exercise: DocumentData) => !args.exerciseName || exerciseMatches(args.exerciseName, exercise.name))
      .map((exercise: DocumentData) => ({ name: String(exercise.name).slice(0, 120), sets: setsOf(exercise) }));
    if (exercises.length === 0) continue;
    for (const exercise of exercises) {
      for (const set of exercise.sets) {
        if (set.lb !== undefined && (!best || set.lb > best.lb)) best = { date: log.date, exercise: exercise.name, lb: set.lb, reps: set.reps };
      }
    }
    if (matched.length < limit) {
      matched.push({
        date: log.date,
        exercises,
        ...(typeof log.perceivedEffort === "number" ? { perceivedEffort: log.perceivedEffort } : {}),
        ...(typeof log.postSessionNotes === "string" && log.postSessionNotes ? { notes: log.postSessionNotes.slice(0, 200) } : {}),
      });
    }
  }
  const sessionsFound = snap.docs.filter((doc) => {
    const log = doc.data();
    return (Array.isArray(log.exercises) ? log.exercises : []).some(
      (exercise: DocumentData) => typeof exercise?.name === "string" && (!args.exerciseName || exerciseMatches(args.exerciseName, exercise.name)),
    );
  }).length;

  return {
    ok: true,
    searched: { exerciseName: args.exerciseName ?? null, from: args.from ?? null, to: args.to ?? null, logsScanned: snap.size, scanCapped: snap.size === SCAN_MAX },
    sessionsFound,
    heaviest: best,
    // Newest first.
    sessions: matched,
    ...(sessionsFound === 0
      ? { hint: "No logged sessions match. Say so plainly; don't guess numbers. Sessions are logged when they finish a workout in the app." }
      : {}),
  };
}
