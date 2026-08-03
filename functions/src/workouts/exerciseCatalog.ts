// The muscle/equipment knowledge behind exercise swaps.
//
// Why this lives on the server: swapping an exercise mutates the plan, and
// every plan mutation in this codebase is server-authoritative (firestore.rules
// gives the client no write path to workoutPlans.days, and none to
// trainingPrograms at all). If the CLIENT decided what a valid swap was, the
// server would be rubber-stamping an arbitrary exercise name into the user's
// program — so the catalog has to be here, where the swap is validated.
//
// iOS keeps its own ExerciseKnowledge table for cues and demo videos. That is
// presentation; this is the decision surface. They overlap in the name list on
// purpose, and CATALOG is the authority for anything that changes a plan.

// Single source of the equipment vocabulary — the callable's Zod enum, the
// coach tool declaration, and this module's own filtering all derive from it,
// so a new kind of gear is added in exactly one place.
export const CATALOG_EQUIPMENT = [
  "none",
  "dumbbell",
  "barbell",
  "kettlebell",
  "bench",
  "pullup_bar",
  "cable",
  "machine",
  "band",
  "club",
  "sandbag",
  "medball",
] as const;

export type Equipment = (typeof CATALOG_EQUIPMENT)[number];

// Coarse movement patterns. Muscle overlap alone ranks a Lateral Raise as a
// fine substitute for an Overhead Press (both hit delts) when it plainly
// isn't — one presses a load overhead, the other doesn't. Pattern is the
// tiebreaker that keeps a swap training the same JOB, not just the same
// tissue.
export type MovementPattern =
  | "horizontal_push"
  | "vertical_push"
  | "horizontal_pull"
  | "vertical_pull"
  | "squat"
  | "hinge"
  | "lunge"
  | "carry"
  | "core"
  | "conditioning"
  | "mobility"
  | "isolation_arm"
  | "isolation_shoulder"
  | "isolation_calf";

export type CatalogEntry = {
  name: string;
  primary: string[];
  secondary: string[];
  equipment: Equipment[];
  pattern: MovementPattern;
  // Roughly "how much external load does this movement normally carry",
  // used to decide whether the weight from the exercise being replaced can
  // carry over to its replacement. A 135 lb barbell squat's number is
  // meaningless on a goblet squat.
  loadClass: "bodyweight" | "light" | "moderate" | "heavy";
};

// Display muscle names are kept human ("Upper chest", "Front delts") because
// they surface directly in the swap UI. Scoring canonicalizes them first —
// otherwise "Upper chest" and "Chest" read as unrelated muscles and an
// Incline Dumbbell Press scores zero against a Bench Press.
const MUSCLE_CANON: Record<string, string> = {
  "upper chest": "chest",
  chest: "chest",
  "front delts": "delts",
  "side delts": "delts",
  "rear delts": "delts",
  delts: "delts",
  traps: "traps",
  lats: "lats",
  "mid back": "lats",
  erectors: "erectors",
  biceps: "biceps",
  brachialis: "biceps",
  forearms: "forearms",
  triceps: "triceps",
  quads: "quads",
  hamstrings: "hamstrings",
  glutes: "glutes",
  adductors: "adductors",
  calves: "calves",
  core: "core",
  "hip flexors": "core",
};

export function canonicalMuscle(muscle: string): string {
  const key = muscle.trim().toLowerCase();
  return MUSCLE_CANON[key] ?? key;
}

// Exercise identity. Firestore keys and baseline lookups both run through
// this, so "Single-arm DB Row", "single arm db row" and "Single-Arm DB Row"
// are one exercise rather than three.
export function normalizeExerciseKey(name: string): string {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
}

