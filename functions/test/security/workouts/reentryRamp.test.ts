import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import {
  acceptPlanAdjustmentProposal,
  createPlanAdjustmentProposalFromTool,
  materializeRampOverrides,
  publishDraftProposals,
  rampAnchorDate,
  rampWeekDates,
  scaleDayToIntensity,
  validateReentryRamp,
} from "../../../src/workouts/planAdjustments.js";
import {
  planAdjustmentProposalPath,
  profilePath,
  workoutPlanPath,
} from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

const USER_ID = "reentry-ramp-user-a";

// A Monday, so week 0 is a full Mon–Sun block and the arithmetic in the
// assertions below is readable. Fixed rather than derived from the clock:
// a "today"-relative fixture is exactly the calendar time-bomb that has bitten
// this suite before.
const MONDAY = "2026-07-27";

const PLAN_DAYS = {
  Mon: {
    name: "Push",
    muscles: ["chest"],
    exercises: [
      { name: "Bench Press", sets: 4, reps: 8, weight: 185 },
      { name: "Push-up", sets: 3, reps: 12, weight: 0 },
    ],
  },
  Wed: {
    name: "Pull",
    muscles: ["back"],
    exercises: [{ name: "Barbell Row", sets: 5, reps: 5, weight: 135 }],
  },
  Fri: {
    name: "Legs",
    muscles: ["quads"],
    exercises: [{ name: "Back Squat", sets: 5, reps: 5, weight: 225 }],
  },
  Sun: { name: "Rest", muscles: [], exercises: [] },
};

let app: App;
let db: Firestore;

async function seedPlan() {
  await db.doc(workoutPlanPath(USER_ID, "current")).set({
    userId: USER_ID,
    planId: "current",
    days: PLAN_DAYS,
    source: "generated",
    createdAt: new Date().toISOString(),
  });
}

