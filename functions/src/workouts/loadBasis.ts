import { allExercises, type CatalogEntry } from "./exerciseCatalog.js";

/**
 * How a lift's weight is counted. The stored number is what's on ONE
 * dumbbell or kettlebell, or the whole load for a barbell, machine or
 * anything else — what plans already hold (a "moderate" dumbbell lift
 * starts at 20 lb, a barbell at 45+). Mirror of the app's
 * ios/IronBoi/IronBoi/Models/WeightLoad.swift; exerciseCatalog.test.ts
 * keeps the patterns and the per-lift table in step.
 */
// "bar": a barbell, counted as the total with the bar ("25s a side" = 95).
export type LoadBasis = "each" | "one" | "bar" | "total";

// Same strings as the Swift raw strings (single backslashes there).
export const IMPLEMENT_PATTERN = "\\b(dumbbells?|dbs?|kettlebells?|kbs?)\\b";
export const SINGLE_IMPLEMENT_PATTERN =
  "\\b(single|one)[- ]?(arm|hand|leg)\\b|\\b(goblet|swings?|halo|suitcase|clean (&|and) press|tricep extension|(kb|kettlebell) curls?)\\b";
export const ONE_OBJECT_PATTERN = "\\b(clubs?|sandbag|med ?ball)\\b";
export const BAR_PATTERN = "\\b(barbell|ez[- ]?bar|trap bar|bb)\\b";

const implement = new RegExp(IMPLEMENT_PATTERN, "i");
const singleImplement = new RegExp(SINGLE_IMPLEMENT_PATTERN, "i");
const oneObject = new RegExp(ONE_OBJECT_PATTERN, "i");
const bar = new RegExp(BAR_PATTERN, "i");
const stance = /^(seated|sitting|standing|half[- ]?kneeling|tall[- ]?kneeling|kneeling|incline|decline)\s+/i;

function catalogBasis(entry: CatalogEntry): LoadBasis {
  if (entry.equipment.includes("barbell")) return "bar";
  if (entry.equipment.some((e) => e === "club" || e === "sandbag" || e === "medball")) return "one";
  if (entry.equipment.some((e) => e === "dumbbell" || e === "kettlebell")) {
    return singleImplement.test(entry.name) ? "one" : "each";
  }
  return "total";
}

/** The catalog lifts that aren't a total — the table the app mirrors. */
export function catalogLoadBases(): Record<string, LoadBasis> {
  const out: Record<string, LoadBasis> = {};
  for (const entry of allExercises()) {
    const basis = catalogBasis(entry);
    if (basis !== "total") out[entry.name] = basis;
  }
  return out;
}

// Exact names only, like the app's dictionary: the catalog's fuzzy lookup
// would call "Shoulder Press" a dumbbell lift here and a total on the phone.
function exactEntry(name: string): CatalogEntry | undefined {
  return allExercises().find((entry) => entry.name === name);
}

export function loadBasis(exerciseName: string): LoadBasis {
  const entry = exactEntry(exerciseName) ?? exactEntry(exerciseName.replace(stance, ""));
  if (entry) return catalogBasis(entry);
  if (implement.test(exerciseName)) return singleImplement.test(exerciseName) ? "one" : "each";
  if (oneObject.test(exerciseName)) return "one";
  if (bar.test(exerciseName)) return "bar";
  return "total";
}

function num(pounds: number): string {
  return Number.isInteger(pounds) ? String(pounds) : pounds.toFixed(1);
}

/** "35 lb each", "35 lb", "135 lb total" — the app's on-screen label. */
export function weightLabel(pounds: number, exerciseName: string): string {
  const basis = loadBasis(exerciseName);
  if (basis === "each") return `${num(pounds)} lb each`;
  if (basis === "one") return `${num(pounds)} lb`;
  return `${num(pounds)} lb total`;
}

/** "35 lb in each hand", "35 lb", "135 lb total" — for the coach's prompt. */
export function weightPhrase(pounds: number, exerciseName: string): string {
  const basis = loadBasis(exerciseName);
  if (basis === "each") return `${num(pounds)} lb in each hand (two dumbbells or kettlebells, ${num(pounds * 2)} lb total)`;
  if (basis === "one") return `${num(pounds)} lb (one ${/kb|kettlebell/i.test(exerciseName) ? "kettlebell" : "weight"})`;
  return `${num(pounds)} lb total`;
}
