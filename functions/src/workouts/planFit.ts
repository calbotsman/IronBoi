import type { z } from "zod";
import type { PlannedWorkoutDay, TrainingExperience } from "../contracts/coach-agent.js";
import {
  type Equipment,
  lookupExercise,
  suggestSwaps,
  suggestedLoadForSwap,
} from "./exerciseCatalog.js";

// Fits a generated plan to the person: only movements their equipment allows,
// at weights that make sense for how long they've been training.
//
// Before this, every plan was the seed's — a beginner with "dumbbells and a
// bench" got Barbell Back Squat at 135 and Bench Press at 155 on day one.

type PlannedDay = z.infer<typeof PlannedWorkoutDay>;
type Experience = z.infer<typeof TrainingExperience>;

/**
 * What the onboarding answer means in catalog terms. `null` = a full gym (no
 * constraint); an empty set = bodyweight only.
 */
export function equipmentFromAnswer(answer: readonly string[] | undefined): Set<Equipment> | null {
  const text = (answer ?? []).join(" ").toLowerCase();
  if (!text.trim()) return null;
  if (/\b(full|commercial|public)?\s*gym\b/.test(text) && !/\bhome gym\b/.test(text)) return null;

  const have = new Set<Equipment>();
  if (/home gym/.test(text)) {
    for (const item of ["dumbbell", "barbell", "bench", "pullup_bar", "kettlebell"] as const) have.add(item);
  }
  if (/dumbbell|\bdbs?\b/.test(text)) have.add("dumbbell");
  if (/barbell|squat rack|power rack/.test(text)) have.add("barbell");
  if (/kettle ?bell|\bkbs?\b/.test(text)) have.add("kettlebell");
  if (/bench/.test(text)) have.add("bench");
  if (/pull[- ]?up|chin[- ]?up/.test(text)) have.add("pullup_bar");
  if (/cable/.test(text)) have.add("cable");
  if (/machine/.test(text)) have.add("machine");
  if (/band/.test(text)) have.add("band");
  if (/club/.test(text)) have.add("club");
  if (/sandbag/.test(text)) have.add("sandbag");
  if (/med(icine)? ?ball/.test(text)) have.add("medball");
  // "Bodyweight", "none", "nothing": the empty set — bodyweight movements only.
  return have;
}

const GEAR_NAMES: Array<[Equipment, string]> = [
  ["dumbbell", "dumbbells"], ["kettlebell", "kettlebells"], ["barbell", "barbell"], ["bench", "bench"],
  ["pullup_bar", "pull-up bar"], ["cable", "cable machine"], ["machine", "machines"], ["band", "bands"],
  ["sandbag", "sandbag"], ["club", "clubs"], ["medball", "medicine ball"],
];

/**
 * What someone said they have, as a clean list: "I'm gonna train at home. I
 * have kettle bells, dumbbells and a barbell for benching" → ["kettlebells",
 * "dumbbells", "barbell", "bench"]. A gym stays "full gym"; nothing at all is
 * "bodyweight". Saved like this so the profile, the plan and the coach's
 * swaps all read the same thing.
 */
export function canonicalEquipment(answer: readonly string[] | undefined): string[] {
  const text = (answer ?? []).join(" ").toLowerCase();
  if (!text.trim()) return [];
  const have = equipmentFromAnswer(answer);
  if (have === null) return ["full gym"];
  const names = GEAR_NAMES.filter(([item]) => have.has(item)).map(([, name]) => name);
  return names.length > 0 ? names : ["bodyweight"];
}

/** Catalog equipment for a saved profile list; null = a full gym (anything goes). */
export function catalogEquipment(saved: readonly string[] | undefined): Equipment[] | null {
  const have = equipmentFromAnswer(saved);
  return have === null ? null : [...have];
}

// First-session weights as a share of the seed's (intermediate) numbers.
const EXPERIENCE_LOAD: Record<Experience, number> = {
  new: 0.4,
  beginner: 0.55,
  intermediate: 1,
  advanced: 1,
};

// A starting load when a swap crosses load classes and nothing carries over.
const DEFAULT_LOAD_LB = { bodyweight: 0, light: 10, moderate: 20, heavy: 30 } as const;

const BARBELL_MIN_LB = 45;

// Gear worth building sessions around when someone names it. A bench or a
// pull-up bar supports other moves; it isn't what they mean by "I got X".
const FEATURED: readonly Equipment[] = ["kettlebell", "band", "dumbbell", "barbell", "sandbag", "club", "medball"];

