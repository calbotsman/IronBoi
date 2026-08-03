import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import {
  getExerciseSwapOptions,
  swapExercise,
} from "../../../src/workouts/exerciseSwap.js";
import { startWorkoutSession } from "../../../src/workouts/activeWorkout.js";
import {
  activeWorkoutPath,
  exerciseBaselinePath,
  trainingProgramPath,
  workoutPlanPath,
  workoutSessionPath,
} from "../../../src/paths.js";

const USER_ID = "exercise-swap-user-a";
const TODAY = "2026-08-03"; // a Monday
const NOW = "2026-08-03T12:00:00.000Z";

let app: App;
let db: Firestore;

function pushDay() {
  return {
    name: "Push + HIIT",
    muscles: ["Chest", "Triceps"],
    exercises: [
      { name: "Barbell Bench Press", sets: 3, reps: 8, weight: 135 },
      { name: "Overhead Press", sets: 3, reps: 10, weight: 75 },
      { name: "Plank", sets: 3, reps: 60, weight: 0 },
    ],
  };
}

async function seedPlan() {
  await db.doc(workoutPlanPath(USER_ID, "current")).set({
    userId: USER_ID,
    planId: "current",
    source: "coach_generated",
    days: { Mon: pushDay(), Wed: { name: "Rest", muscles: [], exercises: [] } },
    updatedAt: NOW,
  });
}

async function seedProgram(activeWeekIndex = 0) {
  await db.doc(trainingProgramPath(USER_ID)).set({
    userId: USER_ID,
    programId: "current",
    startDate: TODAY,
    weeks: [0, 1, 2].map((weekIndex) => ({
      weekIndex,
      days: { Mon: pushDay() },
    })),
    activeWeekIndex,
    source: "coach_generated",
    updatedAt: NOW,
  });
}

