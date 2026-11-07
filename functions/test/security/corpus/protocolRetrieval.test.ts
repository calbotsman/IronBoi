import { describe, it, expect } from "vitest";
import { RESEARCH_CORPUS, retrieveResearchCorpus } from "../../../src/corpus/researchCorpus.js";

// Named coaching protocols (Huberman, Schoenfeld, Sims, Blueprint) are
// retired: the corpus carries no protocol entries, and a profile that still
// names one must not change what is retrieved.
describe("retired coaching protocols in the corpus", () => {
  it("has no named-protocol entries", () => {
    expect(RESEARCH_CORPUS.some((e) => e.entryId.startsWith("protocol_"))).toBe(false);
    expect(JSON.stringify(RESEARCH_CORPUS)).not.toMatch(/huberman|schoenfeld|blueprint|stacy sims/i);
  });

  it("ignores a legacy coachingLens on the profile", () => {
    const question = "should I train legs today?";
    const withLens = retrieveResearchCorpus({
      userContent: question,
      profile: { preferences: { coachingLens: "blueprint" } },
    });
    const without = retrieveResearchCorpus({
      userContent: question,
      profile: { preferences: {} },
    });
    expect(withLens.map((e) => e.entryId)).toEqual(without.map((e) => e.entryId));
  });

  it("still grounds hypertrophy questions in the resistance-training evidence", () => {
    const result = retrieveResearchCorpus({
      userContent: "how much volume per muscle for hypertrophy?",
      profile: null,
    });
    expect(result.some((e) => e.entryId === "acsm_resistance_training_healthy_adults_2026")).toBe(true);
  });
});
