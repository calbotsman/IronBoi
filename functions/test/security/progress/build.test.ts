import { describe, expect, it } from "vitest";
import {
  buildProgressSummary,
  type ProgressBuildInputs,
} from "../../../src/progress/build.js";

// Pure-builder fixture tests — no emulator, no Firestore. The window is
// anchored at 2026-07-16, so the 42-day window covers 2026-06-05..2026-07-16
// and the six chronological week buckets are:
//   idx0: 06-05..06-11   idx1: 06-12..06-18   idx2: 06-19..06-25
//   idx3: 06-26..07-02   idx4: 07-03..07-09   idx5: 07-10..07-16
const TODAY = "2026-07-16T12:00:00.000Z";

let sessionCounter = 0;

type FixtureSet = { reps?: number; loadKg?: number; durationSec?: number };

function log(
  date: string,
  exercises: Array<{ name: string; sets: FixtureSet[] }> = [
    { name: "Bench Press", sets: [{ reps: 5, loadKg: 100 }] },
  ],
) {
  sessionCounter += 1;
  return {
    userId: "u-1",
    sessionId: `session-${sessionCounter}`,
    date,
    source: "manual",
    exercises,
    createdAt: `${date}T10:00:00.000Z`,
  };
}

function weightSample(startDate: string, kg: number) {
  return { category: "body_weight_kg", value: kg, startDate };
}

function threeDayPlan() {
  const trainingDay = (name: string) => ({
    name,
    muscles: [],
    exercises: [{ name: "Bench Press", sets: 3, reps: 5, weight: 100 }],
  });
  return {
    userId: "u-1",
    planId: "current",
    source: "coach_generated",
    days: {
      Mon: trainingDay("Push"),
      Wed: trainingDay("Pull"),
      Fri: trainingDay("Legs"),
      // Rest day with no exercises must NOT count as a planned session.
      Sun: { name: "Rest", muscles: [], exercises: [] },
    },
    updatedAt: TODAY,
  };
}

function build(partial: Partial<ProgressBuildInputs>) {
  return buildProgressSummary({
    logs: [],
    healthSamples: [],
    program: null,
    plan: null,
    profile: null,
    userId: "u-1",
    todayISO: TODAY,
    ...partial,
  });
}

describe("buildProgressSummary — adherence", () => {
  it("counts planned vs completed per week, rates, and the streak", () => {
    const logs = [
      // idx2 — 2 of 3 planned.
      log("2026-06-20"),
      log("2026-06-22"),
      // idx3..idx5 — 3 of 3 planned each (streak of 3).
      log("2026-06-26"),
      log("2026-06-29"),
      log("2026-07-01"),
      log("2026-07-03"),
      log("2026-07-05"),
      log("2026-07-08"),
      log("2026-07-10"),
      log("2026-07-12"),
      log("2026-07-14"),
      // Outside the window (too old / in the future) — must be ignored.
      log("2026-06-01"),
      log("2026-07-20"),
    ];

    const summary = build({ logs, plan: threeDayPlan() });

    expect(summary.adherence).toEqual({
      plannedSessions: 18, // 3 non-empty plan days × 6 weeks
      completedSessions: 11,
      weeklyRate: [0, 0, 0.67, 1, 1, 1],
      streakWeeks: 3,
    });
  });

  it("falls back to the program's active week when no flattened plan exists", () => {
    const program = {
      userId: "u-1",
      programId: "current",
      startDate: "2026-06-05",
      activeWeekIndex: 1,
      weeks: [
        { weekIndex: 0, days: { Mon: { name: "A", exercises: [{ name: "Row", sets: 3, reps: 8, weight: 40 }] } } },
        {
          weekIndex: 1,
          days: {
            Mon: { name: "A", exercises: [{ name: "Row", sets: 3, reps: 8, weight: 40 }] },
            Thu: { name: "B", exercises: [{ name: "Press", sets: 3, reps: 8, weight: 30 }] },
          },
        },
      ],
      source: "coach_generated",
      updatedAt: TODAY,
    };

    const summary = build({ program });
    expect(summary.adherence.plannedSessions).toBe(12); // 2 days × 6 weeks
  });

  it("caps a weekly rate at 1 even when the user trains beyond the plan", () => {
    const oneDayPlan = {
      ...threeDayPlan(),
      days: { Mon: threeDayPlan().days.Mon },
    };
    const logs = [log("2026-07-10"), log("2026-07-12"), log("2026-07-14")];
    const summary = build({ logs, plan: oneDayPlan });
    expect(summary.adherence.weeklyRate[5]).toBe(1);
    expect(summary.adherence.completedSessions).toBe(3);
  });
});

