// Progression events (docs/plans/myo-training-intelligence.md S1).
//
// Every change to what a lift is prescribed at gets one small doc at
// users/{uid}/progressionEvents/{eventId}, with plain words for why. History
// shows the timeline from them ("rows went up 5, you hit every rep") and the
// coach reads the latest one per lift. Holds are written too: "why didn't my
// weight move?" is the question the timeline exists to answer.
//
// Ids are deterministic so a retried finish or rollover overwrites its own
// event instead of adding a second one.

import type { Firestore, WriteBatch, Transaction } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import {
  ProgressionEvent,
  type ProgressionEvent as ProgressionEventType,
  type ProgressionEventKind,
} from "../contracts/coach-agent.js";
import { progressionEventPath } from "../paths.js";
import { normalizeExerciseKey } from "./exerciseCatalog.js";

const MAX_EVENT_ID = 200;

/**
 * `${scope}_${kind}_${exerciseKey}`: scope is the session id for events a
 * finished workout causes (one per session per lift), else the date (one per
 * rollover day or approval day per lift).
 */
export function progressionEventId(scope: string, kind: ProgressionEventKind, exerciseKey: string): string {
  // Firestore ids can't hold "/"; session ids never do, but the date/key
  // parts are ours and the slice keeps the contract's 200-char bound.
  return `${scope}_${kind}_${exerciseKey}`.replace(/\//g, "_").slice(0, MAX_EVENT_ID);
}

export function progressionEventDoc(input: {
  userId: string;
  scope: string;
  kind: ProgressionEventKind;
  exerciseName: string;
  date: string;
  fromLb: number;
  toLb: number;
  reason: string;
  sessionId?: string;
  now: string;
}): ProgressionEventType {
  const exerciseKey = normalizeExerciseKey(input.exerciseName);
  return ProgressionEvent.parse({
    userId: input.userId,
    eventId: progressionEventId(input.scope, input.kind, exerciseKey),
    exerciseKey: exerciseKey.slice(0, 120),
    exerciseName: input.exerciseName.trim().slice(0, 80),
    date: input.date,
    kind: input.kind,
    fromLb: clampLb(input.fromLb),
    toLb: clampLb(input.toLb),
    reason: input.reason.slice(0, 160),
    ...(input.sessionId ? { sessionId: input.sessionId } : {}),
    createdAt: input.now,
  });
}

/** Adds the event to a batch or transaction the caller is already committing. */
export function writeProgressionEvent(
  db: Firestore,
  writer: WriteBatch | Transaction,
  event: ProgressionEventType,
) {
  const ref = db.doc(progressionEventPath(event.userId, event.eventId));
  const data = { ...event, serverUpdatedAt: FieldValue.serverTimestamp() };
  // Batch and transaction share set()'s shape; the union just isn't callable.
  (writer as WriteBatch).set(ref, data);
}

/** "35", "37.5": how weights read in a reason. */
export function lbText(pounds: number): string {
  return Number.isInteger(pounds) ? String(pounds) : pounds.toFixed(1);
}

function clampLb(pounds: number): number {
  return Math.min(2000, Math.max(0, Math.round(pounds * 2) / 2));
}