describe("exercise swaps", () => {
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
    await seedPlan();
  });

  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  describe("getExerciseSwapOptions", () => {
    it("offers same-muscle options and excludes what is already in the day", async () => {
      const result = await getExerciseSwapOptions(db, USER_ID, {
        exerciseName: "Barbell Bench Press",
        dayKey: "Mon",
        planId: "current",
        clientDate: TODAY,
        limit: 6,
      });

      expect(result.options.length).toBeGreaterThan(0);
      const names = result.options.map((option) => option.name);
      expect(names).not.toContain("Barbell Bench Press");
      // Overhead Press is already in the day; it must not be offered even
      // though it shares tissue.
      expect(names).not.toContain("Overhead Press");
    });

    it("filters to bodyweight when the user has no equipment", async () => {
      const result = await getExerciseSwapOptions(db, USER_ID, {
        exerciseName: "Barbell Bench Press",
        dayKey: "Mon",
        planId: "current",
        availableEquipment: [],
        clientDate: TODAY,
        limit: 6,
      });

      expect(result.options.length).toBeGreaterThan(0);
      for (const option of result.options) {
        expect(option.equipment.every((item) => item === "none")).toBe(true);
      }
    });

    it("prefers the user's own anchor over a load carried from the original", async () => {
      await db.doc(exerciseBaselinePath(USER_ID, "dumbbell_bench_press")).set({
        userId: USER_ID,
        exerciseKey: "dumbbell_bench_press",
        exerciseName: "Dumbbell Bench Press",
        anchorWeightLb: 45,
        anchorDate: TODAY,
        source: "user_session",
        updatedAt: NOW,
      });

      const result = await getExerciseSwapOptions(db, USER_ID, {
        exerciseName: "Barbell Bench Press",
        dayKey: "Mon",
        planId: "current",
        availableEquipment: ["dumbbell", "bench"],
        clientDate: TODAY,
        limit: 8,
      });

      const dumbbell = result.options.find((option) => option.name === "Dumbbell Bench Press");
      expect(dumbbell).toBeDefined();
      expect(dumbbell?.suggestedWeightLb).toBe(45);
      expect(dumbbell?.weightFromBaseline).toBe(true);
    });
  });

  describe("scope: going_forward", () => {
    it("patches the template and every week from the active one on", async () => {
      await seedProgram(1);

      await swapExercise(db, USER_ID, {
        dayKey: "Mon",
        exerciseName: "Barbell Bench Press",
        replacementName: "Push-ups",
        scope: "going_forward",
        planId: "current",
        clientDate: TODAY,
      });

      const plan = (await db.doc(workoutPlanPath(USER_ID, "current")).get()).data();
      const names = plan?.days.Mon.exercises.map((exercise: { name: string }) => exercise.name);
      expect(names).toEqual(["Push-ups", "Overhead Press", "Plank"]);

      const program = (await db.doc(trainingProgramPath(USER_ID)).get()).data();
      // Week 0 is behind the active week — history, left alone.
      expect(program?.weeks[0].days.Mon.exercises[0].name).toBe("Barbell Bench Press");
      expect(program?.weeks[1].days.Mon.exercises[0].name).toBe("Push-ups");
      expect(program?.weeks[2].days.Mon.exercises[0].name).toBe("Push-ups");
    });

    it("keeps position, sets and reps", async () => {
      await seedProgram();
      await swapExercise(db, USER_ID, {
        dayKey: "Mon",
        exerciseName: "Barbell Bench Press",
        replacementName: "Push-ups",
        scope: "going_forward",
        planId: "current",
        clientDate: TODAY,
      });

      const plan = (await db.doc(workoutPlanPath(USER_ID, "current")).get()).data();
      const swapped = plan?.days.Mon.exercises[0];
      expect(swapped.sets).toBe(3);
      expect(swapped.reps).toBe(8);
      // 135 lb does not follow a barbell press onto push-ups.
      expect(swapped.weight).toBe(0);
    });
  });

  describe("scope: today", () => {
    it("writes a dated override and leaves the template untouched", async () => {
      await swapExercise(db, USER_ID, {
        dayKey: "Mon",
        exerciseName: "Barbell Bench Press",
        replacementName: "Push-ups",
        scope: "today",
        planId: "current",
        clientDate: TODAY,
      });

      const plan = (await db.doc(workoutPlanPath(USER_ID, "current")).get()).data();
      expect(plan?.dailyOverrides[TODAY].exercises[0].name).toBe("Push-ups");
      // The repeating week is what "just today" must not touch.
      expect(plan?.days.Mon.exercises[0].name).toBe("Barbell Bench Press");
    });
  });

  describe("scope: session", () => {
    async function startSession() {
      return await startWorkoutSession(
        db,
        USER_ID,
        { dayKey: "Mon", planId: "current", startedAt: NOW, clientDate: TODAY },
        {},
      );
    }

    it("replaces in place when nothing has been logged yet", async () => {
      const session = await startSession();
      const result = await swapExercise(db, USER_ID, {
        dayKey: "Mon",
        exerciseName: "Barbell Bench Press",
        replacementName: "Push-ups",
        scope: "session",
        sessionId: session.sessionId,
        planId: "current",
        clientDate: TODAY,
      });

      expect(result.scope).toBe("session");
      const names = "activeWorkout" in result
        ? result.activeWorkout.exercises.map((exercise) => exercise.name)
        : [];
      expect(names).toEqual(["Push-ups", "Overhead Press", "Plank"]);

      // The plan is deliberately untouched by a session swap.
      const plan = (await db.doc(workoutPlanPath(USER_ID, "current")).get()).data();
      expect(plan?.days.Mon.exercises[0].name).toBe("Barbell Bench Press");
      expect(plan?.dailyOverrides).toBeUndefined();
    });

    it("preserves already-completed sets instead of erasing them", async () => {
      const session = await startSession();
      // Two sets of bench actually happened before the swap.
      const active = (await db.doc(activeWorkoutPath(USER_ID)).get()).data();
      const exercises = active?.exercises as Array<Record<string, unknown>>;
      exercises[0].completedSets = [
        { setIndex: 0, completed: true, reps: 8, weight: 135 },
        { setIndex: 1, completed: true, reps: 8, weight: 135 },
        { setIndex: 2, completed: false, reps: 8, weight: 135 },
      ];
      await db.doc(activeWorkoutPath(USER_ID)).set({ ...active, exercises }, { merge: true });

      const result = await swapExercise(db, USER_ID, {
        dayKey: "Mon",
        exerciseName: "Barbell Bench Press",
        replacementName: "Push-ups",
        scope: "session",
        sessionId: session.sessionId,
        planId: "current",
        clientDate: TODAY,
      });

      const swapped = "activeWorkout" in result ? result.activeWorkout : null;
      const names = swapped?.exercises.map((exercise) => exercise.name);
      // The bench work stays in the log; push-ups take over the remainder.
      expect(names).toEqual(["Barbell Bench Press", "Push-ups", "Overhead Press", "Plank"]);

      const bench = swapped?.exercises[0];
      expect(bench?.completedSets).toHaveLength(2);
      expect(bench?.exerciseDone).toBe(true);

      // One bench set remained, so one set of push-ups replaces it.
      expect(swapped?.exercises[1].targetSets).toBe(1);

      // exerciseIndex is the client's row identity — duplicates render as a
      // missing row in SwiftUI.
      const indices = swapped?.exercises.map((exercise) => exercise.exerciseIndex);
      expect(indices).toEqual([0, 1, 2, 3]);
    });

    it("mirrors the swap into the workoutSessions doc", async () => {
      const session = await startSession();
      await swapExercise(db, USER_ID, {
        dayKey: "Mon",
        exerciseName: "Barbell Bench Press",
        replacementName: "Push-ups",
        scope: "session",
        sessionId: session.sessionId,
        planId: "current",
        clientDate: TODAY,
      });

      const stored = (await db.doc(workoutSessionPath(USER_ID, session.sessionId)).get()).data();
      expect(stored?.exercises[0].name).toBe("Push-ups");
    });

    it("rejects a sessionId that is not the running session", async () => {
      await startSession();
      await expect(
        swapExercise(db, USER_ID, {
          dayKey: "Mon",
          exerciseName: "Barbell Bench Press",
          replacementName: "Push-ups",
          scope: "session",
          sessionId: "some-other-session",
          planId: "current",
          clientDate: TODAY,
        }),
      ).rejects.toThrow("active_workout_session_mismatch");
    });
  });

  describe("validation", () => {
    it("refuses a replacement that trains something else", async () => {
      await expect(
        swapExercise(db, USER_ID, {
          dayKey: "Mon",
          exerciseName: "Barbell Bench Press",
          replacementName: "Standing Calf Raises",
          scope: "going_forward",
          planId: "current",
          clientDate: TODAY,
        }),
      ).rejects.toThrow("exercise_swap_not_equivalent");
    });

    it("refuses an exercise name the catalog does not know", async () => {
      // The server-side gate: a client cannot inject an arbitrary string into
      // the user's program.
      await expect(
        swapExercise(db, USER_ID, {
          dayKey: "Mon",
          exerciseName: "Barbell Bench Press",
          replacementName: "Definitely Not An Exercise",
          scope: "going_forward",
          planId: "current",
          clientDate: TODAY,
        }),
      ).rejects.toThrow("exercise_swap_not_equivalent");
    });

    it("refuses to swap an exercise that is not in the target day", async () => {
      await expect(
        swapExercise(db, USER_ID, {
          dayKey: "Wed",
          exerciseName: "Barbell Bench Press",
          replacementName: "Push-ups",
          scope: "going_forward",
          planId: "current",
          clientDate: TODAY,
        }),
      ).rejects.toThrow("exercise_swap_target_not_in_day");
    });

    it("writes an audit event for a swap", async () => {
      await swapExercise(db, USER_ID, {
        dayKey: "Mon",
        exerciseName: "Barbell Bench Press",
        replacementName: "Push-ups",
        scope: "today",
        planId: "current",
        clientDate: TODAY,
      });

      const audit = await db.collection(`users/${USER_ID}/auditLog`).get();
      const types = audit.docs.map((doc) => doc.data().eventType);
      // No review card exists for a narrow edit, so the audit log is the only
      // record that the plan changed.
      expect(types).toContain("exercise_swapped");
    });
  });
});