describe("buildProgressSummary — volume", () => {
  it("sums reps × loadKg per week and calls the halves trend", () => {
    const oneSet = [{ name: "Bench Press", sets: [{ reps: 10, loadKg: 100 }] }];
    const twoSets = [
      { name: "Bench Press", sets: [{ reps: 10, loadKg: 100 }, { reps: 10, loadKg: 100 }] },
    ];
    const logs = [
      log("2026-06-07", oneSet), // idx0 → 1000
      log("2026-06-14", oneSet), // idx1 → 1000
      log("2026-06-21", oneSet), // idx2 → 1000
      log("2026-06-28", twoSets), // idx3 → 2000
      log("2026-07-05", twoSets), // idx4 → 2000
      log("2026-07-12", twoSets), // idx5 → 2000
    ];

    const summary = build({ logs });
    expect(summary.volume.weeklyTotals).toEqual([1000, 1000, 1000, 2000, 2000, 2000]);
    expect(summary.volume.trend).toBe("up");
  });

  it("ignores duration-only and bodyweight sets in the volume total", () => {
    const logs = [
      log("2026-07-12", [
        { name: "Plank", sets: [{ durationSec: 60 }] },
        { name: "Push Ups", sets: [{ reps: 15 }] }, // no loadKg
        { name: "Bench Press", sets: [{ reps: 5, loadKg: 60 }] },
      ]),
    ];
    const summary = build({ logs });
    expect(summary.volume.weeklyTotals[5]).toBe(300);
  });
});

