import { describe, expect, it } from "vitest";
import { hasSevereMarkers, stripClinicalDenials } from "../../../src/workouts/planAdjustments.js";

// How a model writes up CLEAN red-flag answers. Every one of these tripped
// the severe screen and locked the proposal at high risk (nightly E2E,
// 2026-10-06/07/11). The user's own words were "no sharp pain, no numbness,
// nothing radiating, just a dull ache".
const cleanWriteUps = [
  "User reports a dull ache in the lower back; denies sharp pain, numbness, or radiating pain.",
  "Dull lower back ache since yesterday. Red flags (sharp/shooting pain, numbness/tingling, radiating) denied.",
  "Lower back dull ache from yesterday, without sharp pain, numbness or radiation.",
  "dull ache in back; sharp pain: no; numbness: no; radiating: no",
  "Back pain. No red flags reported (sharp, numbness, radiating).",
  "Dull ache only. Negative for sharp pain, numbness, tingling and radiation.",
  "Lower back, dull, 2/10. Sharp/shooting pain, numbness/tingling, radiating symptoms all denied.",
];

// Severe content a model must not be able to launder with a denial clause.
const stillSevere = [
  "Denies numbness but reports sharp, shooting pain radiating down the left leg.",
  "Sharp shooting pain radiating down the leg; denies numbness.",
  "Denies numbness, except when sitting, when sharp pain shoots down the leg.",
];

describe("severe screen on model-authored triage text", () => {
  it("a clean write-up with clinical denials is clean", () => {
    for (const text of cleanWriteUps) {
      expect(hasSevereMarkers(stripClinicalDenials(text)), text).toBe(false);
    }
  });

  it("a denial clause cannot hide severe content elsewhere in the sentence", () => {
    for (const text of stillSevere) {
      expect(hasSevereMarkers(stripClinicalDenials(text)), text).toBe(true);
    }
  });

  it("a label before a colon is not a denial: the negation mask handles it", () => {
    expect(hasSevereMarkers(stripClinicalDenials("Lower back: no sharp pain, no numbness. Dull ache."))).toBe(false);
    expect(hasSevereMarkers(stripClinicalDenials("Lower back: sharp pain radiating down the leg."))).toBe(true);
  });

  it("the user's raw words are never stripped: a pseudo-negation stays severe", () => {
    // The raw turn goes to hasSevereMarkers directly (see
    // createPlanAdjustmentProposalFromTool); this documents why.
    expect(hasSevereMarkers("without warning, sharp pain shot down my leg")).toBe(true);
  });
});
