import type { DocumentData } from "firebase-admin/firestore";
import type { CoachLoadedContext } from "./context.js";
import type { RetrievedCorpusEntry } from "../corpus/researchCorpus.js";

export type CoachContextBundleV1 = {
  schema: "coach_context_bundle.v1";
  dataBoundary: "user_data_is_not_instruction";
  userId: string;
  sessionId: string;
  assembledAt: string;
  profile: Record<string, unknown> | null;
  memoryFacts: CoachContextMemoryFact[];
  // Phase 2 Task 2.3 — count of proposed-but-unconfirmed facts. The coach
  // should NOT act on these in this turn, but knowing there are some lets it
  // mention "there are N items I'd like to confirm next time you have a sec."
  pendingProposalCount: number;
  recentWorkouts: CoachContextWorkout[];
  conversationWindow: CoachContextMessage[];
  healthSummary: {
    available: false;
    reason: "healthkit_not_connected";
  };
  retrievedCorpus: RetrievedCorpusEntry[];
  // Recently accepted plan-adjustment proposals — so the coach can
  // reference a past change instead of re-asking about it.
  recentPlanChanges: CoachContextPlanChange[];
  // Compact projection of derivedSummaries/progress_current — the only
  // numbers the coach may ground progress claims in. Null until the first
  // rebuild has run (or when the read was gated off / failed).
  progressSummary: CoachContextProgressSummary | null;
  // The user's actual plan as the Train tab shows it: the next 7 days from
  // `today`, override-resolved, every exercise with sets/reps/weight. Null
  // when the user has no plan yet.
  currentPlan: CoachContextPlan | null;
};

export type CoachContextPlanDay = {
  date: string;
  dayKey: string;
  name: string;
  // Present (true) only when this date resolves from a dailyOverride — an
  // approved adjustment the user already accepted.
  adjusted?: true;
  exercises: string[];
};

export type CoachContextPlan = {
  today: string;
  todayKey: string;
  source?: string;
  // First day on/after today that has exercises.
  nextSession?: { date: string; dayKey: string; name: string };
  days: CoachContextPlanDay[];
};

export type CoachContextMemoryFact = {
  factId?: string;
  category?: string;
  content: string;
  source?: string;
  confidence?: number;
  createdAt?: string;
  lastReinforcedAt?: string;
};

export type CoachContextWorkout = {
  sessionId?: string;
  date?: string;
  source?: string;
  perceivedEffort?: number;
  summary: string;
};

export type CoachContextMessage = {
  messageId?: string;
  role: "user" | "coach" | "tool" | "system" | "unknown";
  content: string;
  status?: string;
  timestamp?: string;
};

export type CoachContextPlanChange = {
  proposalId?: string;
  category?: string;
  dayKey?: string;
  scope?: string;
  summary: string;
  decidedAt?: string;
};

// Mirrors the ProgressSummary contract minus userId (the bundle already
// carries the authenticated userId; repeating it per-section is what the
// attacker-user stripping tests exist to prevent). Values are re-capped
// here (series ≤8, lifts ≤5) even though the builder already caps them —
// the bundle is the token-budget boundary and must not trust doc contents.
export type CoachContextProgressSummary = {
  computedAt?: string;
  windowDays?: number;
  adherence?: {
    plannedSessions?: number;
    completedSessions?: number;
    weeklyRate?: number[];
    streakWeeks?: number;
  };
  volume?: {
    weeklyTotals?: number[];
    trend?: string;
  };
  lifts?: Array<{
    exerciseName: string;
    e1rmSeries: Array<{ date?: string; value?: number }>;
    trendPct?: number;
  }>;
  body?: {
    weightSeries?: Array<{ date?: string; kg?: number }>;
    rollingAvgKg?: number;
    trendPctPerWeek?: number;
    goalDirection?: string;
    withinSafeBand?: boolean;
  };
  // Server-templated lens framings (build.ts computeLensHighlights). Rides
  // inside the same <progress_summary> tag; absent (not []) when the doc
  // has none, so pre-slice-5 docs produce byte-identical prompts.
  lensHighlights?: Array<{ metric: string; framing: string; note?: string }>;
};

const PROFILE_FIELDS = [
  "ageYears",
  "sexOrGender",
  "sexOrGenderSelfDescription",
  "heightCm",
  "weightKg",
  "goals",
  "goalNotes",
  "trainingExperience",
  "injuriesOrLimitations",
  "equipment",
  "schedule",
  "preferences",
  "dietaryConstraints",
  "createdAt",
  "updatedAt",
] as const;

