// Training history — pure builder (docs/plans/myo-training-intelligence.md S3).
//
// Same posture as progress/build.ts: no Firestore, no clock. The store
// (progress/trainingHistoryStore.ts) loads workout logs, the plan, the
// program, anchors, progression events and the profile; this module turns
// them into the one small doc History and the workout brain read
// (derivedSummaries/training_history): the weeks-on-plan streak, a 9-week
// calendar, this week's missed sessions, lift timelines and records.
// Inputs are loose (Firestore DocumentData) and every read is guarded; the
// result is parsed through the strict TrainingHistory contract at the end.
//
// Units: the app speaks pounds. Logs store kg per set; everything here is
// converted once (2.20462) and rounded to the nearest 0.5 lb.

import {
  PersonalRecord as PersonalRecordSchema,
  ProgressionEventKind,
  TrainingHistory,
  TrainingRecap,
  type PersonalRecord,
  type TrainingHistory as TrainingHistoryType,
  type TrainingRecap as TrainingRecapType,
} from "../contracts/coach-agent.js";
import { canonicalMuscle, isTimedExercise, lookupExercise, normalizeExerciseKey } from "../workouts/exerciseCatalog.js";
import { resolvePrescribedWeight, roundToPlate, type BaselineMap } from "../workouts/exerciseBaselines.js";
import { weekIndexForDate } from "../workouts/program.js";

type Loose = Record<string, unknown>;

export const KG_TO_LB = 2.20462;
const DAY_KEYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] as const;
type DayKey = (typeof DAY_KEYS)[number];
// The last 8 full weeks plus this one.
const CALENDAR_WEEKS = 9;
// How far back the streak (and the best streak) looks; the store reads
// about a year of logs to match.
export const HISTORY_WEEKS = 53;
const MAX_LIFTS = 12;
const MAX_LIFT_EVENTS = 20;
const MAX_SERIES = 12;
const MAX_RECENT_RECORDS = 10;
const MAX_MUSCLES = 12;
const MAX_RECENT_MUSCLES = 20;
// A logged kg converts back with rounding noise; an e1RM has to beat the
// old best by more than that to count.
const E1RM_SLACK_LB = 0.5;

export type TrainingHistoryInputs = {
  userId: string;
  // The user's local date (YYYY-MM-DD).
  today: string;
  // ISO datetime stamped on the doc.
  now: string;
  logs: Loose[];
  plan: Loose | null;
  program: Loose | null;
  baselines: BaselineMap;
  events: Loose[];
  profile: Loose | null;
};

// ---------------------------------------------------------------------------
// Sessions (normalized logs)
// ---------------------------------------------------------------------------

type LoadedSet = { lb: number; reps: number };

type SessionExercise = { key: string; name: string; sets: LoadedSet[] };

export type Session = {
  sessionId?: string;
  date: string;
  createdAt: string;
  // The plan day it was started from ("Thu"), when known: lets a missed
  // Thursday done on Saturday count as made up.
  dayKey?: DayKey;
  name?: string;
  effort?: number;
  volumeLb: number;
  // Lifts with real loaded sets (reps and load > 0), timed work excluded.
  lifts: SessionExercise[];
  // Muscles of every exercise with at least one set, canonical names.
  muscles: string[];
};

