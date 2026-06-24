import { describe, it, expect } from "vitest";
import { retrieveResearchCorpus } from "../../../src/corpus/researchCorpus.js";

// Protocol grounding: the active coaching protocol (preferences.coachingLens)
// must surface its evidence entry so the coach's protocol framing is cited,
// not free-styled — and must NOT pull in protocols the user didn't pick.
describe("coaching-protocol corpus grounding", () => {
  it("surfaces the active protocol's evidence entry on a generic question", () => {
    const result = retrieveResearchCorpus({
      userContent: "should I train legs today?",
      profile: { preferences: { coachingLens: "blueprint" } },
    });
    expect(result.some((e) => e.entryId === "protocol_blueprint_longevity_v1")).toBe(true);
  });

  it("does not surface a protocol the user did not choose", () => {
    const result = retrieveResearchCorpus({
      userContent: "should I train legs today?",
      profile: { preferences: { coachingLens: "blueprint" } },
    });
    expect(result.some((e) => e.entryId === "protocol_huberman_recovery_v1")).toBe(false);
  });

  it("forces no protocol entry when the protocol is the default ('none')", () => {
    const result = retrieveResearchCorpus({
      userContent: "general question about my week",
      profile: { preferences: { coachingLens: "none" } },
    });
    expect(result.some((e) => e.entryId.startsWith("protocol_"))).toBe(false);
  });

  it("still lets topic keywords surface a protocol entry even without selection", () => {
    const result = retrieveResearchCorpus({
      userContent: "how much volume per muscle for hypertrophy?",
      profile: null,
    });
    expect(result.some((e) => e.entryId === "protocol_schoenfeld_hypertrophy_v1")).toBe(true);
  });
});