describe("buildProgressSummary — lifts (Epley e1RM)", () => {
  it("takes the best set per session and trends first→last across the window", () => {
    const logs = [
      log("2026-06-27", [
        { name: "Bench Press", sets: [{ reps: 5, loadKg: 100 }] }, // e1RM 116.67
      ]),
      log("2026-07-06", [
        { name: "Bench Press", sets: [{ reps: 5, loadKg: 102.5 }] }, // 119.58
      ]),
      log("2026-07-13", [
        {
          name: "Bench Press",
          sets: [
            { reps: 5, loadKg: 105 }, // 122.5 — the best set
            { reps: 10, loadKg: 60 }, // 80 — must not win
          ],
        },
        { name: "Squat", sets: [{ reps: 3, loadKg: 140 }] }, // single session
      ]),
    ];

    const summary = build({ logs });

    expect(summary.lifts[0].exerciseName).toBe("Bench Press");
    expect(summary.lifts[0].e1rmSeries).toEqual([
      { date: "2026-06-27", value: 116.7 },
      { date: "2026-07-06", value: 119.6 },
      { date: "2026-07-13", value: 122.5 },
    ]);
    // (122.5 − 116.667) / 116.667 × 100 = 5.0 — computed on unrounded values.
    expect(summary.lifts[0].trendPct).toBe(5);

    // A single-session lift has no trend.
    const squat = summary.lifts.find((lift) => lift.exerciseName === "Squat");
    expect(squat?.trendPct).toBe(0);
    expect(squat?.e1rmSeries).toHaveLength(1);
  });

  it("excludes bodyweight-only movements and keeps the top 5 by frequency", () => {
    const liftNames = ["Alpha", "Bravo", "Charlie", "Delta", "Echo"];
    const logs = [
      // Each named lift appears twice; Foxtrot once; Push Ups (bodyweight) thrice.
      ...["2026-07-01", "2026-07-08"].map((date) =>
        log(
          date,
          liftNames.map((name) => ({ name, sets: [{ reps: 5, loadKg: 50 }] })),
        ),
      ),
      log("2026-07-10", [{ name: "Foxtrot", sets: [{ reps: 5, loadKg: 50 }] }]),
      ...["2026-07-11", "2026-07-12", "2026-07-13"].map((date) =>
        log(date, [{ name: "Push Ups", sets: [{ reps: 20 }] }]),
      ),
    ];

    const summary = build({ logs });

    expect(summary.lifts).toHaveLength(5);
    expect(summary.lifts.map((lift) => lift.exerciseName)).toEqual(liftNames);
    expect(JSON.stringify(summary.lifts)).not.toContain("Push Ups");
  });

  it("caps a lift's series to the 8 most recent sessions but trends the full window", () => {
    // 10 sessions, load climbing 100 → 145 kg in 5 kg steps.
    const dates = [
      "2026-06-06", "2026-06-10", "2026-06-14", "2026-06-18", "2026-06-22",
      "2026-06-26", "2026-06-30", "2026-07-04", "2026-07-08", "2026-07-12",
    ];
    const logs = dates.map((date, index) =>
      log(date, [{ name: "Deadlift", sets: [{ reps: 1, loadKg: 100 + index * 5 }] }]),
    );

    const summary = build({ logs });
    const deadlift = summary.lifts[0];

    expect(deadlift.e1rmSeries).toHaveLength(8);
    // Capped to the most recent 8 sessions: the first two dates drop off.
    expect(deadlift.e1rmSeries[0].date).toBe("2026-06-14");
    expect(deadlift.e1rmSeries[7].date).toBe("2026-07-12");
    // Trend still spans the FULL window: (145 − 100) / 100 = 45%.
    expect(deadlift.trendPct).toBe(45);
  });
});