// The first 43 entries mirror iOS ExerciseKnowledge exactly (same names, same
// primary/secondary muscles) so a swap can never propose something the app
// can't render cues for. The remainder are added ALTERNATES: without them a
// bodyweight-only user asking to swap a Barbell Back Squat has nothing to be
// offered, which is the exact situation this feature exists for.
const ENTRIES: CatalogEntry[] = [
  // --- Push -------------------------------------------------------------
  { name: "Barbell Bench Press", primary: ["Chest"], secondary: ["Triceps", "Front delts"], equipment: ["barbell", "bench"], pattern: "horizontal_push", loadClass: "heavy" },
  { name: "Incline Dumbbell Press", primary: ["Upper chest"], secondary: ["Front delts", "Triceps"], equipment: ["dumbbell", "bench"], pattern: "horizontal_push", loadClass: "moderate" },
  { name: "Diamond Push-ups", primary: ["Triceps"], secondary: ["Chest", "Front delts"], equipment: ["none"], pattern: "horizontal_push", loadClass: "bodyweight" },
  { name: "Weighted Dips", primary: ["Chest", "Triceps"], secondary: ["Front delts"], equipment: ["none"], pattern: "horizontal_push", loadClass: "moderate" },
  { name: "Push-ups", primary: ["Chest"], secondary: ["Triceps", "Front delts"], equipment: ["none"], pattern: "horizontal_push", loadClass: "bodyweight" },
  { name: "Overhead Press", primary: ["Front delts", "Side delts"], secondary: ["Triceps", "Upper chest"], equipment: ["barbell"], pattern: "vertical_push", loadClass: "heavy" },
  { name: "Dumbbell Shoulder Press", primary: ["Front delts", "Side delts"], secondary: ["Triceps"], equipment: ["dumbbell"], pattern: "vertical_push", loadClass: "moderate" },
  { name: "Arnold Press", primary: ["Front delts", "Side delts"], secondary: ["Rear delts", "Triceps"], equipment: ["dumbbell"], pattern: "vertical_push", loadClass: "moderate" },
  { name: "Lateral Raises", primary: ["Side delts"], secondary: ["Rear delts"], equipment: ["dumbbell"], pattern: "isolation_shoulder", loadClass: "light" },
  { name: "KB Clean & Press", primary: ["Front delts", "Side delts"], secondary: ["Traps", "Triceps", "Glutes"], equipment: ["kettlebell"], pattern: "vertical_push", loadClass: "moderate" },
  { name: "Heavy Club Mill", primary: ["Side delts", "Rear delts"], secondary: ["Lats", "Core"], equipment: ["club"], pattern: "isolation_shoulder", loadClass: "light" },
  { name: "Heavy Club Shield Cast", primary: ["Front delts", "Chest"], secondary: ["Core", "Triceps"], equipment: ["club"], pattern: "isolation_shoulder", loadClass: "light" },
  { name: "Skull Crushers", primary: ["Triceps"], secondary: [], equipment: ["barbell", "bench"], pattern: "isolation_arm", loadClass: "light" },
  { name: "Overhead Tricep Extension", primary: ["Triceps"], secondary: [], equipment: ["dumbbell"], pattern: "isolation_arm", loadClass: "light" },
  // --- Pull -------------------------------------------------------------
  { name: "Deadlift", primary: ["Hamstrings", "Glutes"], secondary: ["Lats", "Erectors", "Traps"], equipment: ["barbell"], pattern: "hinge", loadClass: "heavy" },
  { name: "Romanian Deadlift", primary: ["Hamstrings", "Glutes"], secondary: ["Erectors"], equipment: ["barbell"], pattern: "hinge", loadClass: "heavy" },
  { name: "Bent-over Barbell Row", primary: ["Lats", "Mid back"], secondary: ["Biceps", "Rear delts"], equipment: ["barbell"], pattern: "horizontal_pull", loadClass: "heavy" },
  { name: "Inverted Row", primary: ["Lats", "Mid back"], secondary: ["Biceps", "Rear delts"], equipment: ["none"], pattern: "horizontal_pull", loadClass: "bodyweight" },
  { name: "Single-arm DB Row", primary: ["Lats"], secondary: ["Biceps", "Mid back"], equipment: ["dumbbell", "bench"], pattern: "horizontal_pull", loadClass: "moderate" },
  { name: "KB Single-arm Row", primary: ["Lats"], secondary: ["Biceps", "Rear delts"], equipment: ["kettlebell"], pattern: "horizontal_pull", loadClass: "moderate" },
  { name: "KB Halo", primary: ["Side delts", "Rear delts"], secondary: ["Core", "Traps"], equipment: ["kettlebell"], pattern: "isolation_shoulder", loadClass: "light" },
  { name: "Sandbag Carry", primary: ["Traps", "Core"], secondary: ["Biceps", "Lats"], equipment: ["sandbag"], pattern: "carry", loadClass: "heavy" },
  { name: "Hammer Curls", primary: ["Biceps"], secondary: ["Brachialis", "Forearms"], equipment: ["dumbbell"], pattern: "isolation_arm", loadClass: "light" },
  { name: "EZ Bar Curl", primary: ["Biceps"], secondary: ["Brachialis"], equipment: ["barbell"], pattern: "isolation_arm", loadClass: "light" },
  { name: "Incline Dumbbell Curl", primary: ["Biceps"], secondary: ["Brachialis"], equipment: ["dumbbell", "bench"], pattern: "isolation_arm", loadClass: "light" },
  { name: "KB Curl", primary: ["Biceps"], secondary: ["Forearms"], equipment: ["kettlebell"], pattern: "isolation_arm", loadClass: "light" },
  // --- Legs -------------------------------------------------------------
  { name: "Barbell Back Squat", primary: ["Quads", "Glutes"], secondary: ["Hamstrings", "Erectors"], equipment: ["barbell"], pattern: "squat", loadClass: "heavy" },
  { name: "Walking Lunges", primary: ["Quads", "Glutes"], secondary: ["Hamstrings", "Core"], equipment: ["none"], pattern: "lunge", loadClass: "bodyweight" },
  { name: "Bulgarian Split Squat", primary: ["Quads", "Glutes"], secondary: ["Hamstrings"], equipment: ["bench"], pattern: "lunge", loadClass: "light" },
  { name: "KB Goblet Squat", primary: ["Quads", "Glutes"], secondary: ["Core", "Adductors"], equipment: ["kettlebell"], pattern: "squat", loadClass: "moderate" },
  { name: "Hip Thrust", primary: ["Glutes"], secondary: ["Hamstrings", "Core"], equipment: ["barbell", "bench"], pattern: "hinge", loadClass: "heavy" },
  { name: "KB Swing", primary: ["Hamstrings", "Glutes"], secondary: ["Core", "Lats"], equipment: ["kettlebell"], pattern: "hinge", loadClass: "moderate" },
  { name: "Standing Calf Raises", primary: ["Calves"], secondary: [], equipment: ["none"], pattern: "isolation_calf", loadClass: "bodyweight" },
  { name: "Sandbag Clean & Squat", primary: ["Quads", "Glutes"], secondary: ["Lats", "Core", "Traps"], equipment: ["sandbag"], pattern: "squat", loadClass: "moderate" },
  // --- Core / conditioning ---------------------------------------------
  { name: "Plank", primary: ["Core"], secondary: ["Chest", "Front delts"], equipment: ["none"], pattern: "core", loadClass: "bodyweight" },
  { name: "Hanging Leg Raises", primary: ["Core"], secondary: ["Hip flexors", "Lats"], equipment: ["pullup_bar"], pattern: "core", loadClass: "bodyweight" },
  { name: "Med Ball Slam", primary: ["Core", "Lats"], secondary: ["Front delts", "Glutes"], equipment: ["medball"], pattern: "conditioning", loadClass: "light" },
  { name: "HIIT Sprints (20s on/10s off)", primary: ["Quads", "Hamstrings"], secondary: ["Glutes", "Calves"], equipment: ["none"], pattern: "conditioning", loadClass: "bodyweight" },
  { name: "Zone 2 Walk/Jog", primary: ["Quads", "Hamstrings"], secondary: ["Glutes", "Calves"], equipment: ["none"], pattern: "conditioning", loadClass: "bodyweight" },
  { name: "Foam Rolling", primary: ["Core"], secondary: [], equipment: ["none"], pattern: "mobility", loadClass: "bodyweight" },
  { name: "Stretching Circuit", primary: ["Core"], secondary: [], equipment: ["none"], pattern: "mobility", loadClass: "bodyweight" },

  // --- Added alternates -------------------------------------------------
  // Every entry above this line exists on iOS. Everything below is here so
  // that "I have no equipment" and "I don't feel like doing this move" have
  // real answers in every muscle group rather than an empty option list.
  { name: "Incline Push-ups", primary: ["Chest"], secondary: ["Triceps", "Front delts"], equipment: ["none"], pattern: "horizontal_push", loadClass: "bodyweight" },
  { name: "Decline Push-ups", primary: ["Upper chest"], secondary: ["Triceps", "Front delts"], equipment: ["none"], pattern: "horizontal_push", loadClass: "bodyweight" },
  { name: "Dumbbell Bench Press", primary: ["Chest"], secondary: ["Triceps", "Front delts"], equipment: ["dumbbell", "bench"], pattern: "horizontal_push", loadClass: "moderate" },
  { name: "Dumbbell Floor Press", primary: ["Chest"], secondary: ["Triceps"], equipment: ["dumbbell"], pattern: "horizontal_push", loadClass: "moderate" },
  { name: "Pike Push-ups", primary: ["Front delts", "Side delts"], secondary: ["Triceps"], equipment: ["none"], pattern: "vertical_push", loadClass: "bodyweight" },
  { name: "Band Lateral Raise", primary: ["Side delts"], secondary: ["Rear delts"], equipment: ["band"], pattern: "isolation_shoulder", loadClass: "light" },
  { name: "Bench Dips", primary: ["Triceps"], secondary: ["Chest", "Front delts"], equipment: ["bench"], pattern: "isolation_arm", loadClass: "bodyweight" },
  { name: "Pull-ups", primary: ["Lats"], secondary: ["Biceps", "Mid back"], equipment: ["pullup_bar"], pattern: "vertical_pull", loadClass: "bodyweight" },
  { name: "Chin-ups", primary: ["Lats", "Biceps"], secondary: ["Mid back"], equipment: ["pullup_bar"], pattern: "vertical_pull", loadClass: "bodyweight" },
  { name: "Band Row", primary: ["Lats", "Mid back"], secondary: ["Biceps", "Rear delts"], equipment: ["band"], pattern: "horizontal_pull", loadClass: "light" },
  { name: "Superman Hold", primary: ["Erectors"], secondary: ["Glutes", "Rear delts"], equipment: ["none"], pattern: "hinge", loadClass: "bodyweight" },
  { name: "Back Extension", primary: ["Erectors"], secondary: ["Glutes", "Hamstrings"], equipment: ["bench"], pattern: "hinge", loadClass: "bodyweight" },
  { name: "Good Morning", primary: ["Erectors", "Hamstrings"], secondary: ["Glutes"], equipment: ["barbell"], pattern: "hinge", loadClass: "moderate" },
  { name: "Dumbbell Romanian Deadlift", primary: ["Hamstrings", "Glutes"], secondary: ["Erectors"], equipment: ["dumbbell"], pattern: "hinge", loadClass: "moderate" },
  { name: "Single-leg Romanian Deadlift", primary: ["Hamstrings", "Glutes"], secondary: ["Core", "Erectors"], equipment: ["none"], pattern: "hinge", loadClass: "bodyweight" },
  { name: "Glute Bridge", primary: ["Glutes"], secondary: ["Hamstrings", "Core"], equipment: ["none"], pattern: "hinge", loadClass: "bodyweight" },
  { name: "Nordic Hamstring Curl", primary: ["Hamstrings"], secondary: ["Glutes", "Core"], equipment: ["none"], pattern: "hinge", loadClass: "bodyweight" },
  { name: "Bodyweight Squat", primary: ["Quads", "Glutes"], secondary: ["Hamstrings", "Core"], equipment: ["none"], pattern: "squat", loadClass: "bodyweight" },
  { name: "Dumbbell Goblet Squat", primary: ["Quads", "Glutes"], secondary: ["Core", "Adductors"], equipment: ["dumbbell"], pattern: "squat", loadClass: "moderate" },
  { name: "Reverse Lunge", primary: ["Quads", "Glutes"], secondary: ["Hamstrings", "Core"], equipment: ["none"], pattern: "lunge", loadClass: "bodyweight" },
  { name: "Step-ups", primary: ["Quads", "Glutes"], secondary: ["Hamstrings", "Calves"], equipment: ["bench"], pattern: "lunge", loadClass: "bodyweight" },
  { name: "Wall Sit", primary: ["Quads"], secondary: ["Glutes", "Core"], equipment: ["none"], pattern: "squat", loadClass: "bodyweight" },
  { name: "Single-leg Calf Raise", primary: ["Calves"], secondary: [], equipment: ["none"], pattern: "isolation_calf", loadClass: "bodyweight" },
  { name: "Dead Bug", primary: ["Core"], secondary: ["Hip flexors"], equipment: ["none"], pattern: "core", loadClass: "bodyweight" },
  { name: "Hollow Body Hold", primary: ["Core"], secondary: ["Hip flexors"], equipment: ["none"], pattern: "core", loadClass: "bodyweight" },
  { name: "Side Plank", primary: ["Core"], secondary: ["Side delts", "Glutes"], equipment: ["none"], pattern: "core", loadClass: "bodyweight" },
  { name: "Bird Dog", primary: ["Core"], secondary: ["Erectors", "Glutes"], equipment: ["none"], pattern: "core", loadClass: "bodyweight" },
  { name: "Mountain Climbers", primary: ["Core"], secondary: ["Quads", "Front delts"], equipment: ["none"], pattern: "conditioning", loadClass: "bodyweight" },
  { name: "Burpees", primary: ["Quads", "Chest"], secondary: ["Core", "Front delts"], equipment: ["none"], pattern: "conditioning", loadClass: "bodyweight" },
  { name: "Jump Rope", primary: ["Calves", "Quads"], secondary: ["Core"], equipment: ["none"], pattern: "conditioning", loadClass: "bodyweight" },
  { name: "Incline Walk", primary: ["Quads", "Glutes"], secondary: ["Calves"], equipment: ["none"], pattern: "conditioning", loadClass: "bodyweight" },
  { name: "Farmer Carry", primary: ["Traps", "Core"], secondary: ["Forearms"], equipment: ["dumbbell"], pattern: "carry", loadClass: "heavy" },
  { name: "Suitcase Carry", primary: ["Core", "Traps"], secondary: ["Forearms"], equipment: ["kettlebell"], pattern: "carry", loadClass: "moderate" },
];

