import { createRequire } from "node:module";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { CLEARANCE_NOTE, processOnboardingAnswer } from "../../../src/onboarding/flow.js";
import { lookupExercise } from "../../../src/workouts/exerciseCatalog.js";
import { profilePath } from "../../../src/paths.js";

// Onboarding is six answers now — any mix of taps, typing and talking — and
// the plan that comes out fits the person's kit and experience.

const require = createRequire(import.meta.url);
const seed = require("../../../src/domain/ironlab-seed.json");

const USER_ID = "six-questions-user-a";
let app: App;
let db: Firestore;
let clock = Date.parse("2026-10-12T18:00:00.000Z");

function say(content: string) {
  clock += 1000;
  return processOnboardingAnswer(
    db,
    USER_ID,
    { content, timestamp: new Date(clock).toISOString(), inputMode: "voice" },
    seed.DEFAULT_PLAN,
  );
}

type Proposal = {
  profile: {
    injuriesOrLimitations: string[];
    schedule: { daysPerWeek: number; preferredDays: string[] };
    preferences: { preferredWorkoutTime: string };
    sexOrGender: string;
  };
  workoutPlan: { days: Record<string, { exercises: Array<{ name: string; weight: number }> }> };
};

describe("six-question onboarding", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });

  beforeEach(async () => {
    await db.recursiveDelete(db.doc(`users/${USER_ID}`));
  });

  afterAll(async () => {
    await db.recursiveDelete(db.doc(`users/${USER_ID}`));
    if (app && getApps().length && app.name !== "[DEFAULT]") await deleteApp(app);
  });

  it("six spoken answers make a plan that fits dumbbells, a bench, and a beginner", async () => {
    expect((await say("I want to build muscle")).onboardingStep).toBe("trainingExperience");
    expect((await say("beginner")).onboardingStep).toBe("equipment");
    expect((await say("dumbbells and a bench at home")).onboardingStep).toBe("ageYears");
    expect((await say("34")).onboardingStep).toBe("preferredDays");
    expect((await say("Mondays, Wednesdays and Fridays at 6pm")).onboardingStep).toBe("injuriesOrLimitations");
    const done = await say("nothing hurts");

    expect(done.onboardingStatus).toBe("proposal_ready");
    const proposal = (done as unknown as { proposal: Proposal }).proposal;
    expect(proposal.profile.schedule).toMatchObject({ daysPerWeek: 3, preferredDays: ["Mon", "Wed", "Fri"] });
    expect(proposal.profile.preferences.preferredWorkoutTime).toBe("evening");
    expect(proposal.profile.sexOrGender).toBe("prefer_not_to_say");

    const days = proposal.workoutPlan.days;
    expect(Object.entries(days).filter(([, d]) => d.exercises.length > 0).map(([k]) => k)).toEqual(["Mon", "Wed", "Fri"]);
    for (const exercise of Object.values(days).flatMap((d) => d.exercises)) {
      const entry = lookupExercise(exercise.name);
      expect(entry!.equipment.every((item) => ["none", "dumbbell", "bench"].includes(item)), exercise.name).toBe(true);
    }
    const draft = (await db.doc(profilePath(USER_ID)).get()).get("onboardingDraft");
    expect(draft.preferredTime).toBe("18:00");
  });

  it("a doctor's limit becomes a clearance note and the gentlest plan", async () => {
    await say("get stronger");
    await say("intermediate");
    await say("full gym");
    await say("60+");
    await say("tuesdays and thursdays");
    const done = await say("my doctor told me to take it easy");

    const proposal = (done as unknown as { proposal: Proposal }).proposal;
    expect(proposal.profile.injuriesOrLimitations).toEqual([CLEARANCE_NOTE]);
    const squat = Object.values(proposal.workoutPlan.days)
      .flatMap((d) => d.exercises)
      .find((e) => /squat/i.test(e.name) && e.weight > 0);
    // Intermediate would start the seed's 135; a doctor's limit starts at "new".
    if (squat) expect(squat.weight).toBeLessThan(135);
  });
});

describe("changing an answer after the plan is drafted", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });

  beforeEach(async () => {
    await db.recursiveDelete(db.doc(`users/${USER_ID}`));
  });

  it("retires the old draft so only one plan is ever pending", async () => {
    for (const answer of ["build muscle", "beginner", "full gym", "30", "mon wed fri", "nothing"]) await say(answer);
    clock += 1000;
    await processOnboardingAnswer(
      db,
      USER_ID,
      {
        content: "Tue Thu",
        timestamp: new Date(clock).toISOString(),
        inputMode: "text",
        structuredAnswer: { preferredDays: ["Tue", "Thu"] },
      },
      seed.DEFAULT_PLAN,
    );
    const pending = await db
      .collection(`users/${USER_ID}/programProposals`)
      .where("decision", "==", "pending")
      .get();
    expect(pending.size).toBe(1);
    expect(pending.docs[0].get("profile.schedule.preferredDays")).toEqual(["Tue", "Thu"]);
  });
});
