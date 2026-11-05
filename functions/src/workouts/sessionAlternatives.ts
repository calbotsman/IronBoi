// Banked alternatives: everything the phone needs to change a workout
// without waiting on the network.
//
// Swapping a lift used to mean a callable round trip at the moment someone
// said "can I do something else" — slow on gym wifi, dead in airplane mode.
// Every option here comes from the same catalog the live swap uses, so the
// phone can build the bank once (when the plan loads, and again at workout
// start) and read from it instantly:
//
//   swaps     — per exercise, up to three substitutes that train the same
//               primary muscles, preferring a DIFFERENT piece of equipment
//               (the usual reason for a swap is "the rack is taken").
//   sessions  — whole-session replacements for the day, ordered by fit with
//               the person's goals: a shorter or bodyweight version, a run,
//               a mobility session.
//   addOn     — a short block of their main kind of training, offered once
//               when they switch to something outside it ("10 minutes of
//               kettlebell work after?").
//
// Pure: the callable loads the plan, profile and baselines and hands them in.

import type { Firestore } from "firebase-admin/firestore";
import { z } from "zod";
import { PlannedWorkoutDay, SessionActivity, SessionKind, SessionSwitchContext, TrainingStyle } from "../contracts/coach-agent.js";
import { resolvePrescribedWeight, roundToPlate, type BaselineMap } from "./exerciseBaselines.js";
import {
  allExercises,
  isCardioExercise,
  isTimedExercise,
  lookupExercise,
  suggestSwaps,
  type CatalogEntry,
  type Equipment,
  type MovementPattern,
} from "./exerciseCatalog.js";
import { resolvePlanDay, toSwapOption, type SwapOption } from "./exerciseSwap.js";
import { loadBaselines } from "./exerciseBaselines.js";
import { currentDateISO } from "./planAdjustments.js";
import { catalogEquipment } from "./planFit.js";
import { profilePath, workoutPlanPath } from "../paths.js";

type PlannedWorkoutDayType = z.infer<typeof PlannedWorkoutDay>;
/** A planned day with the weekday it sits on. */
export type BankDay = PlannedWorkoutDayType & { dayKey: string };

export const SESSION_KINDS = SessionKind.options;
export type { SessionKind, TrainingStyle };
export const TRAINING_STYLES = TrainingStyle.options;

export const SESSION_ACTIVITIES = SessionActivity.options;
export type { SessionActivity };

export const KIND_STYLE: Record<SessionKind, TrainingStyle> = {
  run: "endurance",
  walk: "endurance",
  cycle: "endurance",
  row: "endurance",
  swim: "endurance",
  hike: "endurance",
  yoga: "mobility",
  mobility: "mobility",
  bodyweight: "strength",
  shorter: "strength",
};

export const KIND_ACTIVITY: Record<SessionKind, SessionActivity> = {
  run: "running",
  walk: "walking",
  cycle: "cycling",
  row: "rowing",
  swim: "swimming",
  hike: "hiking",
  yoga: "yoga",
  mobility: "flexibility",
  bodyweight: "strength",
  shorter: "strength",
};

/**
 * The single timed block a cardio or yoga session is. Names the phone
 * already recognises: cardio by CARDIO_PATTERN, yoga as a catalog timed entry.
 */
export const TIMED_KIND_ITEM: Partial<Record<SessionKind, string>> = {
  run: "Run",
  walk: "Walk",
  cycle: "Bike",
  row: "Rowing",
  swim: "Swim",
  hike: "Hike",
  yoga: "Yoga Flow",
};

// Bounds for a timed session the person didn't give a length for.
const MIN_SESSION_MIN = 10;
const MAX_SESSION_MIN = 120;
// Rough wall-clock per working set including rest, for sizing a run to the
// session it replaces when the profile has no session length.
const MINUTES_PER_SET = 2.5;
/** How long the one-time add-on block runs. */
export const ADD_ON_MINUTES = 10;
const SWAPS_PER_EXERCISE = 3;
// Seconds per timed hold inside a structured session.
const HOLD_SEC = 30;

export type BankedItem = {
  name: string;
  sets: number;
  /** Seconds when `timed`. */
  reps: number;
  weight: number;
  timed: boolean;
};