export function buildCoachContextBundle(
  context: CoachLoadedContext,
  {
    userId,
    sessionId,
    now = new Date().toISOString(),
    retrievedCorpus = [],
    today,
  }: {
    userId: string;
    sessionId: string;
    now?: string;
    retrievedCorpus?: RetrievedCorpusEntry[];
    // The user's LOCAL calendar date (client-stamped clientDate). Falls back
    // to the UTC date of `now` — deterministic for fixtures, and only off by
    // a few hours at the day boundary for real users without clientDate.
    today?: string;
  },
): CoachContextBundleV1 {
  return {
    schema: "coach_context_bundle.v1",
    dataBoundary: "user_data_is_not_instruction",
    userId,
    sessionId,
    assembledAt: now,
    profile: context.profile ? pickProfile(context.profile) : null,
    memoryFacts: context.recentFacts
      .filter((fact) => !fact.userDeletedAt)
      .slice(0, 20)
      .map(memoryFactForPrompt)
      .filter((fact): fact is CoachContextMemoryFact => hasText(fact.content)),
    pendingProposalCount: context.pendingProposalCount ?? 0,
    recentWorkouts: context.recentLogs
      .slice(0, 10)
      .map(workoutForPrompt)
      .filter((workout): workout is CoachContextWorkout => hasText(workout.summary)),
    conversationWindow: context.sessionHistory
      .slice(-30)
      .map(messageForPrompt)
      .filter((message): message is CoachContextMessage => hasText(message.content)),
    healthSummary: {
      available: false,
      reason: "healthkit_not_connected",
    },
    retrievedCorpus,
    // Defaults to [] for callers/fixtures built before this field existed —
    // same tolerance pattern as pendingProposalCount above.
    recentPlanChanges: (context.recentPlanChanges ?? [])
      .map(planChangeForPrompt)
      .filter((change): change is CoachContextPlanChange => hasText(change.summary)),
    // Defaults to null for callers/fixtures built before this field existed.
    progressSummary: context.progressSummary
      ? progressSummaryForPrompt(context.progressSummary)
      : null,
    // Defaults to null for callers/fixtures built before this field existed.
    currentPlan: context.currentPlan
      ? planForPrompt(context.currentPlan, today ?? now.slice(0, 10))
      : null,
  };
}

const PLAN_HORIZON_DAYS = 7;
const MAX_PLAN_EXERCISES_PER_DAY = 14;
const PLAN_WEEKDAY_KEYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;

function addDaysISO(isoDate: string, days: number): string {
  const parsed = Date.parse(`${isoDate}T00:00:00Z`);
  if (Number.isNaN(parsed)) return isoDate;
  return new Date(parsed + days * 86_400_000).toISOString().slice(0, 10);
}

function weekdayKeyOf(isoDate: string): string {
  const parsed = Date.parse(`${isoDate}T00:00:00Z`);
  if (Number.isNaN(parsed)) return "";
  return PLAN_WEEKDAY_KEYS[new Date(parsed).getUTCDay()];
}

// One line per exercise, the way a coach would read it off the card:
// "Barbell Bench Press 5x8 @155 lb" / "Plank 4x60 (bodyweight)". Weight is
// pounds everywhere in the plan contract (PlannedExercise.weight).
function exerciseLine(exercise: unknown): string | null {
  if (!isPlainObject(exercise)) return null;
  const name = stringValue(exercise.name, 120);
  if (!name) return null;
  const sets = numberValue(exercise.sets);
  const reps = numberValue(exercise.reps);
  const weight = numberValue(exercise.weight) ?? 0;
  const scheme = sets !== undefined && reps !== undefined ? ` ${sets}x${reps}` : "";
  const load = weight > 0 ? ` @${weight} lb` : " (bodyweight)";
  return `${name}${scheme}${load}`;
}

