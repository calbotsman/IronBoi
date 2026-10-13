import { createRequire } from "node:module";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import {
  finishWorkoutSession,
  rateWorkoutSession,
  startWorkoutSession,
} from "../../../src/workouts/activeWorkout.js";
import { processOnboardingAnswer, selectPlanDays } from "../../../src/onboarding/flow.js";
import { profilePath, workoutLogPath, workoutPlanPath } from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

// The first day of the habit journey (docs/product/habit-journey-plan.md,
// Phase 1): a short starter session, a recap when it ends, and the answer
// to "how did that feel?".

const require = createRequire(import.meta.url);
const seed = require("../../../src/domain/ironlab-seed.json");

const USER_ID = "first-day-user-a";
const PLAN = {
  userId: USER_ID,
  planId: "current",
  source: "generated",
  days: {
    Mon: {
      name: "Full Body A",
      muscles: [],
      exercises: [
        { name: "Goblet Squat", sets: 3, reps: 10, weight: 35 },
        { name: "Bench Press", sets: 3, reps: 8, weight: 95 },
        { name: "Cable Row", sets: 3, reps: 10, weight: 70 },
        { name: "Plank", sets: 3, reps: 30, weight: 0 },
        { name: "Farmer Carry", sets: 3, reps: 40, weight: 50 },
      ],
    },
    Wed: { name: "Full Body B", muscles: [], exercises: [{ name: "Deadlift", sets: 3, reps: 5, weight: 135 }] },
  },
};

let app: App;
let db: Firestore;

type Started = Awaited<ReturnType<typeof startWorkoutSession>>;

/** Finish with every set done at the prescribed reps and weight (or `reps`). */
function finish(session: Started, completedAt: string, reps?: number) {
  return finishWorkoutSession(db, USER_ID, {
    sessionId: session.sessionId,
    completedAt,
    clientDate: completedAt.slice(0, 10),
    exercises: session.exercises.map((exercise) => ({
      ...exercise,
      exerciseDone: true,
      completedSets: exercise.completedSets.map((set) => ({ ...set, completed: true, reps: reps ?? set.reps })),
    })),
  });
}

