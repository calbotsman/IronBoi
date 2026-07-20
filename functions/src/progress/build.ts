// MYO progress layer — pure builder (docs/plans/myo-progress-tracking-plan.md).
//
// buildProgressSummary is a pure function over plain data: no Firestore, no
// clock, no randomness — the writer (progress/store.ts) loads the inputs and
// this module derives the numbers, so all the math is unit-testable with
// fixture logs. Inputs are typed loosely (Record<string, unknown>) because
// they arrive as Firestore DocumentData that may carry server sentinels or
// legacy shapes; every read is guarded, and the assembled result is parsed
// through the strict ProgressSummary contract at the end — z.number()
// rejects NaN, so any division slip fails loudly instead of shipping NaN to
// the coach prompt.

import {
  ProgressSummary,
  type ProgressSummary as ProgressSummaryType,
  type TrendDirection,
} from "../contracts/coach-agent.js";

export const PROGRESS_WINDOW_DAYS = 42;
const WEEKS_IN_WINDOW = PROGRESS_WINDOW_DAYS / 7; // 6 full buckets, no partial week
const MAX_SERIES_POINTS = 8;
const MAX_LIFTS = 5;
// Volume halves must differ by more than ±5% to call a direction.
const VOLUME_TREND_THRESHOLD = 0.05;
// Safety: losing faster than 1% of body weight per week is a caution under
// EVERY goal (rapid-weight-loss coaching is already a blocked topic).
const MAX_SAFE_LOSS_PCT_PER_WEEK = 1.0;

type Loose = Record<string, unknown>;

export type ProgressBuildInputs = {
  // workoutLogs docs (WorkoutLog shape, tolerated loosely).
  logs: Loose[];
  // healthSamples docs (HealthSample shape) — the writer pre-filters to
  // category "body_weight_kg" and also synthesizes entries from manual
  // metricSnapshots so the builder sees one weight stream.
  healthSamples: Loose[];
  // trainingPrograms/current (TrainingProgram) — planned-days fallback.
  program: Loose | null;
  // workoutPlans/current (WorkoutPlan) — primary planned-days source.
  plan: Loose | null;
  // profile/current (UserHealthProfile) — goals decide body.goalDirection.
  profile: Loose | null;
  userId: string;
  // Full ISO datetime (or date) anchoring the window's newest day.
  todayISO: string;
};

export function buildProgressSummary(inputs: ProgressBuildInputs): ProgressSummaryType {
  const todayDay = epochDayOf(inputs.todayISO);
  if (todayDay === null) {
    throw new Error(`buildProgressSummary: unparseable todayISO "${inputs.todayISO}"`);
  }

  const logs = windowedLogs(inputs.logs, todayDay);
  const plannedPerWeek = plannedSessionsPerWeek(inputs.plan, inputs.program);

  const summary: ProgressSummaryType = {
    userId: inputs.userId,
    computedAt: toISODateTime(inputs.todayISO),
    windowDays: PROGRESS_WINDOW_DAYS,
    adherence: buildAdherence(logs, plannedPerWeek),
    volume: buildVolume(logs),
    lifts: buildLifts(logs),
    body: buildBody(inputs.healthSamples, inputs.profile, todayDay),
  };

  // Strict-parse backstop: catches NaN, negative counts, over-long series.
  return ProgressSummary.parse(summary);
}

// ---------------------------------------------------------------------------
// Window bucketing
// ---------------------------------------------------------------------------

type WindowedLog = {
  raw: Loose;
  date: string; // YYYY-MM-DD
  // Chronological bucket index 0..5; 5 = the 7 days ending today.
  weekIndex: number;
};

function windowedLogs(logs: Loose[], todayDay: number): WindowedLog[] {
  const result: WindowedLog[] = [];
  for (const raw of logs) {
    const date = dateStringOf(raw?.date);
    if (!date) continue;
    const day = epochDayOf(date);
    if (day === null) continue;
    const offset = todayDay - day;
    if (offset < 0 || offset >= PROGRESS_WINDOW_DAYS) continue;
    result.push({
      raw,
      date,
      weekIndex: WEEKS_IN_WINDOW - 1 - Math.floor(offset / 7),
    });
  }
  return result.sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
}

// ---------------------------------------------------------------------------
// Adherence
// ---------------------------------------------------------------------------