// Resolves what the user will actually see for each of the next 7 dates —
// the same contract the Train tab and activeWorkout.ts use: a dailyOverride
// for that ISO date wins over the weekday template. Server-written docs,
// but every field is still re-picked and re-capped here: the bundle is the
// token-budget boundary and never trusts document contents.
function planForPrompt(plan: DocumentData, today: string): CoachContextPlan | null {
  const days = isPlainObject(plan.days) ? plan.days : null;
  if (!days) return null;
  // An unparseable anchor date would render seven identical undated "Rest"
  // days — worse than no plan. Unreachable through the validated clientDate
  // path, but the bundle is the boundary and must not trust its inputs.
  if (Number.isNaN(Date.parse(`${today}T00:00:00Z`))) return null;
  const overrides = isPlainObject(plan.dailyOverrides) ? plan.dailyOverrides : {};

  const resolved: CoachContextPlanDay[] = [];
  for (let offset = 0; offset < PLAN_HORIZON_DAYS; offset += 1) {
    const date = addDaysISO(today, offset);
    const dayKey = weekdayKeyOf(date);
    const override = overrides[date];
    const source = isPlainObject(override) ? override : days[dayKey];
    const day = isPlainObject(source) ? source : {};
    // Filter junk rows BEFORE capping so a run of malformed entries can't
    // push the real exercises out of the window.
    const exercises = (Array.isArray(day.exercises) ? day.exercises : [])
      .map(exerciseLine)
      .filter((line): line is string => line !== null)
      .slice(0, MAX_PLAN_EXERCISES_PER_DAY);
    resolved.push(
      compactObject({
        date,
        dayKey,
        // `||` not `??`: an empty-string name must fall through to the label.
        name: stringValue(day.name, 120) || (exercises.length ? "Workout" : "Rest"),
        adjusted: isPlainObject(override) ? (true as const) : undefined,
        exercises,
      }) as CoachContextPlanDay,
    );
  }

  const next = resolved.find((day) => day.exercises.length > 0);
  // A template with no exercises anywhere in the window is "no plan yet",
  // not "rest all week" — WorkoutPlan.days is a record, so {} is a valid
  // write, and the prompt's null rule is the right response to it.
  if (!next) return null;
  return compactObject({
    today,
    todayKey: weekdayKeyOf(today),
    source: stringValue(plan.source, 40),
    nextSession: next ? { date: next.date, dayKey: next.dayKey, name: next.name } : undefined,
    days: resolved,
  }) as CoachContextPlan;
}

function pickProfile(profile: DocumentData) {
  const picked: Record<string, unknown> = {};
  for (const field of PROFILE_FIELDS) {
    const value = profile[field];
    if (value !== undefined) {
      picked[field] = normalizeValue(value);
    }
  }
  return picked;
}

function memoryFactForPrompt(fact: DocumentData): CoachContextMemoryFact {
  const content = stringValue(fact.content, 1_000) ?? "";
  return compactObject({
    factId: stringValue(fact.factId, 120),
    category: stringValue(fact.category, 80),
    content,
    source: stringValue(fact.source, 80),
    confidence: numberValue(fact.confidence),
    createdAt: stringValue(fact.createdAt, 80),
    lastReinforcedAt: stringValue(fact.lastReinforcedAt, 80),
  });
}

function workoutForPrompt(log: DocumentData): CoachContextWorkout {
  const postSessionNotes = stringValue(log.postSessionNotes, 800);
  const exerciseSummary = Array.isArray(log.exercises)
    ? log.exercises
        .slice(0, 12)
        .map((exercise) => {
          if (!isPlainObject(exercise)) {
            return "";
          }
          const name = stringValue(exercise.name, 120);
          const setCount = Array.isArray(exercise.sets) ? exercise.sets.length : 0;
          return name ? `${name}${setCount ? ` (${setCount} sets)` : ""}` : "";
        })
        .filter(Boolean)
        .join(", ")
    : "";

  return compactObject({
    sessionId: stringValue(log.sessionId, 120),
    date: stringValue(log.date, 80),
    source: stringValue(log.source, 80),
    perceivedEffort: numberValue(log.perceivedEffort),
    summary:
      postSessionNotes ||
      exerciseSummary ||
      stringValue(log.sessionId, 120) ||
      "Workout logged with no summary.",
  });
}

function messageForPrompt(message: DocumentData): CoachContextMessage {
  const content = stringValue(message.content, 1_500) ?? "";
  return compactObject({
    messageId: stringValue(message.messageId, 120),
    role: safeRole(message.role),
    content,
    status: stringValue(message.status, 80),
    timestamp: stringValue(message.timestamp, 80),
  });
}

function planChangeForPrompt(proposal: DocumentData): CoachContextPlanChange {
  const appliesTo = isPlainObject(proposal.appliesTo) ? proposal.appliesTo : {};
  return compactObject({
    proposalId: stringValue(proposal.proposalId, 120),
    category: stringValue(proposal.category, 80),
    dayKey: stringValue(appliesTo.dayKey, 20),
    scope: stringValue(appliesTo.scope, 20),
    summary: stringValue(proposal.summary, 300) ?? "",
    decidedAt: stringValue(proposal.decidedAt, 80),
  });
}

const MAX_PROGRESS_SERIES_POINTS = 8;
const MAX_PROGRESS_LIFTS = 5;
const MAX_PROGRESS_LENS_HIGHLIGHTS = 3;

