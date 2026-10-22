import { describe, expect, it } from "vitest";
import { reviseDraftFromWords, revisionReply } from "../../../src/onboarding/revise.js";

const base = {
  preferredDays: ["Mon", "Wed", "Fri"],
  equipment: ["dumbbells"],
  injuriesOrLimitations: ["none"],
  sessionLengthMin: 45,
};

describe("talking about the drafted week", () => {
  it("swaps a day", () => {
    const { draft, changes } = reviseDraftFromWords(base, "Can we do Tuesday instead of Monday?");
    expect(draft.preferredDays).toEqual(["Tue", "Wed", "Fri"]);
    expect(changes[0]).toMatch(/Tue, Wed, Fri/);
  });
  it("replaces the days when only new ones are named", () => {
    expect(reviseDraftFromWords(base, "I can only train Tuesday and Thursday").draft.preferredDays).toEqual(["Tue", "Thu"]);
  });
  it("reads session length", () => {
    expect(reviseDraftFromWords(base, "I only have 30 minutes").draft.sessionLengthMin).toBe(30);
    expect(reviseDraftFromWords(base, "about an hour is fine").draft.sessionLengthMin).toBe(60);
  });
  it("adds gear", () => {
    expect(reviseDraftFromWords(base, "I also have kettlebells and a medicine ball").draft.equipment)
      .toEqual(expect.arrayContaining(["dumbbells", "kettlebells", "medicine ball"]));
  });
  it("keeps pain as a limitation, in their words", () => {
    const { draft } = reviseDraftFromWords(base, "My left knee hurts when I squat deep.");
    expect(draft.injuriesOrLimitations).toEqual(["My left knee hurts when I squat deep".toLowerCase()]);
  });
  it("keeps everything said as a note, and says honestly when nothing changed", () => {
    const { draft, changes } = reviseDraftFromWords(base, "I like training in the morning with music");
    expect(changes).toEqual([]);
    expect(draft.planNotes).toEqual(["I like training in the morning with music"]);
    expect(revisionReply(changes)).toMatch(/keep that in mind/);
  });
});
