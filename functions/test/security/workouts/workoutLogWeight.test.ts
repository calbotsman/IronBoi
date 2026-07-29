import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import {
  finishWorkoutSession,
  startWorkoutSession,
} from "../../../src/workouts/activeWorkout.js";
import { profilePath, workoutPlanPath } from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

const USER_ID = "workout-log-weight-user-a";

const PLAN = {
  userId: USER_ID,
  planId: "current",
  source: "generated",
  days: {
    Mon: {
      name: "Push",
      muscles: ["chest"],
      exercises: [
        { name: "Bench Press", sets: 3, reps: 8, weight: 135 },
        { name: "Push-up", sets: 3, reps: 12, weight: 0 },
      ],
    },
  },
};

let app: App;
let db: Firestore;

// This is the seam the progress layer reads from, and until now nothing
// covered it: progress/build.test.ts feeds the builder synthetic logs that
// already have loadKg, so a client that never wrote set.weight produced
// loadKg-less logs for months while every test stayed green.
describe("finishWorkoutSession records what was actually lifted", () => {
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
      // suite in the same worker; the setting is already applied in that case.
    }
  });

  beforeEach(async () => {
    await Promise.allSettled([db.recursiveDelete(db.doc(`users/${USER_ID}`))]);
    await db.doc(profilePath(USER_ID)).set({ ...baseProfile, userId: USER_ID });
    await db.doc(workoutPlanPath(USER_ID, "current")).set({
      ...PLAN,
      createdAt: new Date().toISOString(),
    });
  });

  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  async function startSession() {
    return startWorkoutSession(db, USER_ID, { dayKey: "Mon", planId: "current" }, PLAN);
  }

  async function finishWith(sets: { completed: boolean; weight?: number; reps?: number }[]) {
    const started = await startSession();
    const sessionId = started.sessionId;
    return finishWorkoutSession(db, USER_ID, {
      sessionId,
      completedAt: "2026-07-28T18:00:00.000Z",
      exercises: [
        {
          exerciseIndex: 0,
          name: "Bench Press",
          targetSets: 3,
          targetReps: 8,
          targetWeight: 135,
          exerciseDone: true,
          completedSets: sets.map((set, index) => ({ setIndex: index, ...set })),
        },
      ],
    });
  }

  it("carries per-set weight through to loadKg", async () => {
    const result = (await finishWith([
      { completed: true, weight: 135, reps: 8 },
      { completed: true, weight: 145, reps: 6 },
    ])) as { workoutLog: { exercises: { sets: { reps: number; loadKg?: number }[] }[] } };

    const sets = result.workoutLog.exercises[0].sets;
    expect(sets).toHaveLength(2);
    // 135 lb -> 61.2 kg, 145 lb -> 65.8 kg (rounded to 0.1)
    expect(sets[0]).toMatchObject({ reps: 8, loadKg: 61.2 });
    expect(sets[1]).toMatchObject({ reps: 6, loadKg: 65.8 });
  });

  it("records the per-set reps that were performed, not the prescription", async () => {
    const result = (await finishWith([{ completed: true, weight: 135, reps: 5 }])) as {
      log: { exercises: { sets: { reps: number }[] }[] };
    };
    expect(result.workoutLog.exercises[0].sets[0].reps).toBe(5);
  });

  it("omits loadKg when a set carries no weight — the shape that silently broke progress", async () => {
    // Regression guard for the original defect: the iOS set toggle only ever
    // flipped `completed`, so every set arrived weightless and every logged
    // set was dropped by progress/build.ts (tonnage 0, empty e1RM series).
    // The fix is client-side; this pins the consequence so the failure mode
    // is legible if it ever returns.
    const result = (await finishWith([{ completed: true }])) as {
      log: { exercises: { sets: { reps: number; loadKg?: number }[] }[] };
    };
    const set = result.workoutLog.exercises[0].sets[0];
    expect(set.loadKg).toBeUndefined();
    expect(set.reps).toBe(8); // falls back to the prescription
  });

  it("logs only completed sets", async () => {
    const result = (await finishWith([
      { completed: true, weight: 135, reps: 8 },
      { completed: false, weight: 135 },
    ])) as { workoutLog: { exercises: { sets: unknown[] }[] } };
    expect(result.workoutLog.exercises[0].sets).toHaveLength(1);
  });

  it("keeps bodyweight sets weightless rather than logging a 0 kg lift", async () => {
    const started = await startSession();
    const sessionId = started.sessionId;
    const result = (await finishWorkoutSession(db, USER_ID, {
      sessionId,
      completedAt: "2026-07-28T18:00:00.000Z",
      exercises: [
        {
          exerciseIndex: 1,
          name: "Push-up",
          targetSets: 3,
          targetReps: 12,
          targetWeight: 0,
          exerciseDone: true,
          completedSets: [{ setIndex: 0, completed: true, weight: 0, reps: 12 }],
        },
      ],
    })) as { workoutLog: { exercises: { sets: { loadKg?: number }[] }[] } };

    // build.ts treats a 0 kg e1RM as meaningless and skips it by design —
    // bodyweight progression is a separate metric, not a zero-load lift.
    expect(result.workoutLog.exercises[0].sets[0].loadKg).toBeUndefined();
  });
});