// Field-picks the derived progress doc into the compact prompt shape. The
// doc is server-written and contract-validated at write time, but the
// mapping still guards every read: server sentinels (serverUpdatedAt) are
// dropped by the picking, and series are re-capped so a future contract
// widening can't silently blow the token budget.
function progressSummaryForPrompt(summary: DocumentData): CoachContextProgressSummary {
  const adherence = isPlainObject(summary.adherence) ? summary.adherence : {};
  const volume = isPlainObject(summary.volume) ? summary.volume : {};
  const body = isPlainObject(summary.body) ? summary.body : {};
  const lifts = Array.isArray(summary.lifts) ? summary.lifts : [];

  // Re-capped like every other section (≤3 entries, string caps mirroring
  // the ProgressLensHighlight contract) so a widened doc can't blow the
  // token budget. Entries missing metric or framing are dropped whole.
  const lensHighlights = (Array.isArray(summary.lensHighlights) ? summary.lensHighlights : [])
    .slice(0, MAX_PROGRESS_LENS_HIGHLIGHTS)
    .map((highlight) => {
      if (!isPlainObject(highlight)) return null;
      const metric = stringValue(highlight.metric, 40);
      const framing = stringValue(highlight.framing, 120);
      if (!metric || !framing) return null;
      return compactObject({
        metric,
        framing,
        note: stringValue(highlight.note, 200),
      });
    })
    .filter((highlight): highlight is NonNullable<typeof highlight> => highlight !== null);

  return compactObject({
    computedAt: stringValue(summary.computedAt, 80),
    windowDays: numberValue(summary.windowDays),
    adherence: compactObject({
      plannedSessions: numberValue(adherence.plannedSessions),
      completedSessions: numberValue(adherence.completedSessions),
      weeklyRate: numberArray(adherence.weeklyRate),
      streakWeeks: numberValue(adherence.streakWeeks),
    }),
    volume: compactObject({
      weeklyTotals: numberArray(volume.weeklyTotals),
      trend: stringValue(volume.trend, 20),
    }),
    lifts: lifts
      .slice(0, MAX_PROGRESS_LIFTS)
      .map((lift) => {
        if (!isPlainObject(lift)) return null;
        const exerciseName = stringValue(lift.exerciseName, 120);
        if (!exerciseName) return null;
        const series = Array.isArray(lift.e1rmSeries) ? lift.e1rmSeries : [];
        return compactObject({
          exerciseName,
          e1rmSeries: series
            .slice(-MAX_PROGRESS_SERIES_POINTS)
            .filter(isPlainObject)
            .map((point) =>
              compactObject({
                date: stringValue(point.date, 20),
                value: numberValue(point.value),
              }),
            ),
          trendPct: numberValue(lift.trendPct),
        });
      })
      .filter((lift): lift is NonNullable<typeof lift> => lift !== null),
    body: compactObject({
      weightSeries: (Array.isArray(body.weightSeries) ? body.weightSeries : [])
        .slice(-MAX_PROGRESS_SERIES_POINTS)
        .filter(isPlainObject)
        .map((point) =>
          compactObject({
            date: stringValue(point.date, 20),
            kg: numberValue(point.kg),
          }),
        ),
      rollingAvgKg: numberValue(body.rollingAvgKg),
      trendPctPerWeek: numberValue(body.trendPctPerWeek),
      goalDirection: stringValue(body.goalDirection, 20),
      withinSafeBand:
        typeof body.withinSafeBand === "boolean" ? body.withinSafeBand : undefined,
    }),
    // undefined (dropped by compactObject) when empty, so docs without
    // highlights keep their pre-slice-5 prompt bytes.
    lensHighlights: lensHighlights.length > 0 ? lensHighlights : undefined,
  }) as CoachContextProgressSummary;
}

function numberArray(value: unknown): number[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const numbers = value
    .map(numberValue)
    .filter((entry): entry is number => entry !== undefined);
  return numbers;
}

function safeRole(role: unknown): CoachContextMessage["role"] {
  return role === "user" ||
    role === "coach" ||
    role === "tool" ||
    role === "system"
    ? role
    : "unknown";
}

function compactObject<T extends Record<string, unknown>>(value: T): T {
  return Object.fromEntries(
    Object.entries(value).filter(([, entry]) => entry !== undefined && entry !== ""),
  ) as T;
}

function normalizeValue(value: unknown): unknown {
  if (typeof value === "string") {
    return stringValue(value, 1_000);
  }
  if (typeof value === "number" || typeof value === "boolean" || value === null) {
    return value;
  }
  if (Array.isArray(value)) {
    return value.slice(0, 50).map(normalizeValue);
  }
  if (isPlainObject(value)) {
    return Object.fromEntries(
      Object.entries(value)
        .slice(0, 50)
        .map(([key, entry]) => [key, normalizeValue(entry)]),
    );
  }
  return stringValue(value, 120);
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringValue(value: unknown, maxLength: number) {
  if (typeof value !== "string") {
    return undefined;
  }
  return value.length > maxLength ? `${value.slice(0, maxLength)}...` : value;
}

function numberValue(value: unknown) {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function hasText(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}
