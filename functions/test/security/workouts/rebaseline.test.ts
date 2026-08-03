import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import {
  finishWorkoutSession,
  startWorkoutSession,
} from "../../../src/workouts/activeWorkout.js";
import { applyExerciseBaselines } from "../../../src/workouts/rebaseline.js";
import { rolloverTrainingPrograms } from "../../../src/workouts/rollover.js";
import {
  exerciseBaselinePath,
  trainingProgramPath,
  workoutPlanPath,
} from "../../../src/paths.js";

const USER_ID = "exercise-rebaseline-user-a";
const TODAY = "2026-08-03"; // a Monday
const NOW = "2026-08-03T12:00:00.000Z";

let app: App;
let db: Firestore;

// The scenario from the request: the plan prescribes 60 lb, the user works at
// 30, and next time should start at 30 — with any progression protocol
// continuing from 30 rather than from 60.
function pushDay(progression?: Record<string, unknown>) {
  return {
    name: "Push",
    muscles: ["Chest"],
    exercises: [
      {
        name: "Barbell Bench Press",
        sets: 3,
        reps: 8,
        weight: 60,
        ...(progression ? { progression } : {}),
      },
      { name: "Push-ups", sets: 3, reps: 12, weight: 0 },
    ],
  };
}

async function seedPlanAndProgram(progression?: Record<string, unknown>) {
  await db.doc(workoutPlanPath(USER_ID, "current")).set({
    userId: USER_ID,
    planId: "current",
    source: "coach_generated",
    days: { Mon: pushDay(progression) },
    updatedAt: NOW,
  });
  await db.doc(trainingProgramPath(USER_ID)).set({
    userId: USER_ID,
    programId: "current",
    startDate: TODAY,
    weeks: [0, 1, 2].map((weekIndex) => ({
      weekIndex,
      days: { Mon: pushDay(progression) },
    })),
    activeWeekIndex: 0,
    source: "coach_generated",
    updatedAt: NOW,
  });
}

// Runs a whole session at `workedWeight` and returns the finish result.
async function completeSessionAt(workedWeight: number, completedSets = 3) {
  const session = await startWorkoutSession(
    db,
    USER_ID,
    { dayKey: "Mon", planId: "current", startedAt: NOW, clientDate: TODAY },
    {},
  );

  return await finishWorkoutSession(db, USER_ID, {
    sessionId: session.sessionId,
    completedAt: "2026-08-03T13:00:00.000Z",
    exercises: session.exercises.map((exercise) =>
      exercise.name === "Barbell Bench Press"
        ? {
            ...exercise,
            completedSets: exercise.completedSets.map((set, index) => ({
              ...set,
              completed: index < completedSets,
              weight: workedWeight,
            })),
          }
        : exercise,
    ),
  });
}