describe("buildProgressSummary — body weight & safe band", () => {
  const fatLossProfile = { goals: ["fat_loss"] };
  const weeklyDates = [
    "2026-06-05", "2026-06-12", "2026-06-19", "2026-06-26",
    "2026-07-03", "2026-07-10", "2026-07-16",
  ];

  it("classifies an on-band loss for a fat-loss goal as within the safe band", () => {
    // ~0.44%/wk of loss — inside the 0.25–1%/wk band.
    const kgs = [90, 89.6, 89.2, 88.8, 88.4, 88.0, 87.7];
    const summary = build({
      healthSamples: weeklyDates.map((date, i) => weightSample(`${date}T08:00:00.000Z`, kgs[i])),
      profile: fatLossProfile,
    });

    expect(summary.body.goalDirection).toBe("down");
    expect(summary.body.trendPctPerWeek).toBeLessThan(-0.25);
    expect(summary.body.trendPctPerWeek).toBeGreaterThan(-1);
    expect(summary.body.withinSafeBand).toBe(true);
    // Rolling average over the trailing 7 calendar days (07-10 and 07-16).
    expect(summary.body.rollingAvgKg).toBeCloseTo(87.85, 2);
  });

  it("flags too-fast loss as outside the safe band (a caution, never a win)", () => {
    // ~1.4%/wk of loss — faster than the 1%/wk safety ceiling.
    const kgs = [90, 88.8, 87.6, 86.4, 85.2, 84, 83];
    const summary = build({
      healthSamples: weeklyDates.map((date, i) => weightSample(`${date}T08:00:00.000Z`, kgs[i])),
      profile: fatLossProfile,
    });

    expect(summary.body.trendPctPerWeek).toBeLessThan(-1);
    expect(summary.body.withinSafeBand).toBe(false);
  });

  it("flags rapid loss even when the goal wants weight to go up", () => {
    const kgs = [90, 88.8, 87.6, 86.4, 85.2, 84, 83];
    const summary = build({
      healthSamples: weeklyDates.map((date, i) => weightSample(`${date}T08:00:00.000Z`, kgs[i])),
      profile: { goals: ["muscle_gain"] },
    });

    expect(summary.body.goalDirection).toBe("up");
    expect(summary.body.withinSafeBand).toBe(false);
  });

  it("reads a plateau under a fat-loss goal as SAFE (off-target is not unsafe)", () => {
    const summary = build({
      healthSamples: weeklyDates.map((date) => weightSample(`${date}T08:00:00.000Z`, 90)),
      profile: fatLossProfile,
    });

    expect(summary.body.trendPctPerWeek).toBe(0);
    // Operator decision 2026-07-17: withinSafeBand is PURE safety — only
    // loss faster than 1%/wk flags. "On track" is derived separately from
    // trendPctPerWeek + goalDirection.
    expect(summary.body.withinSafeBand).toBe(true);
  });

  it("treats slow gain under a muscle-gain goal as safe", () => {
    const kgs = [80, 80.1, 80.3, 80.4, 80.5, 80.7, 80.8];
    const summary = build({
      healthSamples: weeklyDates.map((date, i) => weightSample(`${date}T08:00:00.000Z`, kgs[i])),
      profile: { goals: ["muscle_gain"] },
    });

    expect(summary.body.goalDirection).toBe("up");
    expect(summary.body.trendPctPerWeek).toBeGreaterThan(0);
    expect(summary.body.withinSafeBand).toBe(true);
  });

  it("averages same-day samples and downsamples long series to 8 points with endpoints", () => {
    const samples = [];
    // 42 daily points, plus a duplicate on the first day to test averaging.
    for (let offset = 41; offset >= 0; offset -= 1) {
      const ms = Date.parse(TODAY) - offset * 86_400_000;
      const date = new Date(ms).toISOString();
      samples.push(weightSample(date, 88));
    }
    samples.push(weightSample("2026-06-05T20:00:00.000Z", 90)); // avg with 88 → 89

    const summary = build({ healthSamples: samples });

    expect(summary.body.weightSeries).toHaveLength(8);
    expect(summary.body.weightSeries[0]).toEqual({ date: "2026-06-05", kg: 89 });
    expect(summary.body.weightSeries[7]).toEqual({ date: "2026-07-16", kg: 88 });
  });

  it("keeps a single weigh-in without inventing a trend", () => {
    const summary = build({
      healthSamples: [weightSample("2026-07-15T08:00:00.000Z", 88)],
      profile: fatLossProfile,
    });

    expect(summary.body.weightSeries).toEqual([{ date: "2026-07-15", kg: 88 }]);
    expect(summary.body.rollingAvgKg).toBe(88);
    expect(summary.body.trendPctPerWeek).toBeUndefined();
    // No computable trend → no evidence of an unsafe rate.
    expect(summary.body.withinSafeBand).toBe(true);
  });
});

describe("buildProgressSummary — sparse and malformed data", () => {
  it("produces a valid empty summary with no inputs at all", () => {
    const summary = build({});

    expect(summary).toEqual({
      userId: "u-1",
      computedAt: TODAY,
      windowDays: 42,
      adherence: {
        plannedSessions: 0,
        completedSessions: 0,
        weeklyRate: [0, 0, 0, 0, 0, 0],
        streakWeeks: 0,
      },
      volume: {
        weeklyTotals: [0, 0, 0, 0, 0, 0],
        trend: "flat",
      },
      lifts: [],
      body: {
        weightSeries: [],
        goalDirection: "flat",
        withinSafeBand: true,
      },
    });
    // The builder strict-parses its own output, so NaN anywhere would have
    // thrown — but pin it explicitly for the empty case.
    expect(JSON.stringify(summary)).not.toContain("NaN");
  });

  it("skips malformed docs instead of crashing or emitting NaN", () => {
    const summary = build({
      logs: [
        { date: 20260710 } as never, // non-string date
        { date: "2026-07-11", exercises: "not-an-array" } as never,
        log("2026-07-12", [{ name: "Bench Press", sets: [{ reps: 5, loadKg: 80 }] }]),
      ],
      healthSamples: [
        { category: "body_weight_kg", value: "heavy", startDate: "2026-07-10T08:00:00.000Z" } as never,
        { category: "steps", value: 10_000, startDate: "2026-07-10T08:00:00.000Z" },
        weightSample("garbage-date", 88),
      ],
      plan: { days: "not-a-map" } as never,
    });

    // The unparseable-date log is dropped; the valid-date log with garbage
    // exercises still counts as a completed session (the user showed up —
    // only its volume/lift contribution is lost).
    expect(summary.adherence.completedSessions).toBe(2);
    expect(summary.volume.weeklyTotals[5]).toBe(400); // only the well-formed log
    expect(summary.body.weightSeries).toEqual([]);
    expect(JSON.stringify(summary)).not.toContain("NaN");
  });
});