describe("re-entry ramp", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });

  beforeEach(async () => {
    await Promise.allSettled([db.recursiveDelete(db.doc(`users/${USER_ID}`))]);
    await db.doc(profilePath(USER_ID)).set({ ...baseProfile, userId: USER_ID });
    await seedPlan();
  });

  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  describe("shape validation", () => {
    it("requires the ramp to finish at full intensity", () => {
      expect(
        validateReentryRamp([
          { intensityPct: 60, note: "a" },
          { intensityPct: 80, note: "b" },
        ]),
      ).toEqual({ ok: false, error: "ramp_must_end_at_full_intensity" });
    });

    it("rejects a ramp that steps back down", () => {
      expect(
        validateReentryRamp([
          { intensityPct: 80, note: "a" },
          { intensityPct: 60, note: "b" },
          { intensityPct: 100, note: "c" },
        ]),
      ).toEqual({ ok: false, error: "ramp_intensity_must_not_decrease" });
    });

    it("rejects a ramp that starts at full intensity (it would change nothing)", () => {
      expect(
        validateReentryRamp([
          { intensityPct: 100, note: "a" },
          { intensityPct: 100, note: "b" },
        ]),
      ).toEqual({ ok: false, error: "ramp_first_week_must_be_reduced" });
    });

    it("accepts a well-formed ramp", () => {
      expect(
        validateReentryRamp([
          { intensityPct: 60, note: "a" },
          { intensityPct: 80, note: "b" },
          { intensityPct: 100, note: "c" },
        ]),
      ).toEqual({ ok: true });
    });
  });

  describe("scaling", () => {
    it("reduces sets and load but never reps, and never to zero", () => {
      const scaled = scaleDayToIntensity(PLAN_DAYS.Mon, 60);
      expect(scaled.exercises).toEqual([
        // 4 sets * 0.6 = 2.4 -> 2; 185 * 0.6 = 111 -> nearest 5 = 110
        { name: "Bench Press", sets: 2, reps: 8, weight: 110 },
        // Bodyweight stays bodyweight; 3 * 0.6 = 1.8 -> 2
        { name: "Push-up", sets: 2, reps: 12, weight: 0 },
      ]);
      expect(scaled.name).toBe("Push · 60%");
    });

    it("floors a single-set exercise at one set rather than deleting it", () => {
      const scaled = scaleDayToIntensity(
        { name: "Accessory", muscles: [], exercises: [{ name: "Curl", sets: 1, reps: 12, weight: 20 }] },
        40,
      );
      expect(scaled.exercises[0].sets).toBe(1);
      // 20 * 0.4 = 8 -> nearest 5 = 10
      expect(scaled.exercises[0].weight).toBe(10);
    });

    it("never prescribes MORE than baseline, at any weight or intensity", () => {
      // Rounding to the nearest 5 rounds UP at a remainder of 2.5, and a
      // small-weight floor pushed light loads upward — both handed the user
      // more weight on their EASIEST week. That falsifies the "a ramp only
      // ever reduces" invariant that is the whole reason a ramp is allowed to
      // apply without review, and it lands hardest on the lightest, most
      // protected movements.
      const violations: string[] = [];
      for (let weight = 1; weight <= 200; weight += 1) {
        for (let pct = 40; pct <= 100; pct += 1) {
          const scaled = scaleDayToIntensity(
            { name: "D", muscles: [], exercises: [{ name: "X", sets: 4, reps: 8, weight }] },
            pct,
          ).exercises[0];
          if (scaled.weight > weight || scaled.sets > 4) {
            violations.push(`${weight}lb @ ${pct}% -> ${scaled.weight}lb x${scaled.sets}`);
          }
        }
      }
      expect(violations).toEqual([]);
    });

    it("leaves a sub-5lb rehab load at baseline instead of flooring it upward", () => {
      const scaled = scaleDayToIntensity(
        {
          name: "Rehab",
          muscles: [],
          exercises: [{ name: "External Rotation", sets: 3, reps: 15, weight: 2.5 }],
        },
        40,
      );
      expect(scaled.exercises[0].weight).toBe(2.5);
    });
  });

  describe("week windows", () => {
    it("starts week 0 at today and ends it on Sunday", () => {
      const week0 = rampWeekDates(0, MONDAY);
      expect(week0[0]).toBe(MONDAY);
      expect(week0.at(-1)).toBe("2026-08-02");
      expect(week0).toHaveLength(7);
    });

    it("does not backfill days already elapsed in the current week", () => {
      // Proposed on the Thursday: the ramp must not claim to have reduced
      // Monday through Wednesday.
      const week0 = rampWeekDates(0, "2026-07-30");
      expect(week0[0]).toBe("2026-07-30");
      expect(week0).toHaveLength(4);
    });

    it("makes every later week a full Monday-to-Sunday block", () => {
      expect(rampWeekDates(1, MONDAY)[0]).toBe("2026-08-03");
      expect(rampWeekDates(1, MONDAY).at(-1)).toBe("2026-08-09");
      expect(rampWeekDates(2, MONDAY)[0]).toBe("2026-08-10");
    });
  });

  describe("materialization", () => {
    const RAMP = [
      { intensityPct: 60, note: "ease in" },
      { intensityPct: 80, note: "build" },
      { intensityPct: 100, note: "normal" },
    ];

    it("writes one dated override per training day across every reduced week", () => {
      const overrides = materializeRampOverrides(PLAN_DAYS, RAMP, MONDAY);
      // Week 0 (Jul 27 Mon, Jul 29 Wed, Jul 31 Fri) and week 1 (Aug 3, 5, 7).
      // Sunday is a rest day and is skipped; week 2 is 100% and writes nothing.
      expect(Object.keys(overrides).sort()).toEqual([
        "2026-07-27",
        "2026-07-29",
        "2026-07-31",
        "2026-08-03",
        "2026-08-05",
        "2026-08-07",
      ]);
    });

    it("scales each week to its own intensity", () => {
      const overrides = materializeRampOverrides(PLAN_DAYS, RAMP, MONDAY);
      expect(overrides["2026-07-31"].exercises[0]).toMatchObject({
        name: "Back Squat",
        sets: 3, // 5 * 0.6 = 3
        weight: 135, // 225 * 0.6 = 135
      });
      expect(overrides["2026-08-07"].exercises[0]).toMatchObject({
        sets: 4, // 5 * 0.8 = 4
        weight: 180, // 225 * 0.8 = 180
      });
    });

    it("never writes an override for a 100% week — the template already says that", () => {
      const overrides = materializeRampOverrides(PLAN_DAYS, RAMP, MONDAY);
      for (const date of rampWeekDates(2, MONDAY)) {
        expect(overrides[date]).toBeUndefined();
      }
    });

    it("skips rest days rather than renaming them", () => {
      const overrides = materializeRampOverrides(PLAN_DAYS, RAMP, MONDAY);
      expect(overrides["2026-08-02"]).toBeUndefined();
    });

    it("shifts to next Monday when this week has no training days left", () => {
      // Saturday. A Mon/Wed/Fri split has nothing left this week, so anchoring
      // week 0 to today would burn the gentlest step on an empty stub: the
      // user's first session back would be at 80%, not 60%. Worse, a minimal
      // two-week [60, 100] ramp would materialize nothing and be refused —
      // on the single likeliest day for someone to say "I fell off".
      const saturday = "2026-07-25";
      expect(rampAnchorDate(PLAN_DAYS, saturday)).toBe("2026-07-27");

      const overrides = materializeRampOverrides(PLAN_DAYS, RAMP, saturday);
      // Every step is delivered in full — 60% week first.
      expect(overrides["2026-07-27"].name).toBe("Push · 60%");
      expect(overrides["2026-08-03"].name).toBe("Push · 80%");
      expect(Object.keys(overrides).some((date) => date < "2026-07-27")).toBe(false);
    });

    it("anchors to today when this week still has a training day", () => {
      // Thursday: Friday is still ahead, so week 0 is the real remainder.
      expect(rampAnchorDate(PLAN_DAYS, "2026-07-30")).toBe("2026-07-30");
      const overrides = materializeRampOverrides(PLAN_DAYS, RAMP, "2026-07-30");
      expect(overrides["2026-07-31"].name).toBe("Legs · 60%");
    });
  });

  describe("propose and accept", () => {
    const RAMP = [
      { intensityPct: 60, note: "Rebuild the pattern" },
      { intensityPct: 80, note: "Add load back" },
      { intensityPct: 100, note: "Back to normal" },
    ];

    async function proposeRampWithRawText(rawUserText: string, clientDate = MONDAY) {
      return createPlanAdjustmentProposalFromTool({
        db,
        userId: USER_ID,
        reason: "returning_from_layoff",
        userNote: "Fell off for a few weeks, wants easing back in.",
        rampWeeks: RAMP,
        rawUserText,
        clientDate,
      });
    }

    async function proposeRamp() {
      const result = await proposeRampWithRawText("I fell off. I need you to adjust my workout.");
      await publishDraftProposals(db, USER_ID, [result.proposalId!]);
      return result;
    }

    it("is appliable without a scope question", async () => {
      const result = await proposeRamp();
      expect(result).toMatchObject({
        category: "readiness_low",
        riskLevel: "low",
        requiresFollowUp: false,
        needsScopeConfirmation: false,
      });
      const snap = await db.doc(planAdjustmentProposalPath(USER_ID, result.proposalId!)).get();
      expect(snap.data()).toMatchObject({
        decision: "pending",
        appliesTo: { scope: "reentry_ramp" },
        proposedPlanPatch: { type: "reentry_ramp" },
      });
      // A ramp spans weeks — a single target day would be a lie.
      expect(snap.data()?.appliesTo?.dayKey).toBeUndefined();
    });

    it("shows the real dates and training days on the card", async () => {
      const result = await proposeRamp();
      const snap = await db.doc(planAdjustmentProposalPath(USER_ID, result.proposalId!)).get();
      const changes = snap.data()?.proposedPlanPatch?.changes as string[];
      expect(changes).toHaveLength(3);
      expect(changes[0]).toContain("2026-07-27 → 2026-08-02");
      expect(changes[0]).toContain("60% of normal");
      expect(changes[0]).toContain("Mon, Wed, Fri");
      expect(changes[2]).toContain("back to your normal plan");
    });

    it("carries every concrete session so the card can show what will be written", async () => {
      // "60% of normal" is not reviewable content — nobody can derive
      // "Back Squat 3×5 @ 135" from it, and the scaling rounds. The card
      // renders these the same way it renders a substitution week.
      const result = await proposeRamp();
      const snap = await db.doc(planAdjustmentProposalPath(USER_ID, result.proposalId!)).get();
      const rampDays = snap.data()?.proposedPlanPatch?.rampDays as
        | { date: string; day: { name: string; exercises: { name: string; sets: number; weight: number }[] } }[]
        | undefined;

      expect(rampDays).toHaveLength(6);
      expect(rampDays![0]).toMatchObject({ date: "2026-07-27" });
      const friday60 = rampDays!.find((entry) => entry.date === "2026-07-31");
      expect(friday60?.day.exercises[0]).toMatchObject({
        name: "Back Squat",
        sets: 3,
        weight: 135,
      });

      // The preview must match what accept actually writes, exercise for
      // exercise — a card that promises a different session than the one it
      // installs is the failure mode this whole field exists to prevent.
      await acceptPlanAdjustmentProposal(db, USER_ID, {
        proposalId: result.proposalId!,
        clientDate: MONDAY,
      });
      const plan = (await db.doc(workoutPlanPath(USER_ID, "current")).get()).data();
      for (const entry of rampDays!) {
        expect(plan?.dailyOverrides[entry.date]).toEqual(entry.day);
      }
    });

    it("writes the whole multi-week ramp as dated overrides and leaves the template alone", async () => {
      const result = await proposeRamp();
      await acceptPlanAdjustmentProposal(db, USER_ID, {
        proposalId: result.proposalId!,
        clientDate: MONDAY,
      });

      const plan = (await db.doc(workoutPlanPath(USER_ID, "current")).get()).data();
      expect(Object.keys(plan?.dailyOverrides ?? {}).sort()).toEqual([
        "2026-07-27",
        "2026-07-29",
        "2026-07-31",
        "2026-08-03",
        "2026-08-05",
        "2026-08-07",
      ]);
      // This is the whole point of the "fell off" fix: the change reaches
      // past Sunday into the following week.
      expect(plan?.dailyOverrides["2026-08-05"].exercises[0].sets).toBe(4);
      // The baseline template is untouched, so the plan returns to normal on
      // its own once the dated overrides run out.
      expect(plan?.days).toMatchObject(PLAN_DAYS);
    });

    it("clears earlier adjustments inside the window AND names them on the card", async () => {
      await db.doc(workoutPlanPath(USER_ID, "current")).set(
        {
          dailyOverrides: {
            "2026-07-20": { name: "Old past", muscles: [], exercises: [] },
            // Inside the ramp window, on a rest day the ramp doesn't write.
            // It has to go — otherwise it keeps overriding a date the ramp
            // promised would be back to normal. But it is content the user
            // approved earlier, so the card must say so: the prune and the
            // disclosure are computed from the same helper precisely so they
            // cannot drift apart.
            "2026-08-02": { name: "Existing accommodation", muscles: [], exercises: [] },
          },
        },
        { merge: true },
      );

      const result = await proposeRamp();
      const snap = await db.doc(planAdjustmentProposalPath(USER_ID, result.proposalId!)).get();
      const changes = snap.data()?.proposedPlanPatch?.changes as string[];
      expect(changes.some((line) => line.includes("2026-08-02") && line.includes("Also clears"))).toBe(
        true,
      );

      await acceptPlanAdjustmentProposal(db, USER_ID, {
        proposalId: result.proposalId!,
        clientDate: MONDAY,
      });

      const plan = (await db.doc(workoutPlanPath(USER_ID, "current")).get()).data();
      expect(plan?.dailyOverrides["2026-07-20"]).toBeUndefined();
      expect(plan?.dailyOverrides["2026-08-02"]).toBeUndefined();
      expect(plan?.dailyOverrides["2026-07-27"].name).toBe("Push · 60%");
    });

    it("says nothing about clearing when there is nothing to clear", async () => {
      const result = await proposeRamp();
      const snap = await db.doc(planAdjustmentProposalPath(USER_ID, result.proposalId!)).get();
      const changes = snap.data()?.proposedPlanPatch?.changes as string[];
      expect(changes.some((line) => line.includes("Also clears"))).toBe(false);
    });

    it("re-anchors the ramp to the day it is accepted, not the day it was proposed", async () => {
      const result = await proposeRamp();
      // Approved four weeks later. A ramp is a shape, not a calendar: "start
      // easing back in" means start now. The card says so explicitly
      // ("starts when you approve") so the shifted dates match the promise.
      await acceptPlanAdjustmentProposal(db, USER_ID, {
        proposalId: result.proposalId!,
        clientDate: "2026-08-24",
      });

      const plan = (await db.doc(workoutPlanPath(USER_ID, "current")).get()).data();
      const dates = Object.keys(plan?.dailyOverrides ?? {}).sort();
      expect(dates[0]).toBe("2026-08-24");
      expect(dates.at(-1)).toBe("2026-09-04");
      // Nothing is written into the dead window between propose and accept.
      expect(dates.some((date) => date < "2026-08-24")).toBe(false);
    });

    it("fails loudly rather than silently applying nothing when there is no training day to scale", async () => {
      await db.doc(workoutPlanPath(USER_ID, "current")).set(
        { days: { Mon: { name: "Rest", muscles: [], exercises: [] } } },
        { merge: false },
      );
      const result = await createPlanAdjustmentProposalFromTool({
        db,
        userId: USER_ID,
        reason: "returning_from_layoff",
        userNote: "easing back",
        rampWeeks: RAMP,
        rawUserText: "I fell off",
        clientDate: MONDAY,
      });
      expect(result).toMatchObject({
        proposalId: null,
        error: "ramp_has_no_training_days_to_scale",
      });
    });

    it("rejects a malformed ramp without persisting anything", async () => {
      const result = await createPlanAdjustmentProposalFromTool({
        db,
        userId: USER_ID,
        reason: "returning_from_layoff",
        userNote: "back after a while",
        rampWeeks: [
          { intensityPct: 60, note: "a" },
          { intensityPct: 70, note: "b" },
        ],
        rawUserText: "I fell off",
        clientDate: MONDAY,
      });
      expect(result).toMatchObject({
        proposalId: null,
        error: "ramp_must_end_at_full_intensity",
      });
      const all = await db.collection(`users/${USER_ID}/planAdjustmentProposals`).get();
      expect(all.empty).toBe(true);
    });

    it("refuses a ramp when the user's own words describe pregnancy or postpartum", async () => {
      // readiness_low's medium-risk hold used to catch this. The ramp's risk
      // downgrade was gated on `category !== injury_pain`, and
      // classifyPlanAdjustment checks pregnancy BEFORE injury — so this
      // sailed through to a one-tap appliable card.
      const result = await createPlanAdjustmentProposalFromTool({
        db,
        userId: USER_ID,
        reason: "returning_from_layoff",
        userNote: "back after time off",
        rampWeeks: RAMP,
        rawUserText: "I'm 6 weeks postpartum and haven't trained since the birth. Ease me back in.",
        clientDate: MONDAY,
      });
      expect(result).toMatchObject({
        proposalId: null,
        category: "pregnancy_postpartum",
        error: "ramp_not_valid_for_this_category",
      });
    });

    it("refuses a ramp when the user's own words describe pain", async () => {
      // A ramp scales the plan down; it cannot route AROUND a movement.
      // Proposing one here would put the user's own aggravating exercise back
      // on the bar at 60% under a card that never mentions the pain.
      const result = await createPlanAdjustmentProposalFromTool({
        db,
        userId: USER_ID,
        reason: "returning_from_layoff",
        userNote: "easing back",
        rampWeeks: RAMP,
        rawUserText: "stopped training two months ago because my knee hurts when I squat",
        clientDate: MONDAY,
      });
      expect(result).toMatchObject({
        proposalId: null,
        category: "injury_pain",
        error: "ramp_not_valid_for_this_category",
      });
    });

    // "back" is both a body part and the most natural word for returning to
    // training. The guard that separates them is deliberately narrow, and the
    // two directions are NOT equally costly: a false positive costs the user
    // some unnecessary triage questions, a false negative puts an injured
    // user's own aggravating movement back on the bar via an auto-appliable
    // ramp. An earlier, looser guard (excusing any "back <preposition>") did
    // exactly that — hence the second table.
    it.each([
      "I fell off for a month and want to get back into training",
      "been off for weeks, easing back into lifting",
      "ready to get back at it after the holidays",
      "trying to work back into my routine",
      // The pronoun forms. These are how people ACTUALLY phrase it, and the
      // first one is the exact sentence that failed on live staging: the
      // model authored a clean 60-80-100 ramp and the server refused it as a
      // back injury. The original unit tests only covered the adjacent forms.
      "I fell off and haven't trained in about a month. Can you ease me back into my normal routine over the next few weeks?",
      "can you work me back up to where I was",
      "help me get back into it",
      "ease me back in please",
    ])("treats %j as a return, not an injury", async (rawUserText) => {
      const result = await proposeRampWithRawText(rawUserText);
      expect(result).toMatchObject({ category: "readiness_low", riskLevel: "low" });
    });

    it.each([
      "my lower back has been bothering me since I stopped",
      "I tweaked my back on Monday",
      "I strained my back in the gym yesterday",
      "felt a twinge in my back on squats",
      "something feels off in my back at the bottom of the squat",
      "want to get back into it but my back hurts",
      // The pronoun allowance must not swallow a real report that happens to
      // sit next to a return phrase.
      "ease me back in — my back has been sore since I stopped",
      "I pulled my back last week",
    ])("still refuses a ramp for %j", async (rawUserText) => {
      const result = await proposeRampWithRawText(rawUserText);
      expect(result).toMatchObject({
        category: "injury_pain",
        error: "ramp_not_valid_for_this_category",
      });
    });

    it("refuses a ramp while the user is still symptomatic from an illness", async () => {
      // Returning to training while still febrile is a clinical caution, not
      // a programming question — and the ramp is the one adjustment that
      // skips human review, so this has to be enforced server-side rather
      // than by prompt text alone.
      const result = await proposeRampWithRawText(
        "I've been sick for 10 days with a fever and I'm still coughing",
      );
      expect(result).toMatchObject({ proposalId: null, error: "ramp_not_valid_while_unwell" });
    });

    it("allows a ramp after an illness the user has recovered from", async () => {
      const result = await proposeRampWithRawText(
        "I had the flu last month and never got back into it",
      );
      expect(result).toMatchObject({ category: "readiness_low", riskLevel: "low" });
    });

    it("refuses returning_from_layoff with no ramp instead of persisting a dead-end card", async () => {
      const result = await createPlanAdjustmentProposalFromTool({
        db,
        userId: USER_ID,
        reason: "returning_from_layoff",
        userNote: "been away a while",
        rawUserText: "I fell off",
        clientDate: MONDAY,
      });
      expect(result).toMatchObject({ proposalId: null, error: "ramp_weeks_missing" });
      const all = await db.collection(`users/${USER_ID}/planAdjustmentProposals`).get();
      expect(all.empty).toBe(true);
    });

    it("holds a ramp for review when the raw text trips the severe screen", async () => {
      const result = await createPlanAdjustmentProposalFromTool({
        db,
        userId: USER_ID,
        reason: "returning_from_layoff",
        userNote: "back after time off",
        rampWeeks: RAMP,
        // The severe screen runs on the RAW turn and is absolute — a ramp
        // must not be able to launder a red flag into an auto-appliable
        // proposal just because it only reduces load.
        rawUserText: "I fell off because of numbness shooting down my leg.",
        clientDate: MONDAY,
      });
      expect(result.riskLevel).toBe("high");
      expect(result.requiresFollowUp).toBe(true);
    });
  });

  describe("draft publishing (the two-tap bug)", () => {
    it("keeps a mid-turn proposal invisible until the turn publishes it", async () => {
      const result = await createPlanAdjustmentProposalFromTool({
        db,
        userId: USER_ID,
        reason: "returning_from_layoff",
        userNote: "easing back",
        rampWeeks: [
          { intensityPct: 70, note: "a" },
          { intensityPct: 100, note: "b" },
        ],
        rawUserText: "I fell off",
        clientDate: MONDAY,
      });

      const beforePublish = await db.doc(planAdjustmentProposalPath(USER_ID, result.proposalId!)).get();
      expect(beforePublish.data()?.decision).toBe("draft");

      const published = await publishDraftProposals(db, USER_ID, [result.proposalId!]);
      expect(published.published).toBe(result.proposalId);

      const afterPublish = await db.doc(planAdjustmentProposalPath(USER_ID, result.proposalId!)).get();
      expect(afterPublish.data()?.decision).toBe("pending");
    });

    it("publishes only the newest draft and supersedes the rest in one commit", async () => {
      // The self-correcting tool loop re-calls adapt_plan within one turn.
      // Before this fix each call published its own card, so a user could tap
      // the first one in the window before the second replaced it.
      const first = await createPlanAdjustmentProposalFromTool({
        db,
        userId: USER_ID,
        reason: "returning_from_layoff",
        userNote: "first attempt",
        rampWeeks: [
          { intensityPct: 50, note: "a" },
          { intensityPct: 100, note: "b" },
        ],
        rawUserText: "I fell off",
        clientDate: MONDAY,
      });
      await new Promise((resolve) => setTimeout(resolve, 5));
      const second = await createPlanAdjustmentProposalFromTool({
        db,
        userId: USER_ID,
        reason: "returning_from_layoff",
        userNote: "revised attempt",
        rampWeeks: [
          { intensityPct: 70, note: "a" },
          { intensityPct: 100, note: "b" },
        ],
        rawUserText: "I fell off",
        clientDate: MONDAY,
      });

      const publishResult = await publishDraftProposals(db, USER_ID, [
        first.proposalId!,
        second.proposalId!,
      ]);
      expect(publishResult.published).toBe(second.proposalId);
      expect(publishResult.superseded).toBe(1);

      const firstSnap = await db.doc(planAdjustmentProposalPath(USER_ID, first.proposalId!)).get();
      expect(firstSnap.data()?.decision).toBe("superseded");

      // Exactly one card is visible — the user never sees a swap.
      const pending = await db
        .collection(`users/${USER_ID}/planAdjustmentProposals`)
        .where("decision", "==", "pending")
        .get();
      expect(pending.size).toBe(1);
    });

    it("is a no-op when the turn created no proposal", async () => {
      await expect(publishDraftProposals(db, USER_ID, [])).resolves.toEqual({
        published: null,
        superseded: 0,
      });
    });

    it("never publishes another turn's draft", async () => {
      // A turn that died before publishing leaves an orphan draft. If a later
      // turn published every draft it found, that orphan would resurrect and
      // supersede whatever card the user was actually looking at — a proposal
      // from a conversation they never finished, replacing a live one.
      const orphan = await createPlanAdjustmentProposalFromTool({
        db,
        userId: USER_ID,
        reason: "returning_from_layoff",
        userNote: "orphaned by a dead turn",
        rampWeeks: [
          { intensityPct: 50, note: "a" },
          { intensityPct: 100, note: "b" },
        ],
        rawUserText: "I fell off",
        clientDate: MONDAY,
      });

      // A later, unrelated turn that proposed nothing of its own.
      const laterTurn = await publishDraftProposals(db, USER_ID, []);
      expect(laterTurn.published).toBeNull();

      const orphanSnap = await db.doc(planAdjustmentProposalPath(USER_ID, orphan.proposalId!)).get();
      expect(orphanSnap.data()?.decision).toBe("draft");
    });
  });
});