export type SessionAlternative = {
  id: string;
  kind: SessionKind;
  style: TrainingStyle;
  activity: SessionActivity;
  /** Short label for a list row and for the coach to name it. */
  title: string;
  minutes: number;
  items: BankedItem[];
};

export type AddOn = {
  style: TrainingStyle;
  /** The gear it's built around ("kettlebell"), or "none". */
  equipment: Equipment;
  title: string;
  minutes: number;
  items: BankedItem[];
};

export type DayBank = {
  dayKey: string;
  workoutName: string;
  swaps: Array<{ exerciseName: string; options: SwapOption[] }>;
  sessions: SessionAlternative[];
};

export type AlternativesBank = {
  version: 1;
  builtAt: string;
  clientDate: string;
  mainStyle: TrainingStyle;
  addOn: AddOn | null;
  /** Every kind, so the phone can build a timed session that wasn't banked for the day. */
  kinds: Array<{ kind: SessionKind; style: TrainingStyle; activity: SessionActivity; timedItem?: string }>;
  days: DayBank[];
};

export type ProfileForBank = {
  goals?: readonly string[];
  trainingFocus?: string;
  sessionLengthMin?: number;
};

/**
 * Lifting, endurance or mobility: what this person mostly trains for.
 * An explicit training focus wins; otherwise the goals vote; MYO builds
 * lifting plans, so a tie or no answer is strength.
 */
export function mainTrainingStyle(profile: ProfileForBank): TrainingStyle {
  switch (profile.trainingFocus) {
    case "endurance_conditioning":
      return "endurance";
    case "mobility_recovery":
      return "mobility";
    case "muscle_split":
    case "full_body":
    case "strength_conditioning":
      return "strength";
    default:
      break;
  }
  const votes: Record<TrainingStyle, number> = { strength: 0, endurance: 0, mobility: 0 };
  for (const goal of profile.goals ?? []) {
    if (goal === "endurance") votes.endurance += 1;
    else if (goal === "mobility") votes.mobility += 1;
    else if (goal === "strength" || goal === "muscle_gain") votes.strength += 1;
  }
  const top = Math.max(votes.strength, votes.endurance, votes.mobility);
  if (top === 0 || votes.strength === top) return "strength";
  return votes.endurance === top ? "endurance" : "mobility";
}

/** What a planned day mostly is, from its exercises' catalog patterns. */
export function dayStyle(day: PlannedWorkoutDayType): TrainingStyle {
  let mobility = 0;
  let endurance = 0;
  for (const exercise of day.exercises) {
    const entry = lookupExercise(exercise.name);
    if (entry?.pattern === "mobility" || entry?.pattern === "core") mobility += 1;
    else if (entry?.pattern === "conditioning" || (!entry && isCardioExercise(exercise.name))) endurance += 1;
  }
  const n = day.exercises.length;
  if (n === 0) return "strength";
  if (mobility * 2 > n) return "mobility";
  if (endurance * 2 > n) return "endurance";
  return "strength";
}

/**
 * The offer to make when someone switches to `kind`: a short block of their
 * main training, only when the switch takes them outside it and they haven't
 * been asked yet this session. Null = don't ask.
 */
export function addOnOffer(
  kind: SessionKind,
  switching: SessionSwitchContext | undefined,
): NonNullable<SessionSwitchContext["addOn"]> | null {
  if (!switching || switching.addOnAsked || !switching.addOn) return null;
  return KIND_STYLE[kind] === switching.mainStyle ? null : switching.addOn;
}

function clampMinutes(minutes: number): number {
  return Math.max(MIN_SESSION_MIN, Math.min(MAX_SESSION_MIN, Math.round(minutes)));
}

function estimateMinutes(items: Array<{ sets: number; reps: number; timed?: boolean; name?: string }>): number {
  let total = 0;
  for (const item of items) {
    const timed = item.timed ?? (item.name ? isTimedExercise(item.name) : false);
    total += timed && item.reps >= 300 ? (item.sets * item.reps) / 60 : item.sets * MINUTES_PER_SET;
  }
  return clampMinutes(total);
}

/** How long a replacement should run: what they said, else their usual, else the day's size. */
export function sessionMinutes(day: PlannedWorkoutDayType | null, profile: ProfileForBank, asked?: number): number {
  if (asked !== undefined && Number.isFinite(asked) && asked > 0) return clampMinutes(asked);
  if (profile.sessionLengthMin) return clampMinutes(profile.sessionLengthMin);
  return day ? estimateMinutes(day.exercises) : clampMinutes(30);
}

