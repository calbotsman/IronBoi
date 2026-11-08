import { describe, expect, it } from "vitest";
import { TrainingHistory, TrainingRecap } from "../../../src/contracts/coach-agent.js";
import {
  buildTrainingHistory,
  buildTrainingRecap,
  normalizeSessions,
  toLb,
  weekStartOf,
} from "../../../src/progress/trainingHistory.js";
import type { BaselineMap } from "../../../src/workouts/exerciseBaselines.js";

// Fixed dates, never the clock. 2026-11-02 is a Monday.
const MON = "2026-11-02";
const TUE = "2026-11-03";
const WED = "2026-11-04";
const THU = "2026-11-05";
const SAT = "2026-11-07";
const USER = "training-history-user";
const LB = 0.45359237;

const PLAN = {
  days: {
    Mon: { name: "Upper Push", muscles: [], exercises: [{ name: "Barbell Bench Press", sets: 3, reps: 8, weight: 135 }] },
    Wed: { name: "Lower", muscles: [], exercises: [{ name: "KB Goblet Squat", sets: 3, reps: 10, weight: 35 }] },
    Thu: { name: "Upper Pull", muscles: [], exercises: [{ name: "Bent-over Barbell Row", sets: 3, reps: 8, weight: 95 }] },
    Sat: { name: "Rest", muscles: [], exercises: [] },
  },
};

type SetSpec = [lb: number, reps: number];

function log(date: string, name: string, sets: SetSpec[], extra: Record<string, unknown> = {}) {
  return {
    userId: USER,
    sessionId: `${date}_${name.replace(/\W+/g, "").toLowerCase()}_${String(extra.tag ?? "a")}`,
    date,
    source: "manual",
    exercises: [{ name, sets: sets.map(([lb, reps]) => ({ reps, loadKg: Math.round(lb * LB * 10) / 10 })) }],
    createdAt: `${date}T12:00:00.000Z`,
    ...extra,
  };
}

function addDays(date: string, days: number) {
  return new Date(Date.parse(`${date}T00:00:00Z`) + days * 86_400_000).toISOString().slice(0, 10);
}

// A full week on plan: Mon bench, Wed squat, Thu row.
function fullWeek(monday: string, bench = 135) {
  return [
    log(monday, "Barbell Bench Press", [[bench, 8], [bench, 8], [bench, 8]], { dayKey: "Mon", workoutName: "Upper Push" }),
    log(addDays(monday, 2), "KB Goblet Squat", [[35, 10], [35, 10], [35, 10]], { dayKey: "Wed", workoutName: "Lower" }),
    log(addDays(monday, 3), "Bent-over Barbell Row", [[95, 8], [95, 8], [95, 8]], { dayKey: "Thu", workoutName: "Upper Pull" }),
  ];
}

function build(logs: Array<Record<string, unknown>>, today: string, options: { createdAt?: string; events?: Array<Record<string, unknown>>; baselines?: BaselineMap; plan?: Record<string, unknown> } = {}) {
  return buildTrainingHistory({
    userId: USER,
    today,
    now: `${today}T15:00:00.000Z`,
    logs,
    plan: options.plan ?? PLAN,
    program: null,
    baselines: options.baselines ?? new Map(),
    events: options.events ?? [],
    profile: { createdAt: options.createdAt ?? "2026-09-01T00:00:00.000Z" },
  });
}