export function normalizeSessions(logs: Loose[]): Session[] {
  const sessions: Session[] = [];
  for (const log of logs) {
    if (!isRecord(log)) continue;
    // localDate is the user's own calendar day (server-written from the
    // app's clientDate); date is the UTC day of completion and lands an
    // evening workout on tomorrow for anyone west of Greenwich.
    const date = dateOf(log.localDate) ?? dateOf(log.date);
    if (!date) continue;
    const titled = titleOf(log);
    const lifts: SessionExercise[] = [];
    const muscles = new Set<string>();
    let volumeLb = 0;
    for (const exercise of Array.isArray(log.exercises) ? log.exercises : []) {
      if (!isRecord(exercise) || typeof exercise.name !== "string" || !exercise.name.trim()) continue;
      const name = exercise.name.trim();
      const sets = Array.isArray(exercise.sets) ? exercise.sets.filter(isRecord) : [];
      if (sets.length > 0) for (const muscle of musclesOf(name)) muscles.add(muscle);
      if (isTimedExercise(name)) continue;
      const loaded: LoadedSet[] = [];
      for (const set of sets) {
        const reps = finite(set.reps);
        const kg = finite(set.loadKg);
        if (reps === null || kg === null || reps <= 0 || kg <= 0) continue;
        const lb = toLb(kg);
        // A misheard "2,000 lb" or a typo would become a record or startLb
        // past the contract's bounds, and the strict parse would then fail
        // every rebuild for a year: History frozen. Skip impossible sets.
        if (lb > 2000 || reps > 500) continue;
        loaded.push({ lb, reps: Math.round(reps) });
        volumeLb += reps * kg * KG_TO_LB;
      }
      if (loaded.length === 0) continue;
      const key = normalizeExerciseKey(name);
      const existing = lifts.find((lift) => lift.key === key);
      if (existing) existing.sets.push(...loaded);
      else lifts.push({ key, name, sets: loaded });
    }
    const effort = finite(log.perceivedEffort);
    sessions.push({
      ...(typeof log.sessionId === "string" && log.sessionId ? { sessionId: log.sessionId } : {}),
      date,
      createdAt: typeof log.createdAt === "string" ? log.createdAt : `${date}T00:00:00.000Z`,
      ...titled,
      ...(effort !== null && effort >= 1 && effort <= 10 ? { effort } : {}),
      volumeLb,
      lifts,
      muscles: [...muscles],
    });
  }
  return sessions.sort((a, b) => cmp(a.date, b.date) || cmp(a.createdAt, b.createdAt));
}

// The server writes dayKey/workoutName on every log it finishes. Older logs
// carry them only in the default note "Thu: Upper Pull"; a note the user
// wrote themselves isn't a title.
function titleOf(log: Loose): { dayKey?: DayKey; name?: string } {
  const dayKey = asDayKey(log.dayKey);
  const name = typeof log.workoutName === "string" && log.workoutName.trim() ? log.workoutName.trim().slice(0, 80) : undefined;
  if (name) return { ...(dayKey ? { dayKey } : {}), name };
  const note = typeof log.postSessionNotes === "string" ? log.postSessionNotes : "";
  const match = /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun|Workout): (.{1,80})$/.exec(note.trim());
  if (!match) return dayKey ? { dayKey } : {};
  const parsedKey = asDayKey(match[1]) ?? dayKey;
  return { ...(parsedKey ? { dayKey: parsedKey } : {}), name: match[2].trim() };
}

function musclesOf(exerciseName: string): string[] {
  const entry = lookupExercise(exerciseName);
  return entry ? entry.primary.map(canonicalMuscle) : [];
}

// ---------------------------------------------------------------------------
// What was planned on a date
// ---------------------------------------------------------------------------

type PlannedDay = { name: string; muscles: string[] };

function plannedDayResolver(plan: Loose | null, program: Loose | null, today: string) {
  const thisWeekStart = weekStartOf(today);
  const planDays = isRecord(plan?.days) ? plan.days : null;
  const overrides = isRecord(plan?.dailyOverrides) ? plan.dailyOverrides : {};
  const startDate = dateOf(program?.startDate);
  const weeks = Array.isArray(program?.weeks) ? program.weeks.filter(isRecord) : [];

  return (date: string): PlannedDay | null => {
    const dayKey = dayKeyOf(date);
    let day: unknown;
    if (isRecord(overrides[date])) {
      day = overrides[date];
    } else if (date < thisWeekStart && startDate && date >= startDate && weeks.length > 0) {
      // Past weeks: what the program said then (rollover never rewrites
      // past weeks). This week and on: what the Train tab shows now.
      const index = weekIndexForDate(startDate, date);
      const week = weeks.find((entry) => entry.weekIndex === index) ?? weeks[weeks.length - 1];
      day = isRecord(week.days) ? week.days[dayKey] : undefined;
    } else {
      day = planDays?.[dayKey];
    }
    if (!isRecord(day)) return null;
    const exercises = Array.isArray(day.exercises) ? day.exercises.filter(isRecord) : [];
    const runs = Array.isArray(day.runs) ? day.runs : [];
    if (exercises.length === 0 && runs.length === 0) return null;
    const muscles = new Set<string>();
    for (const exercise of exercises) {
      if (typeof exercise.name === "string") for (const muscle of musclesOf(exercise.name)) muscles.add(muscle);
    }
    // No catalog match at all: fall back to the day's own labels.
    if (muscles.size === 0 && Array.isArray(day.muscles)) {
      for (const muscle of day.muscles) if (typeof muscle === "string" && muscle.trim()) muscles.add(canonicalMuscle(muscle));
    }
    const name = typeof day.name === "string" && day.name.trim() ? day.name.trim().slice(0, 80) : "Workout";
    return { name, muscles: [...muscles].map((muscle) => muscle.slice(0, 40)).slice(0, MAX_MUSCLES) };
  };
}