function timedSession(kind: SessionKind, minutes: number, dayKey: string): SessionAlternative | null {
  const name = TIMED_KIND_ITEM[kind];
  if (!name) return null;
  return {
    id: `${dayKey}_${kind}`,
    kind,
    style: KIND_STYLE[kind],
    activity: KIND_ACTIVITY[kind],
    title: name,
    minutes,
    items: [{ name, sets: 1, reps: minutes * 60, weight: 0, timed: true }],
  };
}

function item(entry: CatalogEntry, sets: number, reps: number, weight: number): BankedItem {
  const timed = entry.timed === true;
  return { name: entry.name, sets, reps: timed ? HOLD_SEC : reps, weight, timed };
}

/** The day, every lift done with nothing but bodyweight. Null when too little of it translates. */
function bodyweightVersion(day: BankDay, today: string, baselines: BaselineMap): SessionAlternative | null {
  const items: BankedItem[] = [];
  const used = new Set<string>();
  let changed = false;
  for (const exercise of day.exercises) {
    const entry = lookupExercise(exercise.name);
    if (!entry) continue;
    const needsGear = entry.equipment.some((gear) => gear !== "none");
    const pick = needsGear
      ? suggestSwaps({ exerciseName: exercise.name, excludeNames: [...used, ...day.exercises.map((e) => e.name)], availableEquipment: [], limit: 1 })[0]
      : undefined;
    const chosen = needsGear ? (pick ? lookupExercise(pick.name) : undefined) : entry;
    if (!chosen || used.has(chosen.name)) continue;
    if (needsGear) changed = true;
    used.add(chosen.name);
    const weight = chosen.loadClass === "bodyweight" ? 0 : roundToPlate(resolvePrescribedWeight({ name: chosen.name, weight: 0 }, baselines, today));
    items.push(item(chosen, exercise.sets, exercise.reps, weight));
  }
  if (!changed || items.length * 2 < day.exercises.length) return null;
  return {
    id: `${day.dayKey}_bodyweight`,
    kind: "bodyweight",
    style: "strength",
    activity: "strength",
    title: `${day.name} (bodyweight)`,
    minutes: estimateMinutes(items),
    items,
  };
}

/** The first half of the day: the compound work, same sets and weights. */
function shorterVersion(day: BankDay): SessionAlternative | null {
  if (day.exercises.length < 2) return null;
  const keep = day.exercises.slice(0, Math.ceil(day.exercises.length / 2));
  const items = keep.map((exercise) => ({
    name: exercise.name,
    sets: exercise.sets,
    reps: exercise.reps,
    weight: exercise.weight,
    timed: isTimedExercise(exercise.name),
  }));
  return {
    id: `${day.dayKey}_shorter`,
    kind: "shorter",
    style: "strength",
    activity: "strength",
    title: `${day.name} (short)`,
    minutes: estimateMinutes(items),
    items,
  };
}

// The catalog's no-equipment mobility and core work, in pattern order:
// mobility first, then core. Built from the catalog so a new entry joins.
function mobilityItems(limit: number): BankedItem[] {
  const pool = allExercises().filter(
    (entry) =>
      (entry.pattern === "core" || (entry.pattern === "mobility" && !entry.timed)) &&
      entry.equipment.every((gear) => gear === "none"),
  );
  const order: MovementPattern[] = ["mobility", "core"];
  pool.sort((a, b) => order.indexOf(a.pattern) - order.indexOf(b.pattern));
  return pool.slice(0, limit).map((entry) => item(entry, entry.pattern === "mobility" ? 1 : 2, entry.pattern === "mobility" ? 1 : 8, 0));
}

function mobilitySession(dayKey: string, minutes: number): SessionAlternative {
  // Roughly one movement per five minutes, at least three.
  const items = mobilityItems(Math.max(3, Math.round(minutes / 5)));
  return {
    id: `${dayKey}_mobility`,
    kind: "mobility",
    style: "mobility",
    activity: "flexibility",
    title: "Mobility",
    minutes,
    items,
  };
}