const BY_KEY = new Map(ENTRIES.map((entry) => [normalizeExerciseKey(entry.name), entry]));

// Tokens reduced to a singular-ish stem, so "Walking Lunge" and "Walking
// Lunges" are the same movement. Crude on purpose — this only ever compares
// against the fixed catalog, never against free text.
function stemTokens(name: string): Set<string> {
  return new Set(
    normalizeExerciseKey(name)
      .split("_")
      .filter((token) => token.length > 0)
      // Threshold 2, not 3: "ups" in "Push-ups" has to stem to "up" for
      // "Push-up" to resolve. Stems need only be CONSISTENT, not correct
      // English — both sides of every comparison run through this.
      .map((token) => (token.length > 2 && token.endsWith("s") ? token.slice(0, -1) : token)),
  );
}

const BY_STEM = ENTRIES.map((entry) => ({ entry, tokens: stemTokens(entry.name) }));

// Resolves a plan's exercise name to a catalog entry.
//
// Exercise names are not a controlled vocabulary: the coach's adapt_plan tool
// lets the model author a name freely, and older plans carry shorthand
// ("Back Squat" for "Barbell Back Squat"). An exact-match-only lookup means
// the swap button opens an empty list for those — the precise situation this
// feature exists to fix.
//
// So: exact key first, then a token-subset match. "back squat" ⊂ "barbell
// back squat" resolves; a bare "squat" matches three entries and therefore
// resolves to NOTHING. Ambiguity must never silently pick a movement — an
// empty list is honest, a wrong substitute is not.
// Shorthands that are genuinely ambiguous by token-matching but have one
// obvious meaning in a gym. "Bench press" matches both the barbell and
// dumbbell entries, so the subset rule below refuses it — yet an unqualified
// "Bench Press" is what plans in this repo actually say, and it means the
// barbell. Curated, not inferred: each line is a decision someone made, and
// anything not listed here still falls through to the ambiguity rule.
const ALIASES: Record<string, string> = {
  bench_press: "Barbell Bench Press",
  squat: "Barbell Back Squat",
  row: "Bent-over Barbell Row",
  curl: "EZ Bar Curl",
  lunge: "Walking Lunges",
};

