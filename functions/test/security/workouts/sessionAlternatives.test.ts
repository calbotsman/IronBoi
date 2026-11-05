import { describe, expect, it } from "vitest";
import { FinishWorkoutSessionRequest } from "../../../src/workouts/activeWorkout.js";
import { lookupExercise } from "../../../src/workouts/exerciseCatalog.js";
import {
  KIND_ACTIVITY,
  KIND_STYLE,
  SESSION_KINDS,
  TIMED_KIND_ITEM,
  addOnOffer,
  buildAddOn,
  buildAlternativesBank,
  dayStyle,
  mainTrainingStyle,
  sessionMinutes,
  type BankDay,
} from "../../../src/workouts/sessionAlternatives.js";
import { isCardioExercise, isTimedExercise } from "../../../src/workouts/exerciseCatalog.js";

// Pure: the bank the phone caches so changing the workout never waits on
// the network. Built from the catalog, so the cases that matter are its
// shape, that every option is real, and that it fits the person.

const push: BankDay = {
  dayKey: "Mon",
  name: "Push",
  muscles: ["Chest"],
  exercises: [
    { name: "Barbell Bench Press", sets: 4, reps: 6, weight: 185 },
    { name: "Overhead Press", sets: 3, reps: 8, weight: 95 },
    { name: "Incline Dumbbell Press", sets: 3, reps: 10, weight: 50 },
    { name: "Skull Crushers", sets: 3, reps: 12, weight: 50 },
  ],
};

const mobilityDay: BankDay = {
  dayKey: "Sat",
  name: "Recovery",
  muscles: ["Core"],
  exercises: [
    { name: "Stretching Circuit", sets: 1, reps: 1, weight: 0 },
    { name: "Bird Dog", sets: 3, reps: 8, weight: 0 },
    { name: "Dead Bug", sets: 3, reps: 8, weight: 0 },
  ],
};

const NOW = new Date("2026-11-05T12:00:00Z");

function bank(profile = {}, equipment: Parameters<typeof buildAlternativesBank>[0]["equipment"] = null) {
  return buildAlternativesBank({
    days: [push, mobilityDay],
    profile,
    equipment,
    baselines: new Map(),
    today: "2026-11-05",
    now: NOW,
  });
}

describe("alternatives bank shape", () => {
  it("has a day per planned day, swaps per lift, and sessions with real ids", () => {
    const b = bank();
    expect(b.version).toBe(1);
    expect(b.builtAt).toBe(NOW.toISOString());
    expect(b.days.map((d) => d.dayKey)).toEqual(["Mon", "Sat"]);
    expect(b.kinds.map((k) => k.kind)).toEqual([...SESSION_KINDS]);
    expect(b.kinds.find((k) => k.kind === "yoga")).toEqual({ kind: "yoga", style: "mobility", activity: "yoga", timedItem: "Yoga Flow" });
    expect(b.kinds.find((k) => k.kind === "bodyweight")?.timedItem).toBeUndefined();
    const mon = b.days[0];
    expect(mon.workoutName).toBe("Push");
    expect(mon.swaps.map((s) => s.exerciseName)).toEqual(push.exercises.map((e) => e.name));
    for (const swap of mon.swaps) {
      expect(swap.options.length).toBeGreaterThan(0);
      expect(swap.options.length).toBeLessThanOrEqual(3);
      for (const option of swap.options) {
        // Every banked swap is a catalog movement, never the day's own lifts.
        expect(lookupExercise(option.name)).toBeDefined();
        expect(push.exercises.some((e) => e.name === option.name)).toBe(false);
        expect(option.suggestedWeightLb).toBeGreaterThanOrEqual(0);
      }
    }
    expect(mon.sessions.length).toBeGreaterThanOrEqual(2);
    expect(mon.sessions.length).toBeLessThanOrEqual(3);
    for (const session of mon.sessions) {
      expect(session.id).toMatch(/^Mon_[a-z]+$/);
      expect(session.items.length).toBeGreaterThan(0);
      expect(session.style).toBe(KIND_STYLE[session.kind]);
      expect(session.activity).toBe(KIND_ACTIVITY[session.kind]);
      expect(session.minutes).toBeGreaterThanOrEqual(10);
    }
    // Serializes cleanly for the phone's cache (no Maps, no undefined).
    expect(JSON.parse(JSON.stringify(b))).toEqual(b);
  });

  it("prefers a swap on different equipment from the lift it replaces", () => {
    const bench = bank().days[0].swaps.find((s) => s.exerciseName === "Barbell Bench Press")!;
    expect(bench.options[0].equipment).not.toContain("barbell");
  });

  it("only offers swaps the person has the gear for", () => {
    const home = bank({}, ["dumbbell"]);
    for (const swap of home.days[0].swaps) {
      for (const option of swap.options) {
        expect(option.equipment.every((g) => g === "none" || g === "dumbbell")).toBe(true);
      }
    }
  });

  it("a cardio or yoga session is one timed block the app already times", () => {
    const run = bank().days[0].sessions.find((s) => s.kind === "run")!;
    expect(run.items).toHaveLength(1);
    expect(run.items[0].timed).toBe(true);
    expect(run.items[0].reps).toBe(run.minutes * 60);
    for (const kind of SESSION_KINDS) {
      const name = TIMED_KIND_ITEM[kind];
      if (name) expect(isTimedExercise(name), name).toBe(true);
      if (name && kind !== "yoga") expect(isCardioExercise(name), name).toBe(true);
    }
  });

  it("a bodyweight version uses no equipment at all", () => {
    const bw = bank().days[0].sessions.find((s) => s.kind === "bodyweight")!;
    expect(bw).toBeDefined();
    for (const item of bw.items) {
      expect(lookupExercise(item.name)!.equipment.every((g) => g === "none")).toBe(true);
    }
  });

  it("doesn't offer a mobility session in place of a mobility day", () => {
    expect(dayStyle(mobilityDay)).toBe("mobility");
    const sat = bank().days[1];
    expect(sat.sessions.some((s) => s.kind === "mobility")).toBe(false);
    expect(sat.sessions.some((s) => s.style === "endurance")).toBe(true);
  });
});