describe("first day: starter session, recap, effort", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
    try {
      db.settings({ ignoreUndefinedProperties: true });
    } catch {
      // already configured by an earlier suite in this worker
    }
  });

  beforeEach(async () => {
    await db.recursiveDelete(db.doc(`users/${USER_ID}`));
    await db.doc(profilePath(USER_ID)).set({ ...baseProfile, userId: USER_ID });
    await db.doc(workoutPlanPath(USER_ID, "current")).set({ ...PLAN, createdAt: new Date().toISOString() });
  });

  afterAll(async () => {
    await db.recursiveDelete(db.doc(`users/${USER_ID}`));
    if (app && getApps().length && app.name !== "[DEFAULT]") await deleteApp(app);
  });

  it("trims the first-ever session to 4 moves × 2 sets, and only the first", async () => {
    const first = await startWorkoutSession(db, USER_ID, { dayKey: "Mon", planId: "current", starter: true }, PLAN);
    expect(first.exercises.map((e) => e.name)).toEqual(["Goblet Squat", "Bench Press", "Cable Row", "Plank"]);
    expect(first.exercises.every((e) => e.targetSets === 2 && e.completedSets.length === 2)).toBe(true);

    await finish(first, "2026-10-12T18:20:00.000Z");

    // Asking again once a workout is logged gets the normal day.
    const second = await startWorkoutSession(db, USER_ID, { dayKey: "Mon", planId: "current", starter: true }, PLAN);
    expect(second.exercises).toHaveLength(5);
    expect(second.exercises[0].targetSets).toBe(3);
  });

  it("a normal start is never trimmed", async () => {
    const session = await startWorkoutSession(db, USER_ID, { dayKey: "Mon", planId: "current" }, PLAN);
    expect(session.exercises).toHaveLength(5);
  });

  it("the first finish returns a recap, writes it to the conversation, and stamps firstWorkoutAt", async () => {
    const session = await startWorkoutSession(
      db, USER_ID, { dayKey: "Mon", planId: "current", starter: true, startedAt: "2026-10-12T18:00:00.000Z" }, PLAN,
    );
    const result = await finish(session, "2026-10-12T18:22:00.000Z");

    expect(result.recap?.firstWorkout).toBe(true);
    expect(result.recap?.lines).toEqual([
      "4 moves, 8 sets, 116 reps in 22 minutes.",
      "That's your starting point. I'll use today's numbers to set your weights.",
      "Next up: Full Body B, Wednesday.",
    ]);
    const message = await db.doc(`users/${USER_ID}/coachSessions/general/messages/recap_${session.sessionId}`).get();
    expect(message.get("role")).toBe("coach");
    expect(message.get("content")).toBe(result.recap?.lines.join(" "));
    expect((await db.doc(profilePath(USER_ID)).get()).get("firstWorkoutAt")).toBe("2026-10-12T18:22:00.000Z");
  });

  it("a later finish compares with earlier workouts", async () => {
    const first = await startWorkoutSession(db, USER_ID, { dayKey: "Mon", planId: "current" }, PLAN);
    await finish(first, "2026-10-12T18:22:00.000Z");
    const second = await startWorkoutSession(db, USER_ID, { dayKey: "Mon", planId: "current" }, PLAN);
    const result = await finish(second, "2026-10-14T18:22:00.000Z", 12);

    expect(result.recap?.firstWorkout).toBe(false);
    expect(result.recap?.lines[1]).toBe("Goblet Squat: 12 reps at 35 lb, 2 more reps than your best.");
    // firstWorkoutAt stays the first one.
    expect((await db.doc(profilePath(USER_ID)).get()).get("firstWorkoutAt")).toBe("2026-10-12T18:22:00.000Z");
  });

  it("saves 'how did that feel?' on the workout's log", async () => {
    const session = await startWorkoutSession(db, USER_ID, { dayKey: "Mon", planId: "current" }, PLAN);
    await finish(session, "2026-10-12T18:22:00.000Z");

    const rated = await rateWorkoutSession(db, USER_ID, { sessionId: session.sessionId, effort: "about_right" });
    expect(rated).toEqual({ rated: true, perceivedEffort: 6 });
    expect((await db.doc(workoutLogPath(USER_ID, session.sessionId)).get()).get("perceivedEffort")).toBe(6);

    // No log, nothing written.
    expect(await rateWorkoutSession(db, USER_ID, { sessionId: "nope", effort: "easy" })).toEqual({ rated: false });
    expect((await db.doc(workoutLogPath(USER_ID, "nope")).get()).exists).toBe(false);
  });

  it("the plan follows the training focus the user picked (not just days per week)", async () => {
    await db.recursiveDelete(db.doc(`users/${USER_ID}`));
    const result = await processOnboardingAnswer(
      db,
      USER_ID,
      {
        content: "",
        timestamp: "2026-10-12T18:00:00.000Z",
        inputMode: "text",
        structuredAnswer: {
          goals: ["muscle_gain"],
          trainingExperience: "intermediate",
          equipment: ["Full gym"],
          ageYears: "18–39",
          preferredDays: ["Mon", "Wed", "Fri"],
          injuriesOrLimitations: ["none"],
          // Not asked any more, but still honoured when given.
          trainingFocus: "muscle_split",
        },
      },
      seed.DEFAULT_PLAN,
    );
    expect(result.onboardingStatus).toBe("proposal_ready");
    const days = (result as { proposal: { workoutPlan: { days: Record<string, { name: string }> } } }).proposal.workoutPlan.days;
    const split = selectPlanDays(seed.DEFAULT_PLAN, 3, [], "muscle_split");
    const fullBody = selectPlanDays(seed.DEFAULT_PLAN, 3, [], "full_body");
    const names = (plan: Record<string, { name: string }>) => Object.values(plan).map((day) => day.name);
    // 3 days a week alone would have meant full body.
    expect(names(split)).not.toEqual(names(fullBody));
    expect(names(days)).toEqual(names(split));
  });
});