export function lookupExercise(name: string): CatalogEntry | undefined {
  const exact = BY_KEY.get(normalizeExerciseKey(name));
  if (exact) return exact;

  const alias = ALIASES[normalizeExerciseKey(name)];
  if (alias) return BY_KEY.get(normalizeExerciseKey(alias));

  const queryTokens = stemTokens(name);
  if (queryTokens.size === 0) return undefined;

  const matches = BY_STEM.filter(({ tokens }) => isSubset(queryTokens, tokens));
  if (matches.length === 1) return matches[0].entry;

  // Several entries contain the query's tokens. Prefer an exact token-set
  // equality if one exists ("push up" vs "push ups" after stemming); a real
  // tie stays unresolved.
  const equal = matches.filter(({ tokens }) => tokens.size === queryTokens.size);
  return equal.length === 1 ? equal[0].entry : undefined;
}

function isSubset(subset: Set<string>, superset: Set<string>): boolean {
  for (const token of subset) {
    if (!superset.has(token)) return false;
  }
  return true;
}

export function allExercises(): readonly CatalogEntry[] {
  return ENTRIES;
}

export type SwapCandidate = {
  name: string;
  primary: string[];
  secondary: string[];
  equipment: Equipment[];
  pattern: MovementPattern;
  score: number;
  // One plain line the user reads on the option row. Built here rather than
  // on the client so the ranking and its stated justification can never
  // disagree.
  reason: string;
};

