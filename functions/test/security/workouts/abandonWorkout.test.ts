import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import {
  abandonWorkoutSession,
  finishWorkoutSession,
  startWorkoutSession,
} from "../../../src/workouts/activeWorkout.js";
import { activeWorkoutPath, profilePath, workoutPlanPath, workoutSessionPath } from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

const USER_ID = "abandon-workout-user-a";
const PLAN = {
  userId: USER_ID,
  planId: "current",
  source: "generated",
  days: {
    Mon: { name: "Push", muscles: ["chest"], exercises: [{ name: "Bench Press", sets: 3, reps: 8, weight: 135 }] },
  },
};

let app: App;
let db: Firestore;

describe("abandonWorkoutSession throws away an unfinished workout", () => {
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

  it("marks the active and session docs abandoned and writes no log", async () => {
    const session = await startWorkoutSession(db, USER_ID, { dayKey: "Mon", planId: "current" }, PLAN);
    const result = await abandonWorkoutSession(db, USER_ID, { sessionId: session.sessionId });

    expect(result.abandoned).toBe(true);
    expect((await db.doc(activeWorkoutPath(USER_ID)).get()).get("status")).toBe("abandoned");
    expect((await db.doc(workoutSessionPath(USER_ID, session.sessionId)).get()).get("status")).toBe("abandoned");
    expect((await db.collection(`users/${USER_ID}/workoutLogs`).get()).empty).toBe(true);
  });

  it("leaves a finished workout alone", async () => {
    const session = await startWorkoutSession(db, USER_ID, { dayKey: "Mon", planId: "current" }, PLAN);
    await finishWorkoutSession(db, USER_ID, {
      sessionId: session.sessionId,
      completedAt: new Date().toISOString(),
      exercises: session.exercises.map((e) => ({
        ...e,
        completedSets: e.completedSets.map((s) => ({ ...s, completed: true })),
      })),
    });
    const result = await abandonWorkoutSession(db, USER_ID, { sessionId: session.sessionId });

    expect(result.abandoned).toBe(false);
    expect((await db.doc(activeWorkoutPath(USER_ID)).get()).get("status")).toBe("completed");
  });
});