describe("training history builder", () => {
  it("converts logged kg to pounds on the nearest 0.5 lb", () => {
    expect(toLb(Math.round(35 * LB * 10) / 10)).toBe(35);
    expect(toLb(Math.round(37.5 * LB * 10) / 10)).toBe(37.5);
    expect(toLb(Math.round(135 * LB * 10) / 10)).toBe(135);
    const [session] = normalizeSessions([log(MON, "Barbell Bench Press", [[135, 8]])]);
    expect(session.lifts[0].sets[0]).toEqual({ lb: 135, reps: 8 });
  });

  it("weeks are Monday to Sunday", () => {
    expect(weekStartOf("2026-11-08")).toBe(MON); // Sunday
    expect(weekStartOf(MON)).toBe(MON);
    expect(weekStartOf(THU)).toBe(MON);
  });

  describe("streak", () => {
    it("counts full weeks on plan; rest days never break it", () => {
      const logs = [-21, -14, -7].flatMap((offset) => fullWeek(addDays(MON, offset)));
      const history = build(logs, TUE);
      // Three full weeks; this week in progress neither adds nor breaks.
      expect(history.streak).toEqual({ currentWeeks: 3, bestWeeks: 3, thisWeekMet: false });
    });

    it("the current week adds once it's met, even mid-week", () => {
      const logs = [-7, 0].flatMap((offset) => fullWeek(addDays(MON, offset)));
      const history = build(logs, "2026-11-06"); // Friday, all three done
      expect(history.streak).toMatchObject({ currentWeeks: 2, thisWeekMet: true });
      expect(history.thisWeek).toMatchObject({ weekStart: MON, planned: 3, done: 3 });
    });

    it("a short week breaks it; the best streak remembers the longer run", () => {
      const logs = [
        ...[-35, -28, -21].flatMap((offset) => fullWeek(addDays(MON, offset))),
        ...fullWeek(addDays(MON, -14)).slice(0, 2), // 2 of 3
        ...fullWeek(addDays(MON, -7)),
      ];
      const history = build(logs, MON);
      expect(history.streak).toMatchObject({ currentWeeks: 1, bestWeeks: 3 });
    });

    it("counts against the plan's own number of training days", () => {
      const twoDays = { days: { Tue: PLAN.days.Mon, Fri: PLAN.days.Thu } };
      const week = (monday: string) => [
        log(addDays(monday, 1), "Barbell Bench Press", [[135, 8]]),
        log(addDays(monday, 4), "Bent-over Barbell Row", [[95, 8]]),
      ];
      const history = build([...week(addDays(MON, -14)), ...week(addDays(MON, -7))], MON, { plan: twoDays });
      expect(history.streak.currentWeeks).toBe(2);
      expect(history.thisWeek.planned).toBe(2);
    });

    it("weeks before the user started don't count or break", () => {
      const history = build(fullWeek(addDays(MON, -7)), MON, { createdAt: "2026-10-26T09:00:00.000Z" });
      expect(history.streak).toMatchObject({ currentWeeks: 1, bestWeeks: 1 });
      // No "missed" days before day one.
      expect(history.calendar.filter((day) => day.date < "2026-10-26").every((day) => day.status === "rest")).toBe(true);
    });

    it("no plan, no streak", () => {
      const history = build(fullWeek(addDays(MON, -7)), MON, { plan: {} });
      expect(history.streak.currentWeeks).toBe(0);
    });
  });

  describe("calendar and this week", () => {
    it("labels done, missed, today, planned, rest and extra", () => {
      const logs = [
        log(MON, "Barbell Bench Press", [[135, 8]], { dayKey: "Mon", workoutName: "Upper Push" }),
        log(TUE, "KB Swing", [[35, 15]], { workoutName: "Extra swings" }),
      ];
      const history = build(logs, THU);
      expect(history.calendar).toHaveLength(63);
      expect(history.calendar[0].dayKey).toBe("Mon");
      const week = Object.fromEntries(history.calendar.slice(-7).map((day) => [day.dayKey, day]));
      expect(week.Mon).toMatchObject({ status: "done", name: "Upper Push" });
      expect(week.Tue).toMatchObject({ status: "extra", name: "Extra swings" });
      expect(week.Wed).toMatchObject({ status: "missed", name: "Lower" });
      expect(week.Thu).toMatchObject({ status: "today", name: "Upper Pull" });
      expect(week.Fri.status).toBe("rest");
      expect(week.Sat.status).toBe("rest"); // a "Rest" day with no exercises
      expect(history.missedThisWeek).toEqual([
        { date: WED, dayKey: "Wed", name: "Lower", muscles: ["quads", "glutes"] },
      ]);
    });

    it("future training days this week are planned; missed are most recent first", () => {
      const history = build([], "2026-11-06"); // Friday, nothing done
      const week = Object.fromEntries(history.calendar.slice(-7).map((day) => [day.dayKey, day.status]));
      expect(week).toMatchObject({ Mon: "missed", Wed: "missed", Thu: "missed", Sat: "rest" });
      expect(history.missedThisWeek.map((day) => day.dayKey)).toEqual(["Thu", "Wed", "Mon"]);
      const tuesday = build([], TUE);
      expect(tuesday.calendar.slice(-7).find((day) => day.dayKey === "Thu")?.status).toBe("planned");
    });

    it("a missed day done later in the week counts as made up", () => {
      const logs = [log(SAT, "KB Goblet Squat", [[35, 10]], { dayKey: "Wed", workoutName: "Lower" })];
      const history = build(logs, SAT);
      const week = Object.fromEntries(history.calendar.slice(-7).map((day) => [day.dayKey, day]));
      expect(week.Wed).toMatchObject({ status: "done", name: "Lower" });
      expect(week.Sat.status).toBe("extra");
      expect(history.missedThisWeek.map((day) => day.dayKey)).toEqual(["Thu", "Mon"]);
    });

    it("uses the user's local date over the UTC one", () => {
      // Finished Monday 9 pm in New York: UTC already says Tuesday.
      const logs = [log(TUE, "Barbell Bench Press", [[135, 8]], { localDate: MON, dayKey: "Mon" })];
      const history = build(logs, TUE);
      const week = Object.fromEntries(history.calendar.slice(-7).map((day) => [day.dayKey, day.status]));
      expect(week.Mon).toBe("done");
      expect(week.Tue).toBe("rest");
    });

    it("recent muscles come from yesterday's and today's sessions", () => {
      const logs = [
        log(MON, "Barbell Bench Press", [[135, 8]]),
        log(WED, "Bent-over Barbell Row", [[95, 8]]),
      ];
      const history = build(logs, THU);
      expect(history.recentMuscles).toContain("lats");
      expect(history.recentMuscles).not.toContain("chest"); // Monday's bench is three days back
    });

    it("this week's volume is in pounds, with the average effort", () => {
      const logs = [
        log(MON, "Barbell Bench Press", [[100, 10]], { perceivedEffort: 6 }),
        log(TUE, "Plank", [[0, 60]], { perceivedEffort: 8 }),
      ];
      const history = build(logs, TUE);
      expect(history.thisWeek.volumeLb).toBe(1001); // 45.4 kg × 10 reps
      expect(history.thisWeek.avgEffort).toBe(7);
    });
  });

  describe("lifts and personal records", () => {
    it("tracks start → current, sessions, the e1RM series and events newest first", () => {
      const logs = [
        log("2026-10-13", "KB Goblet Squat", [[25, 10], [25, 10]]),
        log("2026-10-20", "KB Goblet Squat", [[30, 10], [30, 10]]),
        log(WED, "KB Goblet Squat", [[35, 10], [35, 10]]),
      ];
      const events = [
        { exerciseKey: "kb_goblet_squat", date: "2026-10-20", kind: "session_up", fromLb: 25, toLb: 30, reason: "All 3×10 hit at 25 lb", createdAt: "2026-10-20T12:00:00.000Z" },
        { exerciseKey: "kb_goblet_squat", date: WED, kind: "session_up", fromLb: 35, toLb: 40, reason: "All 3×10 hit at 35 lb", createdAt: `${WED}T12:00:00.000Z` },
        { exerciseKey: "kb_goblet_squat", date: WED, kind: "not_a_kind", fromLb: 1, toLb: 2 },
      ];
      const baselines: BaselineMap = new Map([["kb_goblet_squat", {
        userId: USER, exerciseKey: "kb_goblet_squat", exerciseName: "KB Goblet Squat", anchorWeightLb: 40,
        anchorDate: WED, source: "user_session", updatedAt: `${WED}T12:00:00.000Z`,
      }]]);
      const history = build(logs, THU, { events, baselines });
      const lift = history.lifts.find((entry) => entry.exerciseKey === "kb_goblet_squat")!;
      expect(lift).toMatchObject({ startLb: 25, currentLb: 40, firstDate: "2026-10-13", lastDate: WED, sessions: 3 });
      expect(lift.events.map((event) => event.toLb)).toEqual([40, 30]);
      expect(lift.e1rmSeries.map((point) => point.date)).toEqual(["2026-10-13", "2026-10-20", WED]);
      expect(lift.e1rmSeries[2].value).toBeCloseTo(35 * (1 + 10 / 30), 0);
    });

    it("a record is set by the session that first beats the previous best", () => {
      const logs = [
        log("2026-10-19", "Barbell Bench Press", [[135, 8]], { tag: "1" }),
        log("2026-10-26", "Barbell Bench Press", [[135, 10]], { tag: "2" }), // more reps at a weight done before
        log(MON, "Barbell Bench Press", [[145, 5]], { tag: "3" }), // heaviest
        log(WED, "Barbell Bench Press", [[135, 9]], { tag: "4" }), // nothing new
      ];
      const history = build(logs, THU);
      const kinds = history.recentRecords.map((record) => [record.date, record.kind]);
      expect(kinds).toEqual([[MON, "heaviest"], ["2026-10-26", "most_reps"]]);
      expect(history.recentRecords[0]).toMatchObject({ weightLb: 145, reps: 5, exerciseName: "Barbell Bench Press" });
      const lift = history.lifts[0];
      expect(lift.prs.map((pr) => pr.kind)).toEqual(["heaviest", "best_e1rm", "most_reps"]);
      expect(lift.prs[0]).toMatchObject({ weightLb: 145, date: MON });
    });

    it("the first time a lift is logged sets no record, and unreal sets never count", () => {
      const logs = [{
        ...log(MON, "Barbell Bench Press", [[135, 8]]),
        exercises: [
          { name: "Barbell Bench Press", sets: [{ reps: 8, loadKg: 61.2 }, { reps: 0, loadKg: 90 }, { reps: 20 }] },
          { name: "Plank", sets: [{ reps: 60, loadKg: 20 }] },
        ],
      }];
      const history = build(logs, MON);
      expect(history.recentRecords).toEqual([]);
      expect(history.lifts.map((lift) => lift.exerciseName)).toEqual(["Barbell Bench Press"]);
      expect(history.lifts[0].prs[0]).toMatchObject({ kind: "heaviest", weightLb: 135 });
    });

    it("keeps the 12 most recently trained lifts", () => {
      const names = ["Barbell Bench Press", "Incline Dumbbell Press", "Overhead Press", "Dumbbell Shoulder Press", "Arnold Press",
        "Lateral Raises", "Skull Crushers", "Deadlift", "Romanian Deadlift", "Bent-over Barbell Row", "Single-arm DB Row",
        "Hammer Curls", "EZ Bar Curl", "KB Goblet Squat"];
      const logs = names.map((name, index) => log(addDays("2026-10-01", index), name, [[20, 10]]));
      const history = build(logs, MON);
      expect(history.lifts).toHaveLength(12);
      expect(history.lifts[0].exerciseName).toBe("KB Goblet Squat");
      expect(history.lifts.map((lift) => lift.exerciseName)).not.toContain("Barbell Bench Press");
    });
  });

  it("always satisfies the strict contract", () => {
    const logs = [-14, -7, 0].flatMap((offset) => fullWeek(addDays(MON, offset)));
    expect(TrainingHistory.safeParse(build(logs, SAT)).success).toBe(true);
    expect(TrainingHistory.safeParse(build([], SAT)).success).toBe(true);
  });
});

