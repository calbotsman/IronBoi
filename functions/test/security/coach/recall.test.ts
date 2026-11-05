import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { exerciseMatches, recallTrainingHistory } from "../../../src/coach/recall.js";
import { buildCoachToolRegistry } from "../../../src/coach/toolRegistry.js";
import { executeTool } from "../../../src/tools/executor.js";
import { LIVE_TOOL_NAMES } from "../../../src/coach/liveSession.js";
import { workoutLogPath } from "../../../src/paths.js";

const USER = "recall-user-a";
const OTHER = "recall-user-b";
let app: App;
let db: Firestore;

function log(userId: string, date: string, exercises: Array<[string, number, number]>) {
  return {
    userId,
    sessionId: `s_${date}`,
    date,
    source: "manual",
    exercises: exercises.map(([name, kg, reps]) => ({ name, sets: [{ reps, loadKg: kg }, { reps, loadKg: kg }] })),
    createdAt: `${date}T18:00:00.000Z`,
  };
}

describe("deep recall over workoutLogs", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });
  beforeEach(async () => {
    await Promise.allSettled([db.recursiveDelete(db.doc(`users/${USER}`)), db.recursiveDelete(db.doc(`users/${OTHER}`))]);
    const logs: Array<[string, ReturnType<typeof log>]> = [
      [USER, log(USER, "2026-03-10", [["Barbell Bench Press", 80, 5], ["Back Squat", 100, 5]])],
      [USER, log(USER, "2026-04-20", [["Barbell Bench Press", 85, 3]])],
      [USER, log(USER, "2026-05-28", [["Dumbbell Bench Press", 30, 10]])],
      [USER, log(USER, "2026-07-01", [["Barbell Bench Press", 90, 2]])],
      [USER, log(USER, "2026-10-30", [["Deadlift", 140, 5]])],
      [OTHER, log(OTHER, "2026-04-01", [["Barbell Bench Press", 200, 1]])],
    ];
    for (const [uid, entry] of logs) await db.doc(workoutLogPath(uid, entry.sessionId)).set(entry);
  });
  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  it("matches every word of the query, in any order", () => {
    expect(exerciseMatches("bench", "Barbell Bench Press")).toBe(true);
    expect(exerciseMatches("bench presses", "Dumbbell Bench Press")).toBe(true);
    expect(exerciseMatches("barbell bench", "Dumbbell Bench Press")).toBe(false);
    expect(exerciseMatches("squat", "Barbell Bench Press")).toBe(false);
  });

  it("answers 'what did I bench last spring?' from that user's logs only", async () => {
    const result = await recallTrainingHistory(db, USER, { exerciseName: "bench", from: "2026-03-01", to: "2026-05-31" });
    expect(result.ok).toBe(true);
    if (!("sessions" in result)) throw new Error("expected sessions");
    expect(result.sessionsFound).toBe(3);
    expect(result.sessions.map((s) => s.date)).toEqual(["2026-05-28", "2026-04-20", "2026-03-10"]);
    expect(result.heaviest).toEqual({ date: "2026-04-20", exercise: "Barbell Bench Press", lb: Math.round(85 * 2.20462), reps: 3 });
    // The squat in the same session is filtered out.
    expect(result.sessions[2].exercises.map((e) => e.name)).toEqual(["Barbell Bench Press"]);
    expect(JSON.stringify(result)).not.toContain(String(Math.round(200 * 2.20462)));
  });

  it("says plainly when nothing matches, and rejects a reversed range", async () => {
    const none = await recallTrainingHistory(db, USER, { exerciseName: "overhead press" });
    expect(none).toMatchObject({ ok: true, sessionsFound: 0 });
    expect((none as { hint?: string }).hint).toMatch(/don't guess/);
    expect(await recallTrainingHistory(db, USER, { from: "2026-06-01", to: "2026-01-01" })).toMatchObject({ ok: false, error: "from_after_to" });
  });

  it("runs through the coach registry for the authenticated user, in text and live", async () => {
    const registry = buildCoachToolRegistry(db, {});
    const result = (await executeTool(registry, "recall_training_history", { exerciseName: "deadlift" }, { authenticatedUserId: USER })) as Record<string, unknown>;
    expect(result).toMatchObject({ ok: true, sessionsFound: 1 });
    const bad = (await executeTool(registry, "recall_training_history", { from: "spring" }, { authenticatedUserId: USER })) as Record<string, unknown>;
    expect(bad).toMatchObject({ ok: false, error: "invalid_recall_training_history_args" });
    expect(LIVE_TOOL_NAMES).toContain("recall_training_history");
  });
});