/** Every whole-session replacement for a day, best fit first. */
export function sessionAlternativesForDay(
  day: BankDay,
  input: { profile: ProfileForBank; mainStyle: TrainingStyle; baselines: BaselineMap; today: string },
): SessionAlternative[] {
  const minutes = sessionMinutes(day, input.profile);
  const own = dayStyle(day);
  const variant = bodyweightVersion(day, input.today, input.baselines) ?? shorterVersion(day);
  const others: SessionAlternative[] = [];
  if (own !== "endurance") others.push(timedSession("run", minutes, day.dayKey)!);
  if (own !== "mobility") others.push(mobilitySession(day.dayKey, minutes));
  if (own === "mobility") others.push(timedSession("walk", minutes, day.dayKey)!);
  // Their main kind of training first, so the top of the list fits them.
  others.sort((a, b) => Number(b.style === input.mainStyle) - Number(a.style === input.mainStyle));
  const all = input.mainStyle === "strength" ? [variant, ...others] : [...others, variant];
  return all.filter((alt): alt is SessionAlternative => alt !== null);
}

// Gear worth building a short finisher around (not a bench or a bar).
const FINISHER_GEAR: readonly Equipment[] = ["kettlebell", "dumbbell", "barbell", "sandbag", "band", "club", "medball"];
const FINISHER_PATTERNS: readonly MovementPattern[] = ["hinge", "squat", "vertical_push", "horizontal_pull", "horizontal_push", "carry"];

/**
 * The gear an add-on is built around: the first finisher-worthy item on
 * their own equipment list, in the order they gave it. A full gym (null)
 * goes by their goals: strength → barbell, muscle → dumbbells, otherwise
 * kettlebell work.
 */
export function addOnGear(equipment: Equipment[] | null, goals: readonly string[] = []): Equipment {
  if (equipment === null) {
    if (goals.includes("strength")) return "barbell";
    if (goals.includes("muscle_gain")) return "dumbbell";
    return "kettlebell";
  }
  return equipment.find((g) => FINISHER_GEAR.includes(g)) ?? "none";
}

/** A short block of their main training, built from what they own. */
export function buildAddOn(
  mainStyle: TrainingStyle,
  equipment: Equipment[] | null,
  baselines: BaselineMap,
  today: string,
  goals: readonly string[] = [],
): AddOn {
  if (mainStyle === "endurance") {
    const run = timedSession("run", ADD_ON_MINUTES, "addon")!;
    return { style: mainStyle, equipment: "none", title: run.title, minutes: ADD_ON_MINUTES, items: run.items };
  }
  if (mainStyle === "mobility") {
    const yoga = timedSession("yoga", ADD_ON_MINUTES, "addon")!;
    return { style: mainStyle, equipment: "none", title: yoga.title, minutes: ADD_ON_MINUTES, items: yoga.items };
  }
  const gear = addOnGear(equipment, goals);
  const catalog = allExercises();
  const items: BankedItem[] = [];
  for (const pattern of FINISHER_PATTERNS) {
    if (items.length >= 3) break;
    const entry = catalog.find(
      (e) => e.pattern === pattern && (gear === "none" ? e.equipment.every((g) => g === "none") : e.equipment.includes(gear) && e.equipment.every((g) => g === gear || g === "none")),
    );
    if (!entry) continue;
    const weight = entry.loadClass === "bodyweight" ? 0 : roundToPlate(resolvePrescribedWeight({ name: entry.name, weight: 0 }, baselines, today));
    items.push(item(entry, 2, 10, weight));
  }
  const label = gear === "none" ? "Bodyweight" : gear.charAt(0).toUpperCase() + gear.slice(1).replace(/_/g, " ");
  return { style: mainStyle, equipment: gear, title: label, minutes: ADD_ON_MINUTES, items };
}

/** Up to three swaps per lift, a different piece of equipment preferred. */
export function swapsForDay(
  day: BankDay,
  input: { equipment: Equipment[] | null; baselines: BaselineMap; today: string },
): DayBank["swaps"] {
  const names = day.exercises.map((exercise) => exercise.name);
  const swaps: DayBank["swaps"] = [];
  for (const exercise of day.exercises) {
    const original = lookupExercise(exercise.name);
    if (!original) continue;
    const ownGear = new Set<Equipment>(original.equipment.filter((gear) => gear !== "none"));
    const candidates = suggestSwaps({
      exerciseName: exercise.name,
      excludeNames: names,
      availableEquipment: input.equipment,
      limit: 8,
    });
    // Stable: within each group the catalog's ranking holds.
    const differentGear = (equipment: Equipment[]) => equipment.every((gear) => !ownGear.has(gear));
    const ordered = [...candidates.filter((c) => differentGear(c.equipment)), ...candidates.filter((c) => !differentGear(c.equipment))];
    const options = ordered
      .slice(0, SWAPS_PER_EXERCISE)
      .map((candidate) => toSwapOption(candidate, exercise.name, exercise.weight, input.baselines, input.today));
    if (options.length > 0) swaps.push({ exerciseName: exercise.name, options });
  }
  return swaps;
}