describe("training recap", () => {
  it("compares each lift's top set with last time and volume with the same plan day", () => {
    const logs = [
      log("2026-10-26", "Barbell Bench Press", [[135, 8], [135, 8]], { dayKey: "Mon", tag: "1" }),
      log("2026-10-28", "KB Goblet Squat", [[35, 10]], { dayKey: "Wed", tag: "2" }),
      log(MON, "Barbell Bench Press", [[140, 8], [140, 6]], { dayKey: "Mon", tag: "3" }),
    ];
    const sessions = normalizeSessions(logs);
    const recap = buildTrainingRecap({
      sessionId: logs[2].sessionId,
      sessions,
      nextWeights: [{ exerciseName: "Barbell Bench Press", fromLb: 140, toLb: 145, reason: "All 2×8 hit at 140 lb" }],
      streakWeeks: 2,
    });
    expect(TrainingRecap.safeParse(recap).success).toBe(true);
    expect(recap.comparedToLast).toEqual([{ exerciseName: "Barbell Bench Press", deltaLb: 5, deltaReps: 0 }]);
    expect(recap.records.map((record) => record.kind)).toEqual(["heaviest"]);
    expect(recap.previousVolumeLb).toBe(2159);
    expect(recap.volumeLb).toBeGreaterThan(0);
    expect(recap.streakWeeks).toBe(2);
    expect(recap.nextWeights[0].toLb).toBe(145);
  });

  it("a first session has nothing to compare and no records", () => {
    const logs = [log(MON, "Barbell Bench Press", [[135, 8]])];
    const recap = buildTrainingRecap({ sessionId: logs[0].sessionId, sessions: normalizeSessions(logs), nextWeights: [], streakWeeks: 0 });
    expect(recap).toEqual({ records: [], nextWeights: [], comparedToLast: [], volumeLb: 1079, streakWeeks: 0 });
  });
});