// ---------------------------------------------------------------------------
// Weeks, streak, calendar
// ---------------------------------------------------------------------------

type DayCell = {
  date: string;
  dayKey: DayKey;
  planned: PlannedDay | null;
  sessions: Session[];
  // A session from later in the week that did this day's planned session.
  madeUpBy?: Session;
};

type Week = { start: string; days: DayCell[]; planned: number; done: number };

function buildWeek(start: string, plannedOn: (date: string) => PlannedDay | null, byDate: Map<string, Session[]>, firstDay: string): Week {
  const days: DayCell[] = DAY_KEYS.map((dayKey, offset) => {
    const date = addDays(start, offset);
    return {
      date,
      dayKey,
      // Nothing was planned before the user was on MYO.
      planned: date >= firstDay ? plannedOn(date) : null,
      sessions: byDate.get(date) ?? [],
    };
  });
  // Make-ups: a session started from Thursday's plan day but done on
  // Saturday does Thursday's session. Each planned day's own first session
  // claims it; any other session in the week may make up the day it came
  // from, once.
  const claimed = new Set<string>();
  const spare: Session[] = [];
  for (const cell of days) {
    cell.sessions.forEach((session, index) => {
      if (cell.planned && index === 0) claimed.add(cell.date);
      else spare.push(session);
    });
  }
  for (const session of spare) {
    if (!session.dayKey || session.dayKey === dayKeyOf(session.date)) continue;
    const target = days.find((cell) => cell.dayKey === session.dayKey);
    if (!target || !target.planned || claimed.has(target.date) || target.madeUpBy) continue;
    target.madeUpBy = session;
  }
  return {
    start,
    days,
    planned: days.filter((cell) => cell.planned).length,
    done: days.reduce((sum, cell) => sum + cell.sessions.length, 0),
  };
}

function weekMet(week: Week): boolean {
  return week.planned > 0 && week.done >= week.planned;
}

type Streak = TrainingHistoryType["streak"];

// Decision 2: calendar weeks, Monday to Sunday; a week counts when the
// sessions logged in it reach the week's planned training days. A week with
// nothing planned (before the user started, or a plan of rest) neither
// counts nor breaks. The current week only adds once it's met.
export function streakOf(weeks: Week[]): Streak {
  const current = weeks[weeks.length - 1];
  const past = weeks.slice(0, -1);
  const thisWeekMet = current ? weekMet(current) : false;
  let run = 0;
  for (let index = past.length - 1; index >= 0; index -= 1) {
    const week = past[index];
    if (week.planned === 0) continue;
    if (!weekMet(week)) break;
    run += 1;
  }
  const currentWeeks = run + (thisWeekMet ? 1 : 0);
  let best = 0;
  let streak = 0;
  for (const week of past) {
    if (week.planned === 0) continue;
    streak = weekMet(week) ? streak + 1 : 0;
    best = Math.max(best, streak);
  }
  return { currentWeeks, bestWeeks: Math.max(best, currentWeeks), thisWeekMet };
}

type CalendarEntry = TrainingHistoryType["calendar"][number];

function calendarEntry(cell: DayCell, today: string): CalendarEntry {
  const base = { date: cell.date, dayKey: cell.dayKey };
  const logged = cell.sessions[0];
  if (logged) {
    return compact({
      ...base,
      status: cell.planned ? "done" : "extra",
      name: logged.name ?? cell.planned?.name ?? "Workout",
      sessionId: logged.sessionId,
    }) as CalendarEntry;
  }
  if (cell.madeUpBy) {
    return compact({
      ...base,
      status: "done",
      name: cell.madeUpBy.name ?? cell.planned?.name,
      sessionId: cell.madeUpBy.sessionId,
    }) as CalendarEntry;
  }
  if (!cell.planned) return { ...base, status: "rest" };
  const status = cell.date < today ? "missed" : cell.date === today ? "today" : "planned";
  return { ...base, status, name: cell.planned.name };
}