describe("fit to the person", () => {
  it("reads the main kind of training from focus, then goals", () => {
    expect(mainTrainingStyle({})).toBe("strength");
    expect(mainTrainingStyle({ trainingFocus: "endurance_conditioning", goals: ["strength"] })).toBe("endurance");
    expect(mainTrainingStyle({ trainingFocus: "myo_recommended", goals: ["mobility"] })).toBe("mobility");
    expect(mainTrainingStyle({ goals: ["endurance", "strength"] })).toBe("strength");
    expect(mainTrainingStyle({ goals: ["endurance", "fat_loss"] })).toBe("endurance");
  });

  it("puts their main kind of training first", () => {
    expect(bank({ goals: ["endurance"] }).days[0].sessions[0].kind).toBe("run");
    expect(bank({ trainingFocus: "mobility_recovery" }).days[0].sessions[0].kind).toBe("mobility");
    expect(bank({}).days[0].sessions[0].style).toBe("strength");
  });

  it("sizes a replacement to their usual session, or what they asked for", () => {
    expect(bank({ sessionLengthMin: 45 }).days[0].sessions.find((s) => s.kind === "run")!.minutes).toBe(45);
    expect(sessionMinutes(push, { sessionLengthMin: 45 }, 20)).toBe(20);
    expect(sessionMinutes(push, {}, 500)).toBe(120);
  });

  it("builds the add-on from the gear they own", () => {
    const kb = buildAddOn("strength", ["kettlebell"], new Map(), "2026-11-05");
    expect(kb.equipment).toBe("kettlebell");
    expect(kb.items.length).toBeGreaterThan(0);
    for (const item of kb.items) expect(lookupExercise(item.name)!.equipment).toContain("kettlebell");
    const none = buildAddOn("strength", [], new Map(), "2026-11-05");
    expect(none.equipment).toBe("none");
    for (const item of none.items) expect(lookupExercise(item.name)!.equipment).toEqual(["none"]);
    expect(buildAddOn("endurance", null, new Map(), "2026-11-05").items[0].timed).toBe(true);
  });
});

describe("the one-time add-on offer", () => {
  const switching = {
    mainStyle: "strength" as const,
    addOnAsked: false,
    addOn: { style: "strength" as const, equipment: "kettlebell" as const, minutes: 10 },
  };

  it("offers only when the switch leaves their main training", () => {
    expect(addOnOffer("run", switching)).toEqual(switching.addOn);
    expect(addOnOffer("yoga", switching)).toEqual(switching.addOn);
    expect(addOnOffer("bodyweight", switching)).toBeNull();
    expect(addOnOffer("shorter", switching)).toBeNull();
  });

  it("never asks twice", () => {
    expect(addOnOffer("run", { ...switching, addOnAsked: true })).toBeNull();
    expect(addOnOffer("run", undefined)).toBeNull();
  });
});

describe("finishing a switched session", () => {
  it("accepts the kind it was switched to and rejects anything else", () => {
    const base = { sessionId: "s1", completedAt: "2026-11-05T13:00:00.000Z", exercises: [] };
    expect(FinishWorkoutSessionRequest.safeParse({ ...base, replacedWith: { kind: "run", activity: "running", title: "Run" } }).success).toBe(true);
    expect(FinishWorkoutSessionRequest.safeParse({ ...base, replacedWith: { kind: "sprint", activity: "running", title: "Run" } }).success).toBe(false);
    expect(FinishWorkoutSessionRequest.safeParse({ ...base, replacedWith: { kind: "run", activity: "running", title: "" } }).success).toBe(false);
  });
});
