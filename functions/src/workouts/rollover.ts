import type { Firestore, QueryDocumentSnapshot } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { safeLogger } from "../logging/safeLogger.js";
import { workoutPlanPath } from "../paths.js";
import { currentDateISO } from "./planAdjustments.js";
import {
  parseTrainingProgramDocument,
  syncCurrentWeekSnapshot,
  weekIndexForDate,
  type TrainingProgramType,
} from "./program.js";

// Week rollover — the job that brings weekIndexForDate/syncCurrentWeekSnapshot
// alive. Until this existed, a trainingPrograms/current doc's activeWeekIndex
// never advanced: a going_forward adjustment would patch weeks 1..N and the
// user would never see them, because workoutPlans/current stayed a snapshot
// of week 0 forever.
//
// Runs DAILY (not weekly) because users start programs on any weekday, so
// every user's week boundary lands on a different calendar day. For any
// program already on the right week the sweep is a pure no-op read.
//
// Idempotency: derived entirely from (startDate, today). A crashed or
// retried run re-computes the same expected index and converges. Per-doc
// write order is deliberate — snapshot sync first, activeWeekIndex flip
// LAST — so a failure between the two leaves expected !== activeWeekIndex
// and tomorrow's run (or the retry) redoes both. No parked/attempts
// bookkeeping is needed (unlike followups/sweep.ts): TrainingProgram is a
// strict schema with no room for status fields, a poison doc can't starve
// the rest (per-doc try/catch), and a chronic failure keeps logging daily
// instead of going silent.

// Keep at least this many materialized weeks AHEAD of the active week, so a
// going_forward adjustment always has a "next week" to cascade into.
const MIN_FUTURE_WEEKS = 2;
// Hard cap on the materialized array — a years-abandoned program must not
// grow an unbounded weeks array (Firestore 1MiB doc limit). Once at the cap,
// activeWeekIndex clamps to the last week and the snapshot keeps serving it.
const MAX_MATERIALIZED_WEEKS = 52;
// Page size for the collection-group scan. A bare scan (no filter/orderBy)
// needs no composite index; pagination keeps memory flat at any user count.
const SCAN_PAGE_SIZE = 300;

type RolloverOutcome = "rolled" | "current" | "corrupt";