/** Every day of the plan, fitted to equipment and experience. */
export function fitPlanToUser(
  days: Record<string, PlannedDay>,
  input: { equipment?: readonly string[]; experience?: Experience },
): Record<string, PlannedDay> {
  const available = equipmentFromAnswer(input.equipment);
  const factor = EXPERIENCE_LOAD[input.experience ?? "intermediate"];
  // "I've got kettlebells" should mean kettlebell work, not just permission
  // for it: each training day gets at least one move with each piece of gear
  // they named (a full gym names nothing, so it's left alone).
  const featured = available ? FEATURED.filter((item) => available.has(item)) : [];
  let rotation = 0;
  return Object.fromEntries(
    Object.entries(days).map(([key, day]) => {
      let fitted = fitDay(day, available, factor);
      for (const gear of featured) fitted = ensureGear(fitted, gear, available!, factor, rotation);
      if (day.exercises.length > 0) rotation += 1;
      return [key, fitted];
    }),
  );
}

/**
 * If no move in the day uses `gear`, swap the first move that has a good
 * same-muscle substitute using it. `rotation` starts the search at a
 * different move on each day, so it isn't the same swap every session.
 */
function ensureGear(
  day: PlannedDay,
  gear: Equipment,
  available: Set<Equipment>,
  factor: number,
  rotation: number,
): PlannedDay {
  if (day.exercises.length === 0) return day;
  if (day.exercises.some((e) => lookupExercise(e.name)?.equipment.includes(gear))) return day;
  const names = day.exercises.map((e) => e.name);
  const order = day.exercises.map((_, i) => (i + rotation) % day.exercises.length);
  for (const index of order) {
    const exercise = day.exercises[index];
    const original = lookupExercise(exercise.name);
    // Keep the gear they named elsewhere in the day; trade bodyweight or
    // generic moves first.
    if (original && FEATURED.some((item) => item !== gear && original.equipment.includes(item) && available.has(item))) continue;
    const pick = suggestSwaps({ exerciseName: exercise.name, excludeNames: names, availableEquipment: [...available], limit: 12 })
      .find((option) => option.equipment.includes(gear) && option.score >= 0.75);
    if (!pick) continue;
    const replacement = lookupExercise(pick.name);
    const carried = suggestedLoadForSwap(exercise.name, pick.name, exercise.weight);
    const weight = carried > 0
      ? scaleLoad(carried, factor, pick.equipment)
      : DEFAULT_LOAD_LB[replacement?.loadClass ?? "bodyweight"];
    const { progression: _dropped, ...rest } = exercise;
    const exercises = [...day.exercises];
    exercises[index] = { ...rest, name: pick.name, weight };
    return { ...day, exercises };
  }
  return day;
}

function fitDay(day: PlannedDay, available: Set<Equipment> | null, factor: number): PlannedDay {
  if (day.exercises.length === 0) return day;
  const used = new Set<string>();
  const exercises: PlannedDay["exercises"] = [];

  for (const exercise of day.exercises) {
    const entry = lookupExercise(exercise.name);
    const allowed = available === null
      || (entry !== undefined && entry.equipment.every((item) => item === "none" || available.has(item)));

    if (allowed) {
      const name = entry?.name ?? exercise.name;
      if (used.has(name)) continue;
      used.add(name);
      // A bodyweight move with a load ("Walking Lunges, 45 lb") means holding
      // something; with nothing to hold, it's done unloaded.
      const holdsLoad = !entry || entry.equipment.some((item) => item !== "none") || canHoldLoad(available);
      const weight = holdsLoad ? scaleLoad(exercise.weight, factor, entry?.equipment ?? []) : 0;
      exercises.push({ ...exercise, weight });
      continue;
    }

    // Not doable with their kit (or unknown to the catalog while they're
    // limited): the closest swap that is, or drop it.
    const [swap] = suggestSwaps({
      exerciseName: exercise.name,
      excludeNames: [...used, ...day.exercises.map((e) => e.name)],
      availableEquipment: [...(available ?? [])],
      limit: 1,
    });
    if (!swap || used.has(swap.name)) continue;
    used.add(swap.name);
    const carried = suggestedLoadForSwap(exercise.name, swap.name, exercise.weight);
    const replacement = lookupExercise(swap.name);
    const base = carried > 0 ? carried : DEFAULT_LOAD_LB[replacement?.loadClass ?? "bodyweight"];
    const { progression: _dropped, ...rest } = exercise;
    exercises.push({
      ...rest,
      name: swap.name,
      // Defaults are already beginner-sized; only carried loads scale down.
      weight: carried > 0 ? scaleLoad(base, factor, swap.equipment) : base,
    });
  }
  return { ...day, exercises };
}

/** Something to hold for a loaded bodyweight move (lunges, carries). */
function canHoldLoad(available: Set<Equipment> | null): boolean {
  if (available === null) return true;
  return ["dumbbell", "kettlebell", "barbell", "sandbag", "medball"].some((item) => available.has(item as Equipment));
}

function scaleLoad(weight: number, factor: number, equipment: readonly Equipment[]): number {
  if (weight <= 0 || factor >= 1) return weight;
  const scaled = Math.max(5, Math.round((weight * factor) / 5) * 5);
  return equipment.includes("barbell") ? Math.max(BARBELL_MIN_LB, scaled) : scaled;
}