function plannedSessionsPerWeek(plan: Loose | null, program: Loose | null): number {
  const planDays = nonEmptyDayCount(plan?.days);
  if (planDays !== null) return planDays;

  // No flattened plan — fall back to the program's active week.
  const weeks = Array.isArray(program?.weeks) ? program.weeks : [];
  const activeIndex =
    typeof program?.activeWeekIndex === "number" && Number.isInteger(program.activeWeekIndex)
      ? program.activeWeekIndex
      : 0;
  const activeWeek = isRecord(weeks[activeIndex]) ? (weeks[activeIndex] as Loose) : null;
  return nonEmptyDayCount(activeWeek?.days) ?? 0;
}

// Counts days whose exercises array is non-empty. Returns null (not 0) when
// the days map itself is absent, so the caller can distinguish "no plan doc"
// from "a plan of pure rest days".
function nonEmptyDayCount(days: unknown): number | null {
  if (!isRecord(days)) return null;
  let count = 0;
  for (const day of Object.values(days)) {
    if (isRecord(day) && Array.isArray(day.exercises) && day.exercises.length > 0) {
      count += 1;
    }
  }
  return count;
}

function buildAdherence(logs: WindowedLog[], plannedPerWeek: number) {
  const perWeek = new Array<number>(WEEKS_IN_WINDOW).fill(0);
  for (const log of logs) {
    perWeek[log.weekIndex] += 1;
  }

  const weeklyRate = perWeek.map((completed) =>
    plannedPerWeek > 0 ? round2(Math.min(1, completed / plannedPerWeek)) : 0,
  );

  let streakWeeks = 0;
  if (plannedPerWeek > 0) {
    for (let index = WEEKS_IN_WINDOW - 1; index >= 0; index -= 1) {
      if (perWeek[index] >= plannedPerWeek) streakWeeks += 1;
      else break;
    }
  }

  return {
    plannedSessions: plannedPerWeek * WEEKS_IN_WINDOW,
    completedSessions: logs.length,
    weeklyRate,
    streakWeeks,
  };
}

// ---------------------------------------------------------------------------
// Volume
// ---------------------------------------------------------------------------

function buildVolume(logs: WindowedLog[]) {
  const weeklyTotals = new Array<number>(WEEKS_IN_WINDOW).fill(0);
  for (const log of logs) {
    weeklyTotals[log.weekIndex] += logVolumeKg(log.raw);
  }
  return {
    weeklyTotals: weeklyTotals.map(round1),
    trend: halvesTrend(weeklyTotals),
  };
}

// Σ reps × loadKg across every set in the log. Each entry in an exercise's
// sets array is one performed set; sets without both reps and loadKg
// (duration-only, bodyweight) contribute 0.
function logVolumeKg(log: Loose): number {
  const exercises = Array.isArray(log.exercises) ? log.exercises : [];
  let total = 0;
  for (const exercise of exercises) {
    if (!isRecord(exercise) || !Array.isArray(exercise.sets)) continue;
    for (const set of exercise.sets) {
      if (!isRecord(set)) continue;
      const reps = finiteNumber(set.reps);
      const loadKg = finiteNumber(set.loadKg);
      if (reps === null || loadKg === null || reps <= 0 || loadKg <= 0) continue;
      total += reps * loadKg;
    }
  }
  return total;
}

// Compare the window's first half against its second half. Deterministic and
// robust to a single spiky week; both-zero halves read flat, training that
// starts mid-window reads up.
function halvesTrend(weeklyTotals: number[]): TrendDirection {
  const half = Math.floor(weeklyTotals.length / 2);
  const firstAvg = average(weeklyTotals.slice(0, half));
  const secondAvg = average(weeklyTotals.slice(half));
  if (firstAvg === 0 && secondAvg === 0) return "flat";
  if (firstAvg === 0) return "up";
  const change = (secondAvg - firstAvg) / firstAvg;
  if (change > VOLUME_TREND_THRESHOLD) return "up";
  if (change < -VOLUME_TREND_THRESHOLD) return "down";
  return "flat";
}

// ---------------------------------------------------------------------------
// Lifts (e1RM via Epley)
// ---------------------------------------------------------------------------

