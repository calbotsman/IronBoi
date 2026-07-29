import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";

initializeApp();

const firestore = getFirestore();

// Firestore REJECTS undefined values by default — `.set()` throws rather than
// skipping the key. Every contract in contracts/coach-agent.ts is full of
// `.optional()` fields, and Zod keeps an optional key whose value is
// explicitly undefined, so any code path that builds a document from optional
// inputs and writes it is one absent field away from a hard failure.
//
// That is not theoretical: finishWorkoutSession wrote `durationSec`,
// `perceivedEffort`, `postSessionNotes`, per-set `loadKg` (bodyweight sets) and
// per-set `notes` straight through, so finishing a workout without notes — or
// with a single push-up set — threw at the write and the user's session could
// not be saved.
//
// Ignoring undefined makes an omitted optional field mean "absent", which is
// what every one of those schemas already intends.
firestore.settings({ ignoreUndefinedProperties: true });

export const db = firestore;
export const auth = getAuth();