describe("buildProgressSummary — lens highlights (slice 5)", () => {
  function lensProfile(lens: string) {
    return {
      goals: ["general_fitness"],
      preferences: { coachingTone: "balanced", coachingLens: lens },
    };
  }

  // Enough logs for a 1-week streak on the 3-day plan, plus a rising bench.
  const trainingLogs = [
    log("2026-06-27", [{ name: "Bench Press", sets: [{ reps: 5, loadKg: 100 }] }]),
    log("2026-07-06", [{ name: "Bench Press", sets: [{ reps: 5, loadKg: 102.5 }] }]),
    log("2026-07-10", [{ name: "Bench Press", sets: [{ reps: 5, loadKg: 105 }] }]),
    log("2026-07-12", [{ name: "Bench Press", sets: [{ reps: 5, loadKg: 105 }] }]),
    log("2026-07-14", [{ name: "Bench Press", sets: [{ reps: 5, loadKg: 105 }] }]),
  ];

  it("huberman leads with consistency and promises (never fakes) recovery signals", () => {
    const summary = build({
      logs: trainingLogs,
      plan: threeDayPlan(),
      profile: lensProfile("huberman"),
    });

    expect(summary.lensHighlights).toHaveLength(1);
    const [highlight] = summary.lensHighlights ?? [];
    expect(highlight.metric).toBe("consistency");
    expect(highlight.framing).toContain("5 sessions in 6 weeks");
    expect(highlight.framing).toContain("nervous system's best friend");
    // recovery is unpopulated in slices 1-3: the note points at the future
    // HealthKit connection instead of inventing an HRV/sleep reading.
    expect(highlight.note).toContain("1-week streak");
    expect(highlight.note).toContain("once HealthKit is connected");
    expect(JSON.stringify(summary.lensHighlights)).not.toMatch(/HRV (is|was|trend(ed|ing))/i);
  });

  it("schoenfeld headlines the volume trend and the top lift's e1RM trend", () => {
    const summary = build({
      logs: trainingLogs,
      plan: threeDayPlan(),
      profile: lensProfile("schoenfeld"),
    });

    expect(summary.lensHighlights?.map((h) => h.metric)).toEqual([
      "volume_trend",
      "top_lift_e1rm",
    ]);
    const [volume, lift] = summary.lensHighlights ?? [];
    // Training starts mid-window → halves trend reads up.
    expect(volume.framing).toBe(
      "Weekly working volume is trending up across the 6-week window",
    );
    expect(volume.note).toContain("Progressive overload is the signal that matters");
    expect(volume.note).toContain("1575 kg"); // 3 sessions × (5 × 105) in the newest bucket
    // (122.5 − 116.667) / 116.667 = 5% across the window, same as the lifts test.
    expect(lift.framing).toBe("Bench Press e1RM up 5% over the 6-week window");
    expect(lift.note).toContain("best set each session");
  });

  it("sims reframes adherence as readiness and makes NO cycle claims without data", () => {
    const summary = build({
      logs: trainingLogs,
      plan: threeDayPlan(),
      profile: lensProfile("sims"),
    });

    expect(summary.lensHighlights).toHaveLength(1);
    const [highlight] = summary.lensHighlights ?? [];
    expect(highlight.metric).toBe("readiness");
    expect(highlight.framing).toContain("5 sessions logged in 6 weeks");
    expect(highlight.note).toContain("only if you opt in");
    // No cycle claim may exist before the consent-gated cycle-data slice.
    expect(JSON.stringify(summary.lensHighlights)).not.toMatch(
      /luteal|follicular|your cycle (is|was)|phase of your cycle/i,
    );
  });

  it("blueprint frames streak + adherence as consistency over intensity, no biohacking", () => {
    const summary = build({
      logs: trainingLogs,
      plan: threeDayPlan(),
      profile: lensProfile("blueprint"),
    });

    expect(summary.lensHighlights).toHaveLength(1);
    const [highlight] = summary.lensHighlights ?? [];
    expect(highlight.metric).toBe("streak");
    expect(highlight.framing).toBe(
      "1-week streak, 5 of 18 planned sessions — consistency over intensity",
    );
    expect(highlight.note).toContain("The habit is the protocol");
    // The prompt guardrail, enforced at the string level: never supplements,
    // biomarkers, or age-reversal framing.
    expect(JSON.stringify(summary.lensHighlights)).not.toMatch(
      /supplement|biomarker|age.?reversal|epigenetic|blood ?panel/i,
    );
  });

  it("blueprint defers to the safety caution when the loss rate is outside the band", () => {
    const weeklyDates = [
      "2026-06-05", "2026-06-12", "2026-06-19", "2026-06-26",
      "2026-07-03", "2026-07-10", "2026-07-16",
    ];
    const kgs = [90, 88.8, 87.6, 86.4, 85.2, 84, 83]; // ~1.4%/wk loss
    const summary = build({
      logs: trainingLogs,
      plan: threeDayPlan(),
      healthSamples: weeklyDates.map((date, i) => weightSample(`${date}T08:00:00.000Z`, kgs[i])),
      profile: { ...lensProfile("blueprint"), goals: ["fat_loss"] },
    });

    expect(summary.body.withinSafeBand).toBe(false);
    const [highlight] = summary.lensHighlights ?? [];
    expect(highlight.note).toContain("faster than the safe pace");
    expect(highlight.note).not.toContain("The habit is the protocol");
  });

  it("omits the field for lens none and for unknown lens values", () => {
    for (const lens of ["none", "keto-warrior"]) {
      const summary = build({
        logs: trainingLogs,
        plan: threeDayPlan(),
        profile: lensProfile(lens),
      });
      expect(summary.lensHighlights).toBeUndefined();
      expect("lensHighlights" in summary).toBe(false);
    }
  });

  it("degrades to an omitted field when there is no data to frame, for every lens", () => {
    for (const lens of ["huberman", "schoenfeld", "sims", "blueprint"]) {
      const summary = build({ profile: lensProfile(lens) });
      expect(summary.lensHighlights).toBeUndefined();
    }
  });

  it("clamps a pathological exercise name so the framing respects the contract cap", () => {
    const longName = "Extremely Long Machine Name ".repeat(6).trim(); // > 120 chars
    const summary = build({
      logs: [
        log("2026-07-06", [{ name: longName, sets: [{ reps: 5, loadKg: 50 }] }]),
        log("2026-07-12", [{ name: longName, sets: [{ reps: 5, loadKg: 55 }] }]),
      ],
      profile: lensProfile("schoenfeld"),
    });

    // build() strict-parses, so getting here proves the ≤120 cap held.
    const lift = summary.lensHighlights?.find((h) => h.metric === "top_lift_e1rm");
    expect(lift?.framing.length).toBeLessThanOrEqual(120);
    expect(lift?.framing).toContain(longName.slice(0, 40));
  });
});