// ---------------------------------------------------------------------------
// Lifts and records
// ---------------------------------------------------------------------------

type LiftStats = {
  key: string;
  name: string;
  firstDate: string;
  lastDate: string;
  startLb: number;
  lastLb: number;
  sessions: number;
  series: Map<string, number>;
  records: PersonalRecord[];
  standing: PersonalRecord[];
};

/** Every lift's sessions, records and standing bests, from oldest to newest. */
export function liftStats(sessions: Session[]): Map<string, LiftStats> {
  const stats = new Map<string, LiftStats>();
  const state = new Map<string, {
    topLb: number; topReps: number; topDate: string; topSession?: string;
    e1rm: number; e1Set: LoadedSet; e1Date: string; e1Session?: string;
    repsAt: Map<number, number>;
  }>();

  for (const session of sessions) {
    for (const lift of session.lifts) {
      const top = lift.sets.reduce((best, set) => (set.lb > best.lb || (set.lb === best.lb && set.reps > best.reps) ? set : best));
      const e1Set = lift.sets.reduce((best, set) => (epley(set) > epley(best) ? set : best));
      const entry = stats.get(lift.key) ?? {
        key: lift.key, name: lift.name, firstDate: session.date, lastDate: session.date,
        startLb: workingWeight(lift.sets), lastLb: 0, sessions: 0, series: new Map<string, number>(), records: [], standing: [],
      };
      entry.name = lift.name;
      entry.lastDate = session.date;
      entry.lastLb = workingWeight(lift.sets);
      entry.sessions += 1;
      entry.series.set(session.date, Math.max(entry.series.get(session.date) ?? 0, round1(epley(e1Set))));
      stats.set(lift.key, entry);

      const before = state.get(lift.key);
      const record = (kind: PersonalRecord["kind"], set: LoadedSet, e1rm?: number): PersonalRecord => compact({
        exerciseName: lift.name.slice(0, 80), kind, weightLb: set.lb, reps: set.reps,
        e1rmLb: e1rm !== undefined ? round1(e1rm) : undefined, date: session.date, sessionId: session.sessionId,
      }) as PersonalRecord;
      // A record is set by the session that first beats the previous best,
      // so the very first time a lift is logged sets none.
      if (before) {
        const candidates: PersonalRecord[] = [];
        if (top.lb > before.topLb) candidates.push(record("heaviest", top));
        const moreReps = lift.sets
          .filter((set) => before.repsAt.has(set.lb) && set.reps > (before.repsAt.get(set.lb) ?? 0))
          .sort((a, b) => b.lb - a.lb || b.reps - a.reps)[0];
        if (moreReps) candidates.push(record("most_reps", moreReps));
        if (epley(e1Set) > before.e1rm + E1RM_SLACK_LB) candidates.push(record("best_e1rm", e1Set, epley(e1Set)));
        // One per lift per session, the plainest first: "heaviest ever"
        // over "more reps" over the estimate.
        if (candidates[0]) entry.records.push(candidates[0]);
      }

      const next = before ?? {
        topLb: 0, topReps: 0, topDate: session.date, topSession: session.sessionId,
        e1rm: 0, e1Set, e1Date: session.date, e1Session: session.sessionId, repsAt: new Map<number, number>(),
      };
      if (top.lb > next.topLb || (top.lb === next.topLb && top.reps > next.topReps)) {
        Object.assign(next, { topLb: top.lb, topReps: top.reps, topDate: session.date, topSession: session.sessionId });
      }
      if (epley(e1Set) > next.e1rm) {
        Object.assign(next, { e1rm: epley(e1Set), e1Set, e1Date: session.date, e1Session: session.sessionId });
      }
      for (const set of lift.sets) next.repsAt.set(set.lb, Math.max(next.repsAt.get(set.lb) ?? 0, set.reps));
      state.set(lift.key, next);
    }
  }

  for (const [key, entry] of stats) {
    const best = state.get(key)!;
    const latestMostReps = [...entry.records].reverse().find((record) => record.kind === "most_reps");
    entry.standing = [
      compact({ exerciseName: entry.name.slice(0, 80), kind: "heaviest", weightLb: best.topLb, reps: best.topReps, date: best.topDate, sessionId: best.topSession }) as PersonalRecord,
      compact({ exerciseName: entry.name.slice(0, 80), kind: "best_e1rm", weightLb: best.e1Set.lb, reps: best.e1Set.reps, e1rmLb: round1(best.e1rm), date: best.e1Date, sessionId: best.e1Session }) as PersonalRecord,
      ...(latestMostReps ? [latestMostReps] : []),
    ];
  }
  return stats;
}