export async function rolloverTrainingPrograms(db: Firestore, todayISO?: string) {
  const today = todayISO ?? currentDateISO();
  const now = new Date().toISOString();

  let scanned = 0;
  let rolled = 0;
  let current = 0;
  let corrupt = 0;
  let failed = 0;

  let cursor: QueryDocumentSnapshot | undefined;
  for (;;) {
    let query = db.collectionGroup("trainingPrograms").limit(SCAN_PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const page = await query.get();
    if (page.empty) break;

    for (const doc of page.docs) {
      scanned += 1;
      try {
        const outcome = await rolloverOneProgram(db, doc, today, now);
        if (outcome === "rolled") rolled += 1;
        else if (outcome === "current") current += 1;
        else corrupt += 1;
      } catch (error) {
        // One broken program must not starve every other user's rollover.
        failed += 1;
        safeLogger.warn("Training program rollover failed for one document", {
          event: "training_program_rollover_failed",
          userId: doc.ref.parent.parent?.id,
          programId: doc.id,
          errorDetail: error instanceof Error ? error.message.slice(0, 200) : "unknown_error",
        });
      }
    }

    if (page.size < SCAN_PAGE_SIZE) break;
    cursor = page.docs[page.docs.length - 1];
  }

  safeLogger.info("Training programs rolled over", {
    event: "training_programs_rolled_over",
    outcome: `rolled_${rolled}_current_${current}_corrupt_${corrupt}_failed_${failed}_of_${scanned}`,
  });
  return { scanned, rolled, current, corrupt, failed };
}

async function rolloverOneProgram(
  db: Firestore,
  doc: QueryDocumentSnapshot,
  today: string,
  now: string,
): Promise<RolloverOutcome> {
  // The PATH is authoritative for identity (same convention as
  // planAdjustments.ts): users/{uid}/trainingPrograms/{programId}. The
  // snapshot sync must land next to the program doc we just rolled, never
  // wherever a (possibly corrupt) userId field points.
  const userId = doc.ref.parent.parent?.id;

  let program: TrainingProgramType;
  try {
    program = parseTrainingProgramDocument(doc.data());
  } catch {
    // Corrupt doc: log the doc path (identifiers only, never values) and
    // skip. Deliberately no delete and no "repair" — a malformed program is
    // an investigation, not a cleanup target for a cron job.
    safeLogger.warn("Skipping malformed training program during rollover", {
      event: "training_program_rollover_corrupt",
      userId,
      programId: doc.id,
    });
    return "corrupt";
  }

  if (!userId) {
    safeLogger.warn("Skipping training program with no parent user during rollover", {
      event: "training_program_rollover_orphan_path",
      programId: doc.id,
    });
    return "corrupt";
  }

  if (program.weeks.length === 0) {
    // Schema-valid but unusable: nothing to activate and nothing to clone.
    safeLogger.warn("Skipping training program with no materialized weeks", {
      event: "training_program_rollover_empty_weeks",
      userId,
      programId: doc.id,
    });
    return "corrupt";
  }

  const expected = weekIndexForDate(program.startDate, today);
  if (expected === program.activeWeekIndex) {
    return "current";
  }

  // Extend the materialized range when the calendar has caught up with it:
  // clone the LAST week's days forward (the last week is the most recent
  // going_forward content, so it — not week 0 — is what "keep doing the
  // program" means), keeping MIN_FUTURE_WEEKS ahead of the new active week,
  // capped at MAX_MATERIALIZED_WEEKS total.
  let weeks = program.weeks;
  const lastWeek = weeks[weeks.length - 1];
  if (expected >= lastWeek.weekIndex && weeks.length < MAX_MATERIALIZED_WEEKS) {
    const targetLength = Math.min(
      MAX_MATERIALIZED_WEEKS,
      Math.max(weeks.length, expected + 1 + MIN_FUTURE_WEEKS),
    );
    weeks = [
      ...weeks,
      ...Array.from({ length: targetLength - weeks.length }, (_, offset) => ({
        weekIndex: lastWeek.weekIndex + 1 + offset,
        days: lastWeek.days,
      })),
    ];
  }

  // Clamp to the last materialized week (== weeks.length - 1 for the
  // contiguous arrays buildTrainingProgramFromDays produces). At the 52-week
  // cap this pins a long-abandoned program to its final week instead of
  // pointing activeWeekIndex at a week that doesn't exist.
  const nextActiveWeekIndex = Math.min(expected, weeks[weeks.length - 1].weekIndex);
  if (nextActiveWeekIndex === program.activeWeekIndex && weeks === program.weeks) {
    // Already clamped to the cap on a prior run — nothing left to change.
    return "current";
  }

  const nextProgram: TrainingProgramType = {
    ...program,
    weeks,
    activeWeekIndex: nextActiveWeekIndex,
    updatedAt: now,
  };

  // Write order matters for crash-retry safety: the snapshot sync and the
  // override prune run FIRST, and the activeWeekIndex flip lands LAST. If
  // anything fails partway, expected !== activeWeekIndex still holds and the
  // next run redoes the whole (idempotent) sequence — flipping the index
  // first would instead turn a half-applied rollover into a permanent
  // "no-op" wedge where the snapshot never resyncs.
  //
  // syncCurrentWeekSnapshot deliberately merge-writes only `days` (see its
  // comment in program.ts) — dailyOverrides on workoutPlans/current survive.
  await syncCurrentWeekSnapshot(db, userId, nextProgram, now);
  await prunePastDailyOverrides(db, userId, today);
  await doc.ref.set(
    {
      weeks: nextProgram.weeks,
      activeWeekIndex: nextProgram.activeWeekIndex,
      updatedAt: now,
      serverUpdatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  safeLogger.info("Training program rolled to the current week", {
    event: "training_program_rolled",
    userId,
    programId: doc.id,
    outcome: `week_${program.activeWeekIndex}_to_${nextActiveWeekIndex}`,
  });
  return "rolled";
}

// Housekeeping on the same rollover pass: dailyOverrides are date-keyed
// temporary changes that expire naturally (resolution is overrides[D] else
// days[weekdayOf(D)]), so past-dated keys are dead weight. Prune strictly
// past dates only — today's override is still live until midnight.
async function prunePastDailyOverrides(db: Firestore, userId: string, today: string) {
  const planRef = db.doc(workoutPlanPath(userId, "current"));
  const planSnap = await planRef.get();
  const overrides = planSnap.exists ? planSnap.data()?.dailyOverrides : undefined;
  if (!isRecord(overrides)) return;

  const deleteMarkers = Object.fromEntries(
    Object.keys(overrides)
      .filter((date) => date < today)
      .map((date) => [date, FieldValue.delete()]),
  );
  // An EXPLICITLY EMPTY map in set(merge:true) replaces the whole map —
  // when nothing is due for deletion, don't touch the field at all (same
  // rule as planAdjustments.ts's clear_overrides handling).
  if (Object.keys(deleteMarkers).length === 0) return;

  await planRef.set(
    {
      dailyOverrides: deleteMarkers,
      serverUpdatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