describe("weight rebaselining", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
    // Match production (functions/src/firebase.ts). Without this the suite
    // tests a Firestore that behaves differently from the deployed one — and
    // that gap is precisely how the undefined-write failures reached a device.
    try {
      db.settings({ ignoreUndefinedProperties: true });
    } catch {
      // settings() throws if the instance has already been used by an earlier
      // suite in the same process; that instance already carries the setting.
    }
  });

  beforeEach(async () => {
    await db.recursiveDelete(db.doc(`users/${USER_ID}`));
  });

  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  describe("finishing a workout", () => {
    it("suggests the worked weight but changes nothing on its own", async () => {
      await seedPlanAndProgram();
      const result = await completeSessionAt(30);

      expect(result.baselineSuggestions).toEqual([
        { exerciseName: "Barbell Bench Press", fromLb: 60, toLb: 30 },
      ]);

      // "Ask on finish" means finishing must not write an anchor.
      const baseline = await db.doc(exerciseBaselinePath(USER_ID, "barbell_bench_press")).get();
      expect(baseline.exists).toBe(false);
      const plan = (await db.doc(workoutPlanPath(USER_ID, "current")).get()).data();
      expect(plan?.days.Mon.exercises[0].weight).toBe(60);
    });

    it("suggests nothing when the user lifted what was prescribed", async () => {
      await seedPlanAndProgram();
      const result = await completeSessionAt(60);
      expect(result.baselineSuggestions).toEqual([]);
    });
  });

  describe("applying baselines", () => {
    it("anchors the new weight and rewrites what the user reads", async () => {
      await seedPlanAndProgram();
      const finished = await completeSessionAt(30);

      await applyExerciseBaselines(db, USER_ID, {
        sessionId: finished.activeWorkout.sessionId,
        baselines: [{ exerciseName: "Barbell Bench Press", weightLb: 30 }],
        clientDate: TODAY,
      });

      const baseline = (
        await db.doc(exerciseBaselinePath(USER_ID, "barbell_bench_press")).get()
      ).data();
      expect(baseline?.anchorWeightLb).toBe(30);
      expect(baseline?.anchorDate).toBe(TODAY);
      expect(baseline?.source).toBe("user_session");

      // The Train tab reads these docs directly — a stale 60 here is a number
      // the user sees and stops trusting.
      const plan = (await db.doc(workoutPlanPath(USER_ID, "current")).get()).data();
      expect(plan?.days.Mon.exercises[0].weight).toBe(30);

      const program = (await db.doc(trainingProgramPath(USER_ID)).get()).data();
      expect(program?.weeks[0].days.Mon.exercises[0].weight).toBe(30);
      expect(program?.weeks[2].days.Mon.exercises[0].weight).toBe(30);
    });

    it("the next workout starts at the rebaselined weight", async () => {
      await seedPlanAndProgram();
      const finished = await completeSessionAt(30);
      await applyExerciseBaselines(db, USER_ID, {
        sessionId: finished.activeWorkout.sessionId,
        baselines: [{ exerciseName: "Barbell Bench Press", weightLb: 30 }],
        clientDate: TODAY,
      });

      // The literal ask: "next time i start at 30lb".
      const next = await startWorkoutSession(
        db,
        USER_ID,
        {
          dayKey: "Mon",
          planId: "current",
          startedAt: "2026-08-10T12:00:00.000Z",
          clientDate: "2026-08-10",
        },
        {},
      );
      const bench = next.exercises.find((exercise) => exercise.name === "Barbell Bench Press");
      expect(bench?.targetWeight).toBe(30);
      expect(bench?.completedSets.every((set) => set.weight === 30)).toBe(true);
    });

    it("refuses to anchor an exercise that was not in the session", async () => {
      await seedPlanAndProgram();
      const finished = await completeSessionAt(30);

      await expect(
        applyExerciseBaselines(db, USER_ID, {
          sessionId: finished.activeWorkout.sessionId,
          baselines: [{ exerciseName: "Deadlift", weightLb: 405 }],
          clientDate: TODAY,
        }),
      ).rejects.toThrow("exercise_baseline_not_in_session");
    });

    it("skips an exercise the user completed no sets of", async () => {
      await seedPlanAndProgram();
      // Zero completed sets: a number staged on the stepper but never lifted.
      const finished = await completeSessionAt(30, 0);

      const result = await applyExerciseBaselines(db, USER_ID, {
        sessionId: finished.activeWorkout.sessionId,
        baselines: [{ exerciseName: "Barbell Bench Press", weightLb: 30 }],
        clientDate: TODAY,
      });

      expect(result.applied).toEqual([]);
      expect(result.skipped).toBe(1);
      const baseline = await db.doc(exerciseBaselinePath(USER_ID, "barbell_bench_press")).get();
      expect(baseline.exists).toBe(false);
    });

    it("writes an audit event", async () => {
      await seedPlanAndProgram();
      const finished = await completeSessionAt(30);
      await applyExerciseBaselines(db, USER_ID, {
        sessionId: finished.activeWorkout.sessionId,
        baselines: [{ exerciseName: "Barbell Bench Press", weightLb: 30 }],
        clientDate: TODAY,
      });

      const audit = await db.collection(`users/${USER_ID}/auditLog`).get();
      expect(audit.docs.map((doc) => doc.data().eventType)).toContain(
        "exercise_baseline_rebaselined",
      );
    });
  });

  describe("progression on top of a rebaseline", () => {
    const RULE = { mode: "linear_lb", amount: 5, everyWeeks: 1, capMultiple: 3 };

    it("continues the protocol from the new anchor, not the old plan weight", async () => {
      await seedPlanAndProgram(RULE);
      const finished = await completeSessionAt(30);
      await applyExerciseBaselines(db, USER_ID, {
        sessionId: finished.activeWorkout.sessionId,
        baselines: [{ exerciseName: "Barbell Bench Press", weightLb: 30 }],
        clientDate: TODAY,
      });

      // Same week: the drop stands.
      const sameWeek = await startWorkoutSession(
        db,
        USER_ID,
        { dayKey: "Mon", planId: "current", startedAt: NOW, clientDate: "2026-08-05" },
        {},
      );
      expect(
        sameWeek.exercises.find((exercise) => exercise.name === "Barbell Bench Press")?.targetWeight,
      ).toBe(30);

      // A week later the +5 protocol fires — from 30, giving 35. Not 65.
      const nextWeek = await startWorkoutSession(
        db,
        USER_ID,
        {
          dayKey: "Mon",
          planId: "current",
          startedAt: "2026-08-10T12:00:00.000Z",
          clientDate: "2026-08-10",
        },
        {},
      );
      expect(
        nextWeek.exercises.find((exercise) => exercise.name === "Barbell Bench Press")?.targetWeight,
      ).toBe(35);
    });

    it("seeds an anchor for a progression exercise that has none yet", async () => {
      // Otherwise a coach-authored protocol would never move until the user
      // happened to change a weight by hand.
      await seedPlanAndProgram(RULE);
      await startWorkoutSession(
        db,
        USER_ID,
        { dayKey: "Mon", planId: "current", startedAt: NOW, clientDate: TODAY },
        {},
      );

      const baseline = (
        await db.doc(exerciseBaselinePath(USER_ID, "barbell_bench_press")).get()
      ).data();
      expect(baseline?.source).toBe("plan_seed");
      // The seed equals what the plan already said, so nothing the user sees
      // changes on the day it is written.
      expect(baseline?.anchorWeightLb).toBe(60);
    });

    it("does not seed an anchor for an exercise with no progression rule", async () => {
      await seedPlanAndProgram();
      await startWorkoutSession(
        db,
        USER_ID,
        { dayKey: "Mon", planId: "current", startedAt: NOW, clientDate: TODAY },
        {},
      );

      const baseline = await db.doc(exerciseBaselinePath(USER_ID, "barbell_bench_press")).get();
      expect(baseline.exists).toBe(false);
    });

    it("the weekly rollover advances the prescription in the plan the user reads", async () => {
      await seedPlanAndProgram(RULE);
      const finished = await completeSessionAt(30);
      await applyExerciseBaselines(db, USER_ID, {
        sessionId: finished.activeWorkout.sessionId,
        baselines: [{ exerciseName: "Barbell Bench Press", weightLb: 30 }],
        clientDate: TODAY,
      });

      // A week on, the daily rollover moves the program to week 1.
      await rolloverTrainingPrograms(db, "2026-08-10");

      const plan = (await db.doc(workoutPlanPath(USER_ID, "current")).get()).data();
      expect(plan?.days.Mon.exercises[0].weight).toBe(35);
      // Bodyweight movements are untouched by progression.
      expect(plan?.days.Mon.exercises[1].weight).toBe(0);
    });

    it("rollover is idempotent — a retried run does not stack increases", async () => {
      await seedPlanAndProgram(RULE);
      const finished = await completeSessionAt(30);
      await applyExerciseBaselines(db, USER_ID, {
        sessionId: finished.activeWorkout.sessionId,
        baselines: [{ exerciseName: "Barbell Bench Press", weightLb: 30 }],
        clientDate: TODAY,
      });

      await rolloverTrainingPrograms(db, "2026-08-10");
      await rolloverTrainingPrograms(db, "2026-08-10");
      await rolloverTrainingPrograms(db, "2026-08-10");

      const plan = (await db.doc(workoutPlanPath(USER_ID, "current")).get()).data();
      expect(plan?.days.Mon.exercises[0].weight).toBe(35);
    });
  });

  describe("users with no baselines", () => {
    it("behaves exactly as before — the plan's own weight is prescribed", async () => {
      await seedPlanAndProgram();
      const session = await startWorkoutSession(
        db,
        USER_ID,
        { dayKey: "Mon", planId: "current", startedAt: NOW, clientDate: TODAY },
        {},
      );
      expect(
        session.exercises.find((exercise) => exercise.name === "Barbell Bench Press")?.targetWeight,
      ).toBe(60);
    });
  });
});
