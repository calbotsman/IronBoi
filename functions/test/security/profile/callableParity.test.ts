import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
// Importing index.js initializes the default admin app (src/firebase.ts)
// against the emulator — the same instance the shared handlers close over.
import {
  handleRegenerateWorkoutPlan,
  handleUpsertProfile,
} from "../../../src/index.js";
import { profilePath, workoutPlanPath } from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

// Callable-migration parity suite for the profile-shaped shared handlers.
// Both the onCall callables (upsertProfile, regenerateWorkoutPlan) and
// their *Http twins route through these handlers, so this pins the
// behavior the iOS app depends on regardless of transport — in
// particular that createdAt/updatedAt are SERVER-owned. The
// pre-migration upsertProfile onCall required the client to send them,
// which rejected every real iOS payload (drift found by the parity
// audit on claude/callable-migration).

const USER_ID = "callable-parity-profile-user-a";

let app: App;
let db: Firestore;

// Exactly what UserProfile.firestorePayload() produces on iOS: no userId,
// no createdAt/updatedAt (server-owned), rawValue enums.
function iosProfilePayload() {
  return {
    ageYears: 32,
    sexOrGender: "male",
    heightCm: 180,
    weightKg: 82,
    goals: ["muscle_gain"],
    trainingExperience: "intermediate",
    injuriesOrLimitations: [],
    equipment: ["Barbell"],
    dietaryConstraints: [],
    schedule: {
      preferredDays: ["Mon", "Wed", "Fri", "Sat"],
      daysPerWeek: 4,
      sessionLengthMin: 60,
    },
    preferences: {
      coachingTone: "balanced",
      preferredWorkoutTime: "flexible",
      dislikedExercises: [],
      trainingFocus: "myo_recommended",
      coachingLens: "none",
    },
  };
}

describe("shared profile handlers (callable/*Http parity)", () => {
  beforeAll(() => {
    // src/index.js -> src/firebase.js already created the default app.
    app = getApps()[0]!;
    db = getFirestore(app);
  });

  beforeEach(async () => {
    await Promise.allSettled([db.recursiveDelete(db.doc(`users/${USER_ID}`))]);
  });

  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  it("accepts the iOS payload with no createdAt/updatedAt and stamps both", async () => {
    const result = await handleUpsertProfile(USER_ID, iosProfilePayload());
    expect(result).toEqual({ ok: true, userId: USER_ID });

    const snap = await db.doc(profilePath(USER_ID)).get();
    const data = snap.data()!;
    expect(data).toMatchObject({
      userId: USER_ID,
      ageYears: 32,
      goals: ["muscle_gain"],
      schedule: { daysPerWeek: 4 },
    });
    expect(typeof data.createdAt).toBe("string");
    expect(typeof data.updatedAt).toBe("string");
    expect(data.serverUpdatedAt).toBeTruthy();
  });

  it("preserves the original createdAt on update and never trusts the body's userId", async () => {
    await db.doc(profilePath(USER_ID)).set({ ...baseProfile, userId: USER_ID });

    const result = await handleUpsertProfile(USER_ID, {
      ...iosProfilePayload(),
      // A hostile/buggy client cannot re-point the write or backdate it.
      userId: "someone-else",
      createdAt: "1999-01-01T00:00:00.000Z",
    });
    expect(result.userId).toBe(USER_ID);

    const snap = await db.doc(profilePath(USER_ID)).get();
    const data = snap.data()!;
    expect(data.userId).toBe(USER_ID);
    // baseProfile's pinned createdAt survives the update.
    expect(data.createdAt).toBe("2026-05-08T00:00:00.000Z");
    expect(data.updatedAt).not.toBe("2026-05-08T00:00:00.000Z");
    expect(data.ageYears).toBe(32);
  });

  it("regenerates workoutPlans/current from the saved profile", async () => {
    await db.doc(profilePath(USER_ID)).set({
      ...baseProfile,
      userId: USER_ID,
      schedule: { daysPerWeek: 3, preferredDays: [], sessionLengthMin: 45 },
    });

    const result = await handleRegenerateWorkoutPlan(USER_ID);
    expect(result).toEqual({ ok: true, daysPerWeek: 3 });

    const planSnap = await db.doc(workoutPlanPath(USER_ID, "current")).get();
    expect(planSnap.exists).toBe(true);
    // The generated plan carries all 7 weekday keys; daysPerWeek shows up
    // as the number of TRAINING days (days with exercises).
    const days = planSnap.data()?.days ?? {};
    const trainingDays = Object.values(days).filter(
      (day) => Array.isArray((day as { exercises?: unknown[] }).exercises) &&
        ((day as { exercises: unknown[] }).exercises.length > 0),
    );
    expect(trainingDays).toHaveLength(3);
  });

  it("rejects regeneration with failed-precondition when no profile exists", async () => {
    await expect(handleRegenerateWorkoutPlan(USER_ID)).rejects.toSatisfy(
      (error: unknown) =>
        error instanceof HttpsError && error.code === "failed-precondition",
    );
  });
});
