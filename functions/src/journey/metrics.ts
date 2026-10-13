import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { profilePath, userRoot } from "../paths.js";
import { safeLogger } from "../logging/safeLogger.js";

// Is MYO becoming a habit? (docs/product/habit-journey-plan.md §7.)
//
// Computed on the server from data already stored — no analytics SDK, nothing
// new collected. The output is COUNTS ONLY: no user ids, no per-person rows.
// Each metric is a { hit, of } pair so a rate is never shown without the
// number of people behind it (today that number is tiny).

const DAY_MS = 24 * 60 * 60 * 1000;

export type UserJourney = {
  /** When they finished onboarding (or, failing that, created the profile). */
  signupAt: number;
  /** Completed workouts, epoch ms. */
  workoutAts: number[];
};

export type Ratio = { hit: number; of: number };

export type HabitMetrics = {
  users: number;
  /** First workout within 48h of signup (people signed up ≥ 48h ago). */
  activation48h: Ratio;
  /** Second workout within 7 days of the first (first workout ≥ 7 days ago). */
  secondWorkoutIn7d: Ratio;
  /** Any workout in days 21–27 after signup (signed up ≥ 28 days ago). */
  week4Active: Ratio;
  /** Any workout in days 77–83 after signup (signed up ≥ 84 days ago). */
  week12Active: Ratio;
  /** Of the last 4 full weeks, weeks with 2+ workouts, over people who trained in them. */
  weeksWith2Plus: Ratio;
  /** Came back within 30 days after a 14+ day gap that started in the last 60 days. */
  comebacks: Ratio;
};

export function computeHabitMetrics(people: UserJourney[], now: number): HabitMetrics {
  const metrics: HabitMetrics = {
    users: people.length,
    activation48h: { hit: 0, of: 0 },
    secondWorkoutIn7d: { hit: 0, of: 0 },
    week4Active: { hit: 0, of: 0 },
    week12Active: { hit: 0, of: 0 },
    weeksWith2Plus: { hit: 0, of: 0 },
    comebacks: { hit: 0, of: 0 },
  };

  for (const person of people) {
    const workouts = [...person.workoutAts].filter((at) => at <= now).sort((a, b) => a - b);
    const sinceSignup = (at: number) => (at - person.signupAt) / DAY_MS;

    if (now - person.signupAt >= 2 * DAY_MS) {
      metrics.activation48h.of += 1;
      if (workouts.some((at) => at >= person.signupAt && sinceSignup(at) < 2)) metrics.activation48h.hit += 1;
    }

    const first = workouts[0];
    if (first !== undefined && now - first >= 7 * DAY_MS) {
      metrics.secondWorkoutIn7d.of += 1;
      if (workouts[1] !== undefined && workouts[1] - first < 7 * DAY_MS) metrics.secondWorkoutIn7d.hit += 1;
    }

    for (const [key, startDay] of [["week4Active", 21], ["week12Active", 77]] as const) {
      if (now - person.signupAt < (startDay + 7) * DAY_MS) continue;
      metrics[key].of += 1;
      if (workouts.some((at) => sinceSignup(at) >= startDay && sinceSignup(at) < startDay + 7)) metrics[key].hit += 1;
    }

    // Four rolling 7-day windows ending now; a person counts only for the
    // windows after their first workout, and only if they trained at all in
    // the last four weeks (lapsed people are what `comebacks` is for).
    const recent = workouts.filter((at) => now - at < 28 * DAY_MS);
    if (recent.length > 0 && first !== undefined) {
      for (let week = 0; week < 4; week += 1) {
        const end = now - week * 7 * DAY_MS;
        const start = end - 7 * DAY_MS;
        if (end <= first) continue;
        metrics.weeksWith2Plus.of += 1;
        if (workouts.filter((at) => at >= start && at < end).length >= 2) metrics.weeksWith2Plus.hit += 1;
      }
    }

    // A lapse: a 14+ day gap after a workout, starting in the last 60 days,
    // old enough that 30 days have passed to see whether they came back.
    for (let i = 0; i < workouts.length; i += 1) {
      const lastBefore = workouts[i];
      const lapseStart = lastBefore + 14 * DAY_MS;
      if (now - lapseStart > 60 * DAY_MS || now - lapseStart < 30 * DAY_MS) continue;
      const next = workouts[i + 1];
      if (next !== undefined && next < lapseStart) continue; // no gap here
      metrics.comebacks.of += 1;
      if (next !== undefined && next - lapseStart <= 30 * DAY_MS) metrics.comebacks.hit += 1;
    }
  }
  return metrics;
}

/**
 * Daily: read every user's signup time and completed workouts, write the
 * counts to ops_metrics/{date}. Fine at TestFlight scale (one read of each
 * user's logs); past a few thousand users this wants an incremental rollup.
 */
export async function runHabitMetrics(db: Firestore, nowISO?: string) {
  const now = nowISO ? Date.parse(nowISO) : Date.now();
  const userRefs = await db.collection("users").listDocuments();
  const people: UserJourney[] = [];

  for (const userRef of userRefs) {
    const userId = userRef.id;
    const profile = (await db.doc(profilePath(userId)).get()).data();
    if (!profile || profile.onboardingStatus !== "complete") continue;
    const signupAt = parseTime(profile.onboardingCompletedAt) ?? parseTime(profile.createdAt);
    if (signupAt === undefined) continue;
    const logs = await db.collection(`${userRoot(userId)}/workoutLogs`).select("createdAt").get();
    const workoutAts = logs.docs
      .map((doc) => parseTime(doc.get("createdAt")))
      .filter((at): at is number => at !== undefined);
    people.push({ signupAt, workoutAts });
  }

  const metrics = computeHabitMetrics(people, now);
  const date = new Date(now).toISOString().slice(0, 10);
  await db.doc(`ops_metrics/${date}`).set({
    ...metrics,
    computedAt: new Date(now).toISOString(),
    serverUpdatedAt: FieldValue.serverTimestamp(),
  });

  const ratio = (r: Ratio) => `${r.hit}/${r.of}`;
  safeLogger.info("Habit metrics computed", {
    event: "habit_metrics_computed",
    outcome: [
      `users_${metrics.users}`,
      `activation48h_${ratio(metrics.activation48h)}`,
      `second7d_${ratio(metrics.secondWorkoutIn7d)}`,
      `week4_${ratio(metrics.week4Active)}`,
      `week12_${ratio(metrics.week12Active)}`,
      `weeks2plus_${ratio(metrics.weeksWith2Plus)}`,
      `comebacks_${ratio(metrics.comebacks)}`,
    ].join(" "),
  });
  return metrics;
}

function parseTime(value: unknown): number | undefined {
  if (typeof value === "string") {
    const at = Date.parse(value);
    return Number.isNaN(at) ? undefined : at;
  }
  if (value && typeof value === "object" && "toMillis" in value && typeof value.toMillis === "function") {
    return (value as { toMillis: () => number }).toMillis();
  }
  return undefined;
}
