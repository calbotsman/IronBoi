import { describe, expect, it } from "vitest";
import { computeHabitMetrics } from "../../../src/journey/metrics.js";

const DAY = 24 * 60 * 60 * 1000;
const NOW = Date.parse("2026-10-12T12:00:00Z");
const daysAgo = (n: number) => NOW - n * DAY;

describe("computeHabitMetrics — counts only", () => {
  it("activation: first workout within 48h, only for people signed up 48h+ ago", () => {
    const m = computeHabitMetrics(
      [
        { signupAt: daysAgo(10), workoutAts: [daysAgo(9.5)] }, // activated
        { signupAt: daysAgo(10), workoutAts: [daysAgo(5)] }, // too late
        { signupAt: daysAgo(1), workoutAts: [] }, // too new to judge
      ],
      NOW,
    );
    expect(m.users).toBe(3);
    expect(m.activation48h).toEqual({ hit: 1, of: 2 });
  });

  it("second workout within 7 days of the first", () => {
    const m = computeHabitMetrics(
      [
        { signupAt: daysAgo(30), workoutAts: [daysAgo(29), daysAgo(26)] },
        { signupAt: daysAgo(30), workoutAts: [daysAgo(29), daysAgo(15)] },
        { signupAt: daysAgo(5), workoutAts: [daysAgo(4)] }, // first too recent
      ],
      NOW,
    );
    expect(m.secondWorkoutIn7d).toEqual({ hit: 1, of: 2 });
  });

  it("week 4 and week 12 retention", () => {
    const m = computeHabitMetrics(
      [
        { signupAt: daysAgo(90), workoutAts: [daysAgo(90 - 23), daysAgo(90 - 80)] },
        { signupAt: daysAgo(40), workoutAts: [daysAgo(39)] },
      ],
      NOW,
    );
    expect(m.week4Active).toEqual({ hit: 1, of: 2 });
    expect(m.week12Active).toEqual({ hit: 1, of: 1 });
  });

  it("weeks with 2+ workouts over the last four weeks", () => {
    const m = computeHabitMetrics(
      [{ signupAt: daysAgo(60), workoutAts: [daysAgo(1), daysAgo(3), daysAgo(8), daysAgo(15), daysAgo(16), daysAgo(50)] }],
      NOW,
    );
    // Weeks (newest first): 2, 1, 2, 0 workouts.
    expect(m.weeksWith2Plus).toEqual({ hit: 2, of: 4 });
  });

  it("comebacks after a 14+ day gap", () => {
    const m = computeHabitMetrics(
      [
        // Lapsed ~59 days ago (last workout 73 days ago), back 40 days ago.
        { signupAt: daysAgo(120), workoutAts: [daysAgo(73), daysAgo(40)] },
        // Lapsed ~50 days ago, never back.
        { signupAt: daysAgo(120), workoutAts: [daysAgo(64)] },
      ],
      NOW,
    );
    expect(m.comebacks).toEqual({ hit: 1, of: 2 });
  });

  it("output carries no user identifiers", () => {
    const m = computeHabitMetrics([{ signupAt: daysAgo(10), workoutAts: [daysAgo(9)] }], NOW);
    // Every value is a number or a { hit, of } pair of numbers — no strings,
    // so nothing that could name a person.
    for (const value of Object.values(m)) {
      if (typeof value === "number") continue;
      expect(Object.keys(value).sort()).toEqual(["hit", "of"]);
      expect(typeof value.hit).toBe("number");
      expect(typeof value.of).toBe("number");
    }
  });
});