/** Records set by one session, across every lift. */
export function recordsForSession(sessions: Session[], sessionId: string): PersonalRecord[] {
  return [...liftStats(sessions).values()].flatMap((lift) => lift.records.filter((record) => record.sessionId === sessionId));
}

// Epley over one set, in pounds.
function epley(set: LoadedSet): number {
  return set.lb * (1 + set.reps / 30);
}

// The weight most sets were done at; ties go heavy (the same rule as
// exerciseBaselines.ts workedWeight).
function workingWeight(sets: LoadedSet[]): number {
  const counts = new Map<number, number>();
  for (const set of sets) counts.set(set.lb, (counts.get(set.lb) ?? 0) + 1);
  let best = sets[0]?.lb ?? 0;
  let bestCount = 0;
  for (const [lb, count] of counts) {
    if (count > bestCount || (count === bestCount && lb > best)) {
      best = lb;
      bestCount = count;
    }
  }
  return best;
}

type LiftEvent = TrainingHistoryType["lifts"][number]["events"][number];

function eventsByLift(events: Loose[]): Map<string, Array<LiftEvent & { createdAt: string }>> {
  const byKey = new Map<string, Array<LiftEvent & { createdAt: string }>>();
  for (const event of events) {
    if (!isRecord(event) || typeof event.exerciseKey !== "string") continue;
    const kind = ProgressionEventKind.safeParse(event.kind);
    const date = dateOf(event.date);
    const fromLb = finite(event.fromLb);
    const toLb = finite(event.toLb);
    if (!kind.success || !date || fromLb === null || toLb === null) continue;
    const list = byKey.get(event.exerciseKey) ?? [];
    list.push({
      date,
      kind: kind.data,
      fromLb: clampLb(fromLb),
      toLb: clampLb(toLb),
      reason: typeof event.reason === "string" ? event.reason.slice(0, 160) : "",
      createdAt: typeof event.createdAt === "string" ? event.createdAt : "",
    });
    byKey.set(event.exerciseKey, list);
  }
  // Same day, same instant (a heavier-than-prescribed session writes both
  // changed_in_workout and session_up): the step leads, so the intro's "up 5
  // from last time" finds it first.
  const stepFirst = (kind: string) => (kind === "session_up" || kind === "weekly_up" || kind === "deload" ? 0 : 1);
  for (const list of byKey.values()) {
    list.sort((a, b) => cmp(b.date, a.date) || cmp(b.createdAt, a.createdAt) || stepFirst(a.kind) - stepFirst(b.kind));
  }
  return byKey;
}

// What the plan prescribes now for a lift: its anchor + progression where it
// has one, else the plan's own number, else what was last lifted.
function currentWeight(key: string, lastLb: number, plan: Loose | null, baselines: BaselineMap, today: string): number {
  const planDays = isRecord(plan?.days) ? Object.values(plan.days) : [];
  for (const day of planDays) {
    const exercises = isRecord(day) && Array.isArray(day.exercises) ? day.exercises.filter(isRecord) : [];
    const match = exercises.find((exercise) => typeof exercise.name === "string" && normalizeExerciseKey(exercise.name) === key);
    if (match && typeof match.weight === "number") {
      const prescribed = resolvePrescribedWeight(
        { name: match.name as string, weight: match.weight, progression: isRecord(match.progression) ? (match.progression as never) : undefined },
        baselines,
        today,
      );
      if (prescribed > 0) return clampLb(prescribed);
    }
  }
  const anchor = baselines.get(key);
  if (anchor && anchor.anchorWeightLb > 0) return clampLb(roundToPlate(anchor.anchorWeightLb));
  return clampLb(lastLb);
}

