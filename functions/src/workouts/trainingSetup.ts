import { createRequire } from "node:module";
import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { z } from "zod";
import { GoalType, PlannedWorkoutDay, TrainingExperience, TrainingFocus } from "../contracts/coach-agent.js";
import { buildWorkoutPlanFromProfile } from "../onboarding/flow.js";
import { profilePath, workoutPlanPath } from "../paths.js";
import { recordAuditEventBestEffort } from "../audit/log.js";
import { writeRegeneratedPlanAndProgram } from "./program.js";

// The six things onboarding asks, changed later — from the You screen or by
// saying it to the coach ("4 days a week now, I've got kettlebells, building
// muscle"). One path for both, so tapping and talking can't disagree: save the
// answers on the profile, then rebuild the plan from them.

const require = createRequire(import.meta.url);
const seed = require("../domain/ironlab-seed.json") as {
  DEFAULT_PLAN: Record<string, z.infer<typeof PlannedWorkoutDay>>;
};

const WEEK = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] as const;

export const TrainingSetupChange = z
  .object({
    goals: z.array(GoalType).min(1).max(3).optional(),
    trainingExperience: TrainingExperience.optional(),
    /** In the user's words, as onboarding takes it: "kettlebells", "full gym". */
    equipment: z.array(z.string().trim().min(1).max(60)).min(1).max(12).optional(),
    /** Which days. Wins over daysPerWeek when both are given. */
    preferredDays: z.array(z.enum(WEEK)).min(1).max(7).optional(),
    daysPerWeek: z.number().int().min(1).max(7).optional(),
    sessionLengthMin: z.number().int().min(15).max(120).optional(),
    /** "HH:MM", 24h — the training-day reminder time on the phone. */
    preferredTime: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/).optional(),
  })
  .strict()
  .refine((change) => Object.values(change).some((value) => value !== undefined), {
    message: "nothing_to_change",
  });
export type TrainingSetupChange = z.infer<typeof TrainingSetupChange>;

// Fields that change what the plan should be. Session length and the reminder
// time are saved but don't need a new plan.
const PLAN_FIELDS = ["goals", "trainingExperience", "equipment", "preferredDays", "daysPerWeek"] as const;

export async function updateTrainingSetup(
  db: Firestore,
  userId: string,
  change: TrainingSetupChange,
  actor: "user" | "coach",
) {
  const now = new Date().toISOString();
  const profileRef = db.doc(profilePath(userId));
  const current = (await profileRef.get()).data() ?? {};
  const schedule = { ...(current.schedule ?? {}) } as {
    daysPerWeek?: number;
    preferredDays?: string[];
    sessionLengthMin?: number;
  };

  if (change.preferredDays) {
    const days = WEEK.filter((day) => change.preferredDays!.includes(day));
    schedule.preferredDays = days;
    schedule.daysPerWeek = days.length;
  } else if (change.daysPerWeek !== undefined) {
    schedule.daysPerWeek = change.daysPerWeek;
    // Their old days only still apply if there are exactly that many of them;
    // otherwise the plan builder spreads the new count across the week.
    if ((schedule.preferredDays ?? []).length !== change.daysPerWeek) schedule.preferredDays = [];
  }
  if (change.sessionLengthMin !== undefined) schedule.sessionLengthMin = change.sessionLengthMin;

  const patch: Record<string, unknown> = {
    schedule,
    updatedAt: now,
    serverUpdatedAt: FieldValue.serverTimestamp(),
  };
  if (change.goals) patch.goals = change.goals;
  if (change.trainingExperience) patch.trainingExperience = change.trainingExperience;
  if (change.equipment) patch.equipment = change.equipment;
  if (change.preferredTime) {
    patch.preferredTime = change.preferredTime;
    const hour = Number(change.preferredTime.slice(0, 2));
    patch.preferences = { preferredWorkoutTime: hour < 11 ? "morning" : hour < 16 ? "afternoon" : "evening" };
  }
  await profileRef.set(patch, { merge: true });

  const changed = Object.entries(change).filter(([, value]) => value !== undefined).map(([key]) => key);
  const rebuild = PLAN_FIELDS.some((field) => change[field] !== undefined);
  let trainingDays: string[] = currentTrainingDays((await db.doc(workoutPlanPath(userId)).get()).get("days"));
  let keptAdjustments = 0;

  if (rebuild) {
    const focus = TrainingFocus.safeParse(current.preferences?.trainingFocus ?? current.trainingFocus);
    const experience = TrainingExperience.safeParse(change.trainingExperience ?? current.trainingExperience);
    const plan = buildWorkoutPlanFromProfile(
      userId,
      {
        schedule: { daysPerWeek: schedule.daysPerWeek ?? 3, preferredDays: schedule.preferredDays ?? [] },
        trainingFocus: focus.success ? focus.data : undefined,
        equipment: change.equipment ?? (Array.isArray(current.equipment) ? current.equipment : undefined),
        trainingExperience: experience.success ? experience.data : undefined,
      },
      seed.DEFAULT_PLAN,
      now,
    );

    // Adjustments still ahead (an injury week, a back-safe day) are kept: a
    // new schedule must never quietly undo a safety change.
    const planRef = db.doc(workoutPlanPath(userId));
    const overrides = ((await planRef.get()).get("dailyOverrides") ?? {}) as Record<string, unknown>;
    const today = now.slice(0, 10);
    const upcoming = Object.fromEntries(Object.entries(overrides).filter(([date]) => date >= today));
    keptAdjustments = Object.keys(upcoming).length;

    await writeRegeneratedPlanAndProgram(db, userId, plan.days, now);
    if (keptAdjustments > 0) await planRef.set({ dailyOverrides: upcoming }, { merge: true });
    trainingDays = currentTrainingDays(plan.days);
  }

  await recordAuditEventBestEffort(db, {
    userId,
    eventType: "training_setup_changed",
    actor,
    payload: { changed, rebuilt: rebuild, daysPerWeek: trainingDays.length },
  });

  return { ok: true as const, changed, rebuiltPlan: rebuild, trainingDays, keptAdjustments };
}

function currentTrainingDays(days: unknown): string[] {
  if (!days || typeof days !== "object") return [];
  const map = days as Record<string, { exercises?: unknown[] }>;
  return WEEK.filter((day) => Array.isArray(map[day]?.exercises) && map[day]!.exercises!.length > 0);
}
