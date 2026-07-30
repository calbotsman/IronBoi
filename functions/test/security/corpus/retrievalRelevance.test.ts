import { describe, expect, it } from "vitest";
import { retrieveResearchCorpus } from "../../../src/corpus/researchCorpus.js";

function idsFor(userContent: string): string[] {
  return retrieveResearchCorpus({ userContent, profile: null, maxEntries: 4 }).map(
    (entry) => entry.entryId,
  );
}

// The corpus decides what evidence the coach is handed, and prompt.ts tells the
// model to stay generic when nothing relevant comes back. So bad retrieval reads
// to the user as a stupid coach — which is exactly what happened: "I don't have
// the vertical height in my basement for overhead press" retrieved nothing but
// the generic baseline, and "no rack at home, can you swap back squats"
// retrieved PREGNANCY and PAIN guidance.
//
// Two root causes, both fixed here:
//   1. the keyword-boost loop sat inside the per-entry map but never read
//      `entry`, so every match scored every one of the 19 entries equally
//   2. body-part words ("back", "knee", "shoulder", "ankle") were injury terms,
//      and they are all lift names
describe("corpus retrieval relevance", () => {
  describe("space and equipment constraints reach real guidance", () => {
    it.each([
      "I dont have vertical height in my basement for overhead press",
      "no rack at home, can you swap back squats",
      "my gym only has dumbbells up to 30lb",
      "swap my shoulder press, the ceiling is too low",
      "only have bands in the hotel room",
    ])("%j retrieves the equipment/space entry", (query) => {
      expect(idsFor(query)).toContain("myo_equipment_and_space_constraint_v1");
    });

    it.each([
      "no rack at home, can you swap back squats",
      "swap my shoulder press, the ceiling is too low",
      "my basement ceiling is too low for overhead press",
    ])("%j does NOT retrieve clinical guidance", (query) => {
      const ids = idsFor(query);
      expect(ids).not.toContain("myo_pain_injury_adjustment_v1");
      expect(ids).not.toContain("acog_exercise_pregnancy_faq_2026");
    });
  });

  // The safety half. Scoping the boost must not stop real clinical topics from
  // retrieving their guidance — that would be the dangerous direction.
  describe("clinical topics still retrieve clinical guidance", () => {
    it("pain reaches the pain/injury entry", () => {
      expect(idsFor("my knee hurts when I squat")).toContain("myo_pain_injury_adjustment_v1");
    });

    it("a symptom with no body part still reaches it", () => {
      expect(idsFor("something is really sore and swollen")).toContain(
        "myo_pain_injury_adjustment_v1",
      );
    });

    it("pregnancy reaches pregnancy guidance", () => {
      expect(idsFor("Im 6 weeks postpartum, how should I train")).toContain(
        "acog_exercise_pregnancy_faq_2026",
      );
    });

    it("a chronic condition reaches its guidance", () => {
      expect(idsFor("I have diabetes, is this plan ok")).toContain(
        "ada_physical_activity_diabetes_2016",
      );
    });

    it("protein reaches nutrition guidance", () => {
      expect(idsFor("how much protein should I eat")).toContain("issn_protein_exercise_2017");
    });
  });

  describe("a layoff retrieves schedule guidance", () => {
    it.each([
      "I fell off for a month, ease me back in",
      "havent trained in weeks",
      "took some time off, want to start again",
    ])("%j retrieves the schedule-disruption entry", (query) => {
      expect(idsFor(query)).toContain("myo_schedule_disruption_v1");
    });
  });

  describe("scoping", () => {
    it("does not drag the whole corpus into an unrelated query", () => {
      // The uniform-boost bug filled all four slots with whatever scored the
      // baseline bonus. A narrow query should return a short, on-topic list.
      const ids = idsFor("my basement ceiling is too low for overhead press");
      expect(ids.length).toBeLessThanOrEqual(2);
    });

    it("keeps a plain greeting from retrieving clinical material", () => {
      const ids = idsFor("hey, hows it going");
      expect(ids).not.toContain("acog_exercise_pregnancy_faq_2026");
      expect(ids).not.toContain("myo_pain_injury_adjustment_v1");
    });
  });
});
