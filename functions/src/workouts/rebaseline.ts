// Committing the weights a user actually lifted as their new baselines.
//
// Called only from the finish-workout card the user taps "Apply" on — the
// suggestions themselves come from deriveBaselineSuggestions and write
// nothing. This is the write half.
//
// It does two things that have to happen together:
//   1. Move the anchor (users/{uid}/exerciseBaselines/{key}) to the weight
//      that was worked, with anchorDate = today so any progression protocol
//      restarts its clock from the new number rather than immediately
//      re-applying weeks of accumulated increase on top of it.
//   2. Rewrite the prescribed weight everywhere the user will READ it —
//      workoutPlans/current and the program's current-and-future weeks. The
//      Train tab reads those docs straight from a snapshot listener, so an
//      anchor that didn't reach them would leave the app showing 60 lb for a
//      lift the user just rebaselined to 30.

import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { recordAuditEventBestEffort } from "../audit/log.js";
import { safeLogger } from "../logging/safeLogger.js";
import { trainingProgramPath, workoutPlanPath, workoutSessionPath } from "../paths.js";
import { normalizeExerciseKey } from "./exerciseCatalog.js";
import {
  baselineDocFor,
  baselinePropagation,
  baselineRefFor,
  loadBaselines,
  type ApplyExerciseBaselinesRequestType,
  type BaselineMap,
} from "./exerciseBaselines.js";
import { currentDateISO } from "./planAdjustments.js";
import { ensureTrainingProgram, parseTrainingProgramDocument } from "./program.js";

export async function applyExerciseBaselines(
  db: Firestore,
  userId: string,
  request: ApplyExerciseBaselinesRequestType,
) {
  const today = request.clientDate ?? currentDateISO();
  const now = new Date().toISOString();

  const sessionRef = db.doc(workoutSessionPath(userId, request.sessionId));
  const planRef = db.doc(workoutPlanPath(userId, "current"));
  const programRef = db.doc(trainingProgramPath(userId));

  // Hoisted for the same reason acceptPlanAdjustmentProposal hoists it: the
  // legacy backfill writes, and a transaction cannot write before its reads.
  await ensureTrainingProgram(db, userId);

  const applied = await db.runTransaction(async (transaction) => {
    const [sessionSnap, planSnap, programSnap] = await Promise.all([
      transaction.get(sessionRef),
      transaction.get(planRef),
      transaction.get(programRef),
    ]);

    if (!sessionSnap.exists) throw new Error("workout_session_not_found");
    const sessionData = sessionSnap.data() ?? {};
    if (sessionData.userId !== userId) throw new Error("workout_session_user_mismatch");

    // The session is the evidence. Anchoring an exercise the user never
    // performed in it would let a client post arbitrary working weights that
    // the coach and every future prescription then treat as demonstrated.
    const performed = new Map<string, number>();
    if (Array.isArray(sessionData.exercises)) {
      for (const exercise of sessionData.exercises) {
        if (!isRecord(exercise) || typeof exercise.name !== "string") continue;
        const completed = Array.isArray(exercise.completedSets)
          ? exercise.completedSets.filter((set) => isRecord(set) && set.completed === true).length
          : 0;
        performed.set(normalizeExerciseKey(exercise.name), completed);
      }
    }

    const accepted: Array<{ exerciseName: string; weightLb: number }> = [];
    for (const entry of request.baselines) {
      const key = normalizeExerciseKey(entry.exerciseName);
      const completedSets = performed.get(key);
      if (completedSets === undefined) {
        throw new Error("exercise_baseline_not_in_session");
      }
      // Zero completed sets means the exercise was skipped. Whatever number
      // was staged on its stepper was never lifted, so it is not evidence of
      // anything and must not become the anchor.
      if (completedSets === 0) continue;
      accepted.push(entry);
    }

    if (accepted.length === 0) {
      return [] as Array<{ exerciseName: string; weightLb: number }>;
    }

    // Merge the new anchors over the existing ones before recomputing the
    // plan, so a day holding two rebaselined exercises gets both.
    const baselines: BaselineMap = new Map(
      (await loadBaselines(db, userId)).entries(),
    );
    for (const entry of accepted) {
      const doc = baselineDocFor(
        userId,
        entry.exerciseName,
        entry.weightLb,
        today,
        "user_session",
        now,
        request.sessionId,
      );
      baselines.set(doc.exerciseKey, doc);
      transaction.set(
        baselineRefFor(db, userId, entry.exerciseName),
        { ...doc, serverUpdatedAt: FieldValue.serverTimestamp() },
        { merge: true },
      );
    }

    // --- Propagate to what the user reads ------------------------------
    const { planDays: patchedDays, programWeeks } = baselinePropagation(
      planSnap.data(),
      programSnap.exists ? parseTrainingProgramDocument(programSnap.data()) : undefined,
      baselines,
      today,
    );
    if (patchedDays) {
      transaction.set(
        planRef,
        {
          days: patchedDays,
          source: "user_edited",
          updatedAt: now,
          serverUpdatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    }
    if (programWeeks) {
      transaction.set(
        programRef,
        {
          weeks: programWeeks,
          source: "user_edited",
          updatedAt: now,
          serverUpdatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    }

    return accepted;
  });

  if (applied.length > 0) {
    await recordAuditEventBestEffort(db, {
      userId,
      eventType: "exercise_baseline_rebaselined",
      actor: "user",
      payload: { sessionId: request.sessionId, exercises: applied },
    });
  }

  safeLogger.info("Exercise baselines applied", {
    event: "exercise_baselines_applied",
    userId,
    outcome: `applied_${applied.length}_of_${request.baselines.length}`,
  });

  return {
    ok: true as const,
    applied: applied.map((entry) => entry.exerciseName),
    skipped: request.baselines.length - applied.length,
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
