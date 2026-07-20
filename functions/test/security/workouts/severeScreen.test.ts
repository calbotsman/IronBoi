import { describe, expect, it } from "vitest";

import { hasSevereMarkers } from "../../../src/workouts/planAdjustments.js";

// Adversarial corpus for the negation-aware severe screen (PR #15 review).
// Pure-function test — no emulator needed. Every phrase here was found by
// probing the screen from both attack directions; keep BOTH lists growing
// whenever a new phrasing slips through in either direction.
//
// LOCK = a severe report the screen must catch (a miss here is a safety
// regression: the proposal becomes appliable at low risk).
// CLEAR = an honest denial or innocent phrase that must NOT lock (a trip
// here re-creates the outage where answering triage honestly pinned every
// proposal at high risk).

const MUST_LOCK: string[] = [
  // Pseudo-negation intensifiers — negation words that emphasize, not deny.
  "not gonna lie sharp pain in my knee",
  "no lie sharp pain shooting down my leg",
  "not kidding sharp pain shooting down",
  "no joke the pain is sharp",
  "nothing helps the sharp pain in my leg",
  "nothing makes the tingling go away",
  "without warning sharp pain in my lower back",
  "no idea why it's numb",
  "not to mention the sharp pain",
  "not even exaggerating my arm is numb",
  // Severity phrased THROUGH negation (superlative family).
  "never felt pain this sharp before, adjust my week",
  "never had pain this severe",
  // Newline / bullet boundaries — a denial must not eat the next line.
  "no numbness\n- sharp pain when I bend",
  "no numbness\nsharp pain when I twist",
  // Contrast and clause boundaries.
  "no numbness but shooting pain down my left leg when I twist",
  "not sure honestly, sharp pain when I bend over",
  "no no, sharp pain when bending",
  // Negation-shaped severe reports (pre-mask family).
  "there is no feeling in my left foot",
  "no more feeling in my toes",
  "I've lost all feeling in my foot",
  "zero feeling in my foot",
  "can’t feel my left foot", // curly apostrophe — iOS smart punctuation
  // Round-2 review: "and"-coordinated deny-then-report chains — a report
  // resumes with a determiner after and/or, which ends the mask.
  "no numbness and my chest pain is back",
  "no bruising and my chest pain came back",
  "no swelling and the pain is sharp",
  "no numbness and the tingling in my chest got worse",
  // Round-2 review: anaphoric new-onset reports built from window words.
  "never had chest pain like this",
  "never felt chest pain like this before",
  "never had this chest pain before",
  "I've never experienced severe pain like this",
  "never felt sharp pain like this",
  "never felt a pop like that in my knee",
  // Round-2 review: comparative "this + symptom adjective" reports.
  "my knee has never been this swollen",
  "my leg has never been this numb",
  "never felt this faint before during a workout",
  // Round-2 review: "able to feel" family + window-stop control.
  "haven't been able to feel my toes",
  "never noticed the numbness until my leg gave out",
  // Plain severe reports (base patterns, no negation involved).
  "chest pain when I go hard",
  "the pain is shooting down my leg",
  "my foot went numb halfway through",
];

const MUST_CLEAR: string[] = [
  // The live E2E phrasing that started all of this.
  "no sharp pain, no numbness, nothing radiating, just a dull ache from yesterday — adjust this week please",
  // Joint denial lists — arbitrarily long, and/or are NOT stoppers.
  "no numbness or tingling or radiating pain",
  "pain-free, no numbness or tingling or anything radiating",
  "not experiencing any of the numbness or tingling",
  "haven't had any of that numbness stuff",
  "haven't passed out or felt faint",
  "no swelling or bruising or anything like that",
  "without any sharp or shooting pain",
  // Simple denials in many shapes.
  "no sharp pains",
  "never had numbness",
  "denies tingling",
  "denying any numbness or tingling",
  "haven't felt any radiating pain",
  "I don’t have any numbness", // curly apostrophe
  "no pins and needles",
  "nothing radiating",
  "no shooting pain down my leg",
  "no pain at all",
  // Improvement reports (recovery check-ins must not lock).
  "not so sharp anymore, feeling better",
  // Round-2 review: bare-noun joint denial after "and" (no determiner).
  "no numbness and tingling",
  // Round-2 review: improvement reports use "that" with state verbs.
  "the pain isn't that sharp anymore",
  "hasn't been that swollen lately",
  // Round-2 review: intensity chat must not lock (superlative is anchored
  // to pain nouns / state verbs, not programs and splits).
  "is this intense enough for me",
  "I've never done a program this intense",
  "this severe workout split",
  "keep the programming that sharp",
  // Innocent fitness vocabulary near the pattern space.
  "lower the numbers on squats",
  "can't move my Thursday session to Friday",
  "no feelings either way about swapping bench for dumbbells",
];

describe("hasSevereMarkers — negation-aware screen corpus", () => {
  for (const phrase of MUST_LOCK) {
    it(`LOCKS: ${JSON.stringify(phrase)}`, () => {
      expect(hasSevereMarkers(phrase)).toBe(true);
    });
  }
  for (const phrase of MUST_CLEAR) {
    it(`CLEARS: ${JSON.stringify(phrase)}`, () => {
      expect(hasSevereMarkers(phrase)).toBe(false);
    });
  }
});