// ---------------------------------------------------------------------------
// The builder
// ---------------------------------------------------------------------------

export function buildTrainingHistory(inputs: TrainingHistoryInputs): TrainingHistoryType {
  const today = dateOf(inputs.today);
  if (!today) throw new Error(`buildTrainingHistory: unparseable today "${inputs.today}"`);
  const sessions = normalizeSessions(inputs.logs).filter((session) => session.date <= today);
  const plannedOn = plannedDayResolver(inputs.plan, inputs.program, today);

  // The user's first day on MYO: profile creation or the first log,
  // whichever is earlier. Days before it plan nothing.
  const starts = [dateOf(inputs.profile?.createdAt), sessions[0]?.date].filter((date): date is string => Boolean(date));
  const firstDay = starts.length > 0 ? starts.sort()[0] : today;

  const byDate = new Map<string, Session[]>();
  for (const session of sessions) byDate.set(session.date, [...(byDate.get(session.date) ?? []), session]);

  const thisWeekStart = weekStartOf(today);
  const firstWeekStart = weekStartOf(firstDay);
  const weeks: Week[] = [];
  for (let back = HISTORY_WEEKS - 1; back >= 0; back -= 1) {
    const start = addDays(thisWeekStart, -7 * back);
    // Weeks before the user started stay in for the calendar window only.
    if (start < firstWeekStart && back >= CALENDAR_WEEKS) continue;
    weeks.push(buildWeek(start, plannedOn, byDate, firstDay));
  }
  const current = weeks[weeks.length - 1];

  const calendar = weeks.slice(-CALENDAR_WEEKS).flatMap((week) => week.days.map((cell) => calendarEntry(cell, today)));

  const missedThisWeek = current.days
    .filter((cell) => cell.planned && cell.date < today && cell.sessions.length === 0 && !cell.madeUpBy)
    .reverse()
    .map((cell) => ({ date: cell.date, dayKey: cell.dayKey, name: cell.planned!.name, muscles: cell.planned!.muscles }));

  const yesterday = addDays(today, -1);
  const recentMuscles = [...new Set(
    sessions.filter((session) => session.date === today || session.date === yesterday).flatMap((session) => session.muscles),
  )].map((muscle) => muscle.slice(0, 40)).slice(0, MAX_RECENT_MUSCLES);

  const weekSessions = sessions.filter((session) => session.date >= thisWeekStart && session.date <= addDays(thisWeekStart, 6));
  const efforts = weekSessions.map((session) => session.effort).filter((effort): effort is number => effort !== undefined);
  const thisWeek = compact({
    weekStart: thisWeekStart,
    planned: current.planned,
    done: current.done,
    volumeLb: Math.round(weekSessions.reduce((sum, session) => sum + session.volumeLb, 0)),
    avgEffort: efforts.length > 0 ? round1(efforts.reduce((a, b) => a + b, 0) / efforts.length) : undefined,
  }) as TrainingHistoryType["thisWeek"];

  const stats = liftStats(sessions);
  const events = eventsByLift(inputs.events);
  const lifts = [...stats.values()]
    .sort((a, b) => cmp(b.lastDate, a.lastDate) || b.sessions - a.sessions || a.name.localeCompare(b.name))
    .slice(0, MAX_LIFTS)
    .map((lift) => ({
      exerciseKey: lift.key.slice(0, 120),
      exerciseName: lift.name.slice(0, 80),
      currentLb: currentWeight(lift.key, lift.lastLb, inputs.plan, inputs.baselines, today),
      startLb: lift.startLb,
      firstDate: lift.firstDate,
      lastDate: lift.lastDate,
      sessions: lift.sessions,
      events: (events.get(lift.key) ?? []).slice(0, MAX_LIFT_EVENTS).map(({ createdAt: _createdAt, ...event }) => event),
      e1rmSeries: [...lift.series.entries()]
        .sort(([a], [b]) => cmp(a, b))
        .slice(-MAX_SERIES)
        .map(([date, value]) => ({ date, value })),
      prs: lift.standing.slice(0, 3),
    }));

  const recentRecords = [...stats.values()]
    .flatMap((lift) => lift.records)
    .sort((a, b) => cmp(b.date, a.date) || b.weightLb - a.weightLb)
    .slice(0, MAX_RECENT_RECORDS);

  return TrainingHistory.parse({
    userId: inputs.userId,
    computedAt: new Date(Date.parse(inputs.now)).toISOString(),
    today,
    streak: streakOf(weeks),
    thisWeek,
    calendar,
    missedThisWeek,
    recentMuscles,
    lifts,
    recentRecords,
  });
}

