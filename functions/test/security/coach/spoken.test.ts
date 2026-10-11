import { describe, expect, it } from "vitest";
import { plainSpeech, spokenSummary } from "../../../src/coach/spoken.js";

describe("spokenSummary — what the voice reads", () => {
  it("a short reply is read whole", () => {
    expect(spokenSummary("Bench is three sets of eight at one fifty-five. Go.")).toBe(
      "Bench is three sets of eight at one fifty-five. Go.",
    );
  });

  it("a paragraph is cut to the sentences that fit", () => {
    const long = Array.from({ length: 8 }, (_, i) => `Sentence number ${i + 1} says a few more words about the plan.`).join(" ");
    const out = spokenSummary(long, 120);
    expect(out.length).toBeLessThanOrEqual(120);
    expect(out.startsWith("Sentence number 1")).toBe(true);
    expect(out.endsWith(".")).toBe(true);
  });

  it("a closing question is kept even when it did not fit", () => {
    const text = "Here is the plan for today in some detail that runs long enough to pass the cap. Want me to adjust it?";
    const out = spokenSummary(text, 90);
    expect(out.endsWith("Want me to adjust it?")).toBe(true);
    expect(out.length).toBeLessThanOrEqual(135);
  });

  it("one over-long sentence is cut at a word", () => {
    const text = "word ".repeat(100).trim();
    const out = spokenSummary(text, 60);
    expect(out.length).toBeLessThanOrEqual(61);
    expect(out.endsWith(".")).toBe(true);
    expect(out).not.toMatch(/wor\.$/);
  });

  it("markdown never reaches the voice", () => {
    expect(plainSpeech("**Bench**: 5x8\n- lower slow\n- pause\n\n1. drive")).toBe("Bench: 5x8. lower slow. pause. drive");
  });
});