// Muscle overlap, 0..1. Primary muscles carry the weight; secondary counts
// for a quarter, enough to break ties between two movements that match the
// same primary but only one of which also trains what the original did.
function muscleOverlap(a: CatalogEntry, b: CatalogEntry): number {
  const aPrimary = new Set(a.primary.map(canonicalMuscle));
  const bPrimary = new Set(b.primary.map(canonicalMuscle));
  const aSecondary = new Set(a.secondary.map(canonicalMuscle));
  const bSecondary = new Set(b.secondary.map(canonicalMuscle));

  if (aPrimary.size === 0) return 0;

  let primaryHits = 0;
  for (const muscle of aPrimary) {
    if (bPrimary.has(muscle)) primaryHits += 1;
  }
  // Union, not just the original's count — a movement that hits the same one
  // primary muscle PLUS three others is a less faithful swap than one that
  // hits exactly the same primary.
  const primaryUnion = new Set([...aPrimary, ...bPrimary]).size;
  const primaryScore = primaryHits / primaryUnion;

  let secondaryHits = 0;
  for (const muscle of aSecondary) {
    if (bSecondary.has(muscle) || bPrimary.has(muscle)) secondaryHits += 1;
  }
  const secondaryScore = aSecondary.size === 0 ? 0 : secondaryHits / aSecondary.size;

  return primaryScore * 0.8 + secondaryScore * 0.2;
}