export function buildAlternativesBank(input: {
  days: BankDay[];
  profile: ProfileForBank;
  equipment: Equipment[] | null;
  baselines: BaselineMap;
  today: string;
  now?: Date;
}): AlternativesBank {
  const mainStyle = mainTrainingStyle(input.profile);
  return {
    version: 1,
    builtAt: (input.now ?? new Date()).toISOString(),
    clientDate: input.today,
    mainStyle,
    addOn: buildAddOn(mainStyle, input.equipment, input.baselines, input.today, input.profile.goals),
    kinds: SESSION_KINDS.map((kind) => ({
      kind,
      style: KIND_STYLE[kind],
      activity: KIND_ACTIVITY[kind],
      ...(TIMED_KIND_ITEM[kind] ? { timedItem: TIMED_KIND_ITEM[kind] } : {}),
    })),
    days: input.days.map((day) => ({
      dayKey: day.dayKey,
      workoutName: day.name,
      swaps: swapsForDay(day, input),
      sessions: sessionAlternativesForDay(day, { profile: input.profile, mainStyle, baselines: input.baselines, today: input.today }),
    })),
  };
}

export const GetSessionAlternativesRequest = z.object({
  planId: z.string().min(1).default("current"),
  clientDate: z.string().date().optional(),
}).strict();

/** The bank for every day of the plan, as it stands today (a dated override beats the template). */
export async function getSessionAlternatives(
  db: Firestore,
  userId: string,
  request: z.infer<typeof GetSessionAlternativesRequest>,
): Promise<{ ok: true; bank: AlternativesBank }> {
  const today = request.clientDate ?? currentDateISO();
  const [planSnap, profileSnap, baselines] = await Promise.all([
    db.doc(workoutPlanPath(userId, request.planId)).get(),
    db.doc(profilePath(userId)).get(),
    loadBaselines(db, userId),
  ]);
  const planData = planSnap.data();
  const dayKeys = planData && typeof planData.days === "object" && planData.days !== null ? Object.keys(planData.days) : [];
  const days = dayKeys
    .map((dayKey) => {
      const day = resolvePlanDay(planData, dayKey, today);
      return day ? { ...day, dayKey } : null;
    })
    .filter((day): day is BankDay => day !== null && day.exercises.length > 0);
  const profile = profileSnap.data() ?? {};
  const preferences = typeof profile.preferences === "object" && profile.preferences !== null ? profile.preferences : {};
  const schedule = typeof profile.schedule === "object" && profile.schedule !== null ? profile.schedule : {};
  const focus = typeof preferences.trainingFocus === "string" ? preferences.trainingFocus : profile.trainingFocus;
  const bank = buildAlternativesBank({
    days,
    profile: {
      goals: Array.isArray(profile.goals) ? profile.goals.filter((g: unknown): g is string => typeof g === "string") : [],
      trainingFocus: typeof focus === "string" ? focus : undefined,
      sessionLengthMin: typeof schedule.sessionLengthMin === "number" ? schedule.sessionLengthMin : undefined,
    },
    equipment: orderedEquipment(Array.isArray(profile.equipment) ? profile.equipment : undefined),
    baselines,
    today,
  });
  return { ok: true, bank };
}

/** Catalog gear in the order the person listed it; null = a full gym. */
export function orderedEquipment(saved: readonly unknown[] | undefined): Equipment[] | null {
  const strings = (saved ?? []).filter((item): item is string => typeof item === "string");
  if (catalogEquipment(strings) === null) return null;
  const ordered: Equipment[] = [];
  for (const entry of strings) {
    for (const gear of catalogEquipment([entry]) ?? []) {
      if (!ordered.includes(gear)) ordered.push(gear);
    }
  }
  return ordered;
}