function buildLifts(logs: WindowedLog[]) {
  // normalized name → { displayName, points: date → best e1RM that date }
  const byExercise = new Map<
    string,
    { displayName: string; sessions: number; byDate: Map<string, number> }
  >();

  for (const log of logs) {
    const exercises = Array.isArray(log.raw.exercises) ? log.raw.exercises : [];
    for (const exercise of exercises) {
      if (!isRecord(exercise) || typeof exercise.name !== "string") continue;
      const displayName = exercise.name.trim();
      if (!displayName) continue;
      const best = bestSetE1rm(exercise.sets);
      if (best === null) continue;

      const key = displayName.toLowerCase();
      const entry =
        byExercise.get(key) ??
        { displayName, sessions: 0, byDate: new Map<string, number>() };
      entry.sessions += 1;
      const existing = entry.byDate.get(log.date);
      // Two sessions on the same date keep the higher e1RM for that point.
      entry.byDate.set(log.date, existing === undefined ? best : Math.max(existing, best));
      byExercise.set(key, entry);
    }
  }

  return [...byExercise.values()]
    .sort(
      (a, b) =>
        b.sessions - a.sessions ||
        a.displayName.localeCompare(b.displayName),
    )
    .slice(0, MAX_LIFTS)
    .map((entry) => {
      const series = [...entry.byDate.entries()]
        .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
        .map(([date, value]) => ({ date, value }));
      // Trend over the FULL window, then cap the stored series to the most
      // recent 8 sessions (recent strength is what the coach references).
      const first = series[0]?.value;
      const last = series[series.length - 1]?.value;
      const trendPct =
        series.length >= 2 && first !== undefined && last !== undefined && first > 0
          ? round1(((last - first) / first) * 100)
          : 0;
      return {
        exerciseName: entry.displayName,
        e1rmSeries: series
          .slice(-MAX_SERIES_POINTS)
          .map((point) => ({ date: point.date, value: round1(point.value) })),
        trendPct,
      };
    });
}

// Epley: loadKg × (1 + reps/30) over the session's best set. Bodyweight sets
// (no positive loadKg) are excluded — reps-at-bodyweight progression is a
// separate metric per the plan, not a 0 kg e1RM.
function bestSetE1rm(sets: unknown): number | null {
  if (!Array.isArray(sets)) return null;
  let best: number | null = null;
  for (const set of sets) {
    if (!isRecord(set)) continue;
    const reps = finiteNumber(set.reps);
    const loadKg = finiteNumber(set.loadKg);
    if (reps === null || loadKg === null || reps < 1 || loadKg <= 0) continue;
    const e1rm = loadKg * (1 + reps / 30);
    if (best === null || e1rm > best) best = e1rm;
  }
  return best;
}

// ---------------------------------------------------------------------------
// Body weight
// ---------------------------------------------------------------------------

function buildBody(healthSamples: Loose[], profile: Loose | null, todayDay: number) {
  const daily = dailyWeightPoints(healthSamples, todayDay);
  const goalDirection = goalDirectionOf(profile);

  const trendPctPerWeek = weeklyTrendPct(daily);
  return {
    weightSeries: downsampleEvenly(daily, MAX_SERIES_POINTS).map((point) => ({
      date: point.date,
      kg: round2(point.kg),
    })),
    ...(daily.length > 0
      ? { rollingAvgKg: round2(rollingAverageKg(daily, todayDay)) }
      : {}),
    ...(trendPctPerWeek !== null ? { trendPctPerWeek: round2(trendPctPerWeek) } : {}),
    goalDirection,
    withinSafeBand: classifyWithinSafeBand(trendPctPerWeek, goalDirection),
  };
}

type DailyWeightPoint = { date: string; day: number; kg: number };

function dailyWeightPoints(healthSamples: Loose[], todayDay: number): DailyWeightPoint[] {
  const byDate = new Map<string, { sum: number; count: number; day: number }>();
  for (const sample of healthSamples) {
    if (!isRecord(sample) || sample.category !== "body_weight_kg") continue;
    const kg = finiteNumber(sample.value);
    if (kg === null || kg <= 0) continue;
    const date = dateStringOf(sample.startDate);
    if (!date) continue;
    const day = epochDayOf(date);
    if (day === null) continue;
    const offset = todayDay - day;
    if (offset < 0 || offset >= PROGRESS_WINDOW_DAYS) continue;
    const entry = byDate.get(date) ?? { sum: 0, count: 0, day };
    entry.sum += kg;
    entry.count += 1;
    byDate.set(date, entry);
  }
  return [...byDate.entries()]
    .map(([date, { sum, count, day }]) => ({ date, day, kg: sum / count }))
    .sort((a, b) => a.day - b.day);
}