function equipmentSatisfied(entry: CatalogEntry, available: Set<Equipment> | null): boolean {
  if (!available) return true;
  // "none" is never a constraint — a movement that needs nothing is always
  // available, including to someone who listed no equipment at all.
  return entry.equipment.every((item) => item === "none" || available.has(item));
}

function describeEquipment(entry: CatalogEntry): string {
  const needed = entry.equipment.filter((item) => item !== "none");
  if (needed.length === 0) return "no equipment";
  return needed.map((item) => item.replace(/_/g, " ")).join(" + ");
}

export type SwapOptionsInput = {
  exerciseName: string;
  // Names already in the day. Offering a swap to something the user is
  // already doing two exercises later is not an option, it's a bug.
  excludeNames?: string[];
  // null = no equipment constraint. An empty array is NOT the same thing:
  // it means "I have nothing", which filters to bodyweight-only.
  availableEquipment?: Equipment[] | null;
  limit?: number;
};

// Ranks catalog movements as substitutes for `exerciseName`.
//
// A candidate must share at least one canonical PRIMARY muscle to be offered
// at all. Ranking a movement that happens to share a secondary muscle would
// let "Plank" surface as a substitute for "Barbell Bench Press" (both list
// chest somewhere), and an option list the user can't trust is worse than no
// option list.
export function suggestSwaps(input: SwapOptionsInput): SwapCandidate[] {
  const original = lookupExercise(input.exerciseName);
  if (!original) return [];

  const limit = input.limit ?? 6;
  // Exclude by RESOLVED name. A plan saying "Back Squat" resolves to
  // "Barbell Back Squat"; excluding the raw string would leave the catalog
  // free to offer that exercise as a substitute for itself.
  const excluded = new Set(
    [input.exerciseName, ...(input.excludeNames ?? [])].map((name) =>
      normalizeExerciseKey(lookupExercise(name)?.name ?? name),
    ),
  );
  const available =
    input.availableEquipment === undefined || input.availableEquipment === null
      ? null
      : new Set(input.availableEquipment);
  const originalPrimary = new Set(original.primary.map(canonicalMuscle));

  const scored: SwapCandidate[] = [];
  for (const entry of ENTRIES) {
    if (excluded.has(normalizeExerciseKey(entry.name))) continue;
    if (!equipmentSatisfied(entry, available)) continue;

    const sharesPrimary = entry.primary
      .map(canonicalMuscle)
      .some((muscle) => originalPrimary.has(muscle));
    if (!sharesPrimary) continue;

    const overlap = muscleOverlap(original, entry);
    const samePattern = entry.pattern === original.pattern;
    const sameLoadClass = entry.loadClass === original.loadClass;
    const score = overlap + (samePattern ? 0.35 : 0) + (sameLoadClass ? 0.05 : 0);

    const sharedPrimaryNames = entry.primary.filter((muscle) =>
      originalPrimary.has(canonicalMuscle(muscle)),
    );
    const reason = `${sharedPrimaryNames.join(" + ")} · ${describeEquipment(entry)}${
      samePattern ? " · same movement" : ""
    }`;

    scored.push({
      name: entry.name,
      primary: entry.primary,
      secondary: entry.secondary,
      equipment: entry.equipment,
      pattern: entry.pattern,
      score: Math.round(score * 1000) / 1000,
      reason,
    });
  }

  // Name as the final tiebreak so identical scores rank deterministically —
  // a swap list that reshuffles between two identical requests reads as
  // broken, and makes the ranking untestable.
  scored.sort((a, b) => b.score - a.score || a.name.localeCompare(b.name));
  return scored.slice(0, limit);
}