// ---------------------------------------------------------------------------
// The finish-screen recap (S4)
// ---------------------------------------------------------------------------

/**
 * What changed because of this session: records it set, next time's weights,
 * each lift's top set against the last time it was done, and volume against
 * the last time this same plan day was done. Pure; `sessions` holds every
 * log including this one.
 */
export function buildTrainingRecap(input: {
  sessionId: string;
  sessions: Session[];
  nextWeights: TrainingRecapType["nextWeights"];
  streakWeeks: number;
}): TrainingRecapType {
  const index = input.sessions.findIndex((session) => session.sessionId === input.sessionId);
  const session = index >= 0 ? input.sessions[index] : undefined;
  const earlier = index >= 0 ? input.sessions.slice(0, index) : input.sessions;

  const comparedToLast: TrainingRecapType["comparedToLast"] = [];
  for (const lift of session?.lifts ?? []) {
    const previous = [...earlier].reverse().map((entry) => entry.lifts.find((other) => other.key === lift.key)).find(Boolean);
    if (!previous) continue;
    const now = topSet(lift.sets);
    const then = topSet(previous.sets);
    comparedToLast.push({ exerciseName: lift.name.slice(0, 80), deltaLb: clampDelta(now.lb - then.lb), deltaReps: now.reps - then.reps });
  }

  // Volume means something only against the same kind of day: leg day
  // against push day is noise.
  const sameDay = session
    ? [...earlier].reverse().find((entry) => (session.dayKey && entry.dayKey === session.dayKey) || (session.name && entry.name === session.name))
    : undefined;

  return TrainingRecap.parse({
    records: session?.sessionId ? recordsForSession(input.sessions, session.sessionId).slice(0, 5).map((record) => PersonalRecordSchema.parse(record)) : [],
    nextWeights: input.nextWeights.slice(0, 10),
    comparedToLast: comparedToLast.slice(0, 10),
    volumeLb: Math.round(session?.volumeLb ?? 0),
    ...(sameDay ? { previousVolumeLb: Math.round(sameDay.volumeLb) } : {}),
    streakWeeks: input.streakWeeks,
  });
}

function topSet(sets: LoadedSet[]): LoadedSet {
  return sets.reduce((best, set) => (set.lb > best.lb || (set.lb === best.lb && set.reps > best.reps) ? set : best));
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

export function toLb(kg: number): number {
  return Math.round(kg * KG_TO_LB * 2) / 2;
}

function clampLb(pounds: number): number {
  return Math.min(2000, Math.max(0, Math.round(pounds * 2) / 2));
}

function clampDelta(pounds: number): number {
  return Math.round(pounds * 2) / 2;
}

function round1(value: number): number {
  return Math.round(value * 10) / 10;
}

function isRecord(value: unknown): value is Loose {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function finite(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function dateOf(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const date = value.slice(0, 10);
  return /^\d{4}-\d{2}-\d{2}$/.test(date) && Number.isFinite(Date.parse(`${date}T00:00:00Z`)) ? date : null;
}

function asDayKey(value: unknown): DayKey | undefined {
  return (DAY_KEYS as readonly unknown[]).includes(value) ? (value as DayKey) : undefined;
}

export function addDays(date: string, days: number): string {
  return new Date(Date.parse(`${date}T00:00:00Z`) + days * 86_400_000).toISOString().slice(0, 10);
}

export function dayKeyOf(date: string): DayKey {
  // getUTCDay: 0 = Sunday.
  return DAY_KEYS[(new Date(Date.parse(`${date}T00:00:00Z`)).getUTCDay() + 6) % 7];
}

/** The Monday of the calendar week holding `date`. */
export function weekStartOf(date: string): string {
  return addDays(date, -DAY_KEYS.indexOf(dayKeyOf(date)));
}

function cmp(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

function compact<T extends Record<string, unknown>>(value: T): T {
  return Object.fromEntries(Object.entries(value).filter(([, entry]) => entry !== undefined)) as T;
}