// Mean of the trailing 7 calendar days' points; when the newest data is
// older than a week, fall back to the most recent point so the field still
// reflects the latest known weight instead of vanishing.
function rollingAverageKg(daily: DailyWeightPoint[], todayDay: number): number {
  const recent = daily.filter((point) => todayDay - point.day < 7);
  if (recent.length > 0) return average(recent.map((point) => point.kg));
  return daily[daily.length - 1].kg;
}

// Least-squares slope over (epochDay, kg), expressed as percent of mean body
// weight per week. Null with <2 points or zero day-spread.
function weeklyTrendPct(daily: DailyWeightPoint[]): number | null {
  if (daily.length < 2) return null;
  const n = daily.length;
  const meanDay = average(daily.map((point) => point.day));
  const meanKg = average(daily.map((point) => point.kg));
  if (meanKg <= 0) return null;
  let numerator = 0;
  let denominator = 0;
  for (const point of daily) {
    numerator += (point.day - meanDay) * (point.kg - meanKg);
    denominator += (point.day - meanDay) ** 2;
  }
  if (denominator === 0 || n < 2) return null;
  const slopeKgPerDay = numerator / denominator;
  return ((slopeKgPerDay * 7) / meanKg) * 100;
}

// profile.goals per the plan's goal table: the FIRST goal in the array that
// implies a weight direction wins (fat_loss → down, muscle_gain → up);
// everything else — strength, general_fitness, mobility, endurance,
// habit_building, return_to_training — reads flat (body weight is not their
// headline metric).
function goalDirectionOf(profile: Loose | null): "down" | "up" | "flat" {
  const goals = Array.isArray(profile?.goals) ? profile.goals : [];
  for (const goal of goals) {
    if (goal === "fat_loss") return "down";
    if (goal === "muscle_gain") return "up";
  }
  return "flat";
}

// PURE SAFETY semantics (operator decision 2026-07-17): withinSafeBand is
// false ONLY when weight is being lost faster than 1%/wk — the one rate
// that's a caution under every goal. A fat-loss plateau is off-target, not
// unsafe; consumers that care about "on track" derive it from
// trendPctPerWeek + goalDirection instead of overloading this boolean.
function classifyWithinSafeBand(
  trendPctPerWeek: number | null,
  _goalDirection: "down" | "up" | "flat",
): boolean {
  if (trendPctPerWeek === null) return true;
  return trendPctPerWeek >= -MAX_SAFE_LOSS_PCT_PER_WEEK;
}

// Even-index downsampling that preserves both endpoints, so the capped
// series keeps the window-wide shape instead of only its tail.
function downsampleEvenly<T>(points: T[], max: number): T[] {
  if (points.length <= max) return points;
  const result: T[] = [];
  for (let index = 0; index < max; index += 1) {
    result.push(points[Math.round((index * (points.length - 1)) / (max - 1))]);
  }
  return result;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function isRecord(value: unknown): value is Loose {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function finiteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

// Accepts "YYYY-MM-DD" or a full ISO datetime; returns the date part.
function dateStringOf(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const date = value.slice(0, 10);
  return /^\d{4}-\d{2}-\d{2}$/.test(date) ? date : null;
}

function epochDayOf(value: string): number | null {
  const date = dateStringOf(value);
  if (!date) return null;
  const ms = Date.parse(`${date}T00:00:00.000Z`);
  return Number.isFinite(ms) ? Math.floor(ms / 86_400_000) : null;
}

function toISODateTime(value: string): string {
  const ms = Date.parse(value);
  if (Number.isFinite(ms)) return new Date(ms).toISOString();
  // Date-only inputs parse above; anything else is a programmer error.
  throw new Error(`buildProgressSummary: unparseable timestamp "${value}"`);
}

function average(values: number[]): number {
  return values.length === 0
    ? 0
    : values.reduce((sum, value) => sum + value, 0) / values.length;
}

function round1(value: number): number {
  return Math.round(value * 10) / 10;
}

function round2(value: number): number {
  return Math.round(value * 100) / 100;
}