// Whether `replacementName` is a defensible substitute for `originalName`.
// This is the server-side gate on swapExercise: the client proposes, but a
// replacement that doesn't share a primary muscle never reaches the plan.
export function isValidSwap(originalName: string, replacementName: string): boolean {
  const original = lookupExercise(originalName);
  const replacement = lookupExercise(replacementName);
  if (!original || !replacement) return false;
  // Compare RESOLVED names: "Back Squat" and "Barbell Back Squat" are the
  // same movement, and swapping one for the other is a no-op dressed up as
  // a change.
  if (normalizeExerciseKey(original.name) === normalizeExerciseKey(replacement.name)) return false;

  const originalPrimary = new Set(original.primary.map(canonicalMuscle));
  return replacement.primary.map(canonicalMuscle).some((muscle) => originalPrimary.has(muscle));
}

// What to put on the bar for a swapped-in exercise, before the user's own
// baseline is consulted.
//
// Load does NOT carry across load classes. 225 lb is a reasonable barbell
// squat and an impossible goblet squat, so proposing it would be worse than
// proposing nothing. When the classes differ, this returns 0 — which the UI
// renders as "set your weight" rather than a fake prescription.
export function suggestedLoadForSwap(
  originalName: string,
  replacementName: string,
  originalWeightLb: number,
): number {
  const original = lookupExercise(originalName);
  const replacement = lookupExercise(replacementName);
  if (!original || !replacement) return 0;
  if (replacement.loadClass === "bodyweight") return 0;
  if (original.loadClass !== replacement.loadClass) return 0;
  return originalWeightLb;
}
