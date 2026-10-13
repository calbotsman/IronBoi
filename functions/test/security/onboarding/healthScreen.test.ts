import { createRequire } from "node:module";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { processOnboardingAnswer } from "../../../src/onboarding/flow.js";
import { MODERATE_NOTE, screenOutcome } from "../../../src/onboarding/healthScreen.js";

// The onboarding health screen follows ACSM 2015's logic: symptoms, or a
// known heart / metabolic / kidney condition in someone not yet active, mean
// a doctor first; other conditions mean moderate effort with specific notes.

const require = createRequire(import.meta.url);
const seed = require("../../../src/domain/ironlab-seed.json");

describe("health screen outcome", () => {
  it("clears someone with nothing to report", () => {
    expect(screenOutcome({ activeNow: "some", conditions: [], symptoms: false })).toEqual({
      status: "clear", reasons: [], notes: [],
    });
  });

  it("needs a doctor first for symptoms, whatever else", () => {
    const outcome = screenOutcome({ activeNow: "regular", conditions: [], symptoms: true });
    expect(outcome.status).toBe("clearance_needed");
    expect(outcome.reasons[0]).toMatch(/symptoms/);
  });

  it("known disease: clearance if inactive, moderate if already active", () => {
    expect(screenOutcome({ activeNow: "none", conditions: ["diabetes"], symptoms: false }).status).toBe("clearance_needed");
    expect(screenOutcome({ activeNow: "some", conditions: ["kidney"], symptoms: false }).status).toBe("clearance_needed");
    const active = screenOutcome({ activeNow: "regular", conditions: ["heart"], symptoms: false });
    expect(active.status).toBe("moderate");
    expect(active.notes[0]).toBe(MODERATE_NOTE);
  });

  it("other conditions: moderate, with the right notes", () => {
    const outcome = screenOutcome({ activeNow: "none", conditions: ["glaucoma", "osteoporosis"], symptoms: false });
    expect(outcome.status).toBe("moderate");
    expect(outcome.notes.join(" ")).toMatch(/head-below-heart/);
    expect(outcome.notes.join(" ")).toMatch(/spinal flexion/);
  });

  it("pregnancy: moderate, or a doctor first with a contraindication", () => {
    expect(screenOutcome({ activeNow: "some", conditions: ["pregnant"], symptoms: false }).status).toBe("moderate");
    expect(screenOutcome({ activeNow: "some", conditions: ["pregnant"], symptoms: false, pregnancyContraindication: true }).status)
      .toBe("clearance_needed");
  });

  it("a doctor's clearance turns 'first' into a moderate start", () => {
    expect(screenOutcome({ activeNow: "none", conditions: [], symptoms: true, clearedByDoctor: true }).status).toBe("moderate");
  });
});

const USER_ID = "health-screen-user-a";
let app: App;
let db: Firestore;
let clock = Date.parse("2026-10-13T18:00:00.000Z");

function answer(content: string, structuredAnswer?: Record<string, unknown>) {
  clock += 1000;
  return processOnboardingAnswer(db, USER_ID, {
    content, timestamp: new Date(clock).toISOString(), inputMode: structuredAnswer ? "tap" : "text", structuredAnswer,
  }, seed.DEFAULT_PLAN);
}

describe("health screen in onboarding", () => {
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

  async function throughAge() {
    await answer("Build muscle", { goals: ["muscle_gain"] });
    await answer("A little", { trainingExperience: "beginner" });
    await answer("Dumbbells", { equipment: ["dumbbells"] });
    await answer("Mon, Wed, Fri at 6", { preferredDays: ["Mon", "Wed", "Fri"], preferredTime: "18:00" });
    await answer("40", { ageYears: 40, sexOrGender: "male", heightCm: 178, weightKg: 88 });
  }

  it("holds the plan for symptoms until a doctor clears them, then starts gently", async () => {
    await throughAge();
    const held = await answer("Screened", {
      healthScreen: { activeNow: "none", conditions: [], symptoms: true }, injuriesOrLimitations: ["none"],
    });
    expect(held.onboardingStatus).toBe("collecting");
    expect(held.onboardingMissingFields).toEqual(["medicalClearance"]);
    expect(held.nextPrompt).toMatch(/check with a doctor/);

    const cleared = await answer("My doctor cleared me", { medicalClearance: "cleared" });
    expect(cleared.onboardingStatus).toBe("proposal_ready");
    const profile = (cleared as unknown as { proposal: { profile: { injuriesOrLimitations: string[] } } }).proposal.profile;
    expect(profile.injuriesOrLimitations).toContain(MODERATE_NOTE);
  });

  it("a condition with no symptoms makes a plan, with its notes", async () => {
    await throughAge();
    const done = await answer("Screened", {
      healthScreen: { activeNow: "some", conditions: ["glaucoma"], symptoms: false }, injuriesOrLimitations: ["none"],
    });
    expect(done.onboardingStatus).toBe("proposal_ready");
    const limits = (done as unknown as { proposal: { profile: { injuriesOrLimitations: string[] } } }).proposal.profile.injuriesOrLimitations;
    expect(limits).toContain(MODERATE_NOTE);
    expect(limits.join(" ")).toMatch(/Glaucoma/);
    expect(limits).not.toContain("none");
  });

  it("free text naming a condition the old keyword list missed still starts gently", async () => {
    await throughAge();
    const done = await answer("I have type 2 diabetes");
    expect(done.onboardingStatus).toBe("proposal_ready");
  });

  it("won't take an age under 18", async () => {
    await answer("Build muscle", { goals: ["muscle_gain"] });
    await answer("A little", { trainingExperience: "beginner" });
    await answer("Dumbbells", { equipment: ["dumbbells"] });
    await answer("Mon at 6", { preferredDays: ["Mon"], preferredTime: "18:00" });
    const young = await answer("16", { ageYears: 16, sexOrGender: "male" });
    expect(young.onboardingMissingFields).toContain("ageYears");
  });
});
