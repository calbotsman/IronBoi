import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { TrainingHistory, TrainingRecap } from "../../../src/contracts/coach-agent.js";
import { finishWorkoutSession, startWorkoutSession } from "../../../src/workouts/activeWorkout.js";
import { rolloverTrainingPrograms } from "../../../src/workouts/rollover.js";
import { planSessionProgression } from "../../../src/workouts/sessionProgression.js";
import { progressionEventId } from "../../../src/workouts/progressionEvents.js";
import { refreshTrainingHistoryIfStale } from "../../../src/progress/trainingHistoryStore.js";
import {
  exerciseBaselinePath,
  progressionEventPath,
  progressionEventsCollection,
  trainingHistoryPath,
  trainingProgramPath,
  workoutPlanPath,
} from "../../../src/paths.js";

// Double progression (docs/plans/myo-training-intelligence.md S2): every
// prescribed set done with every rep at the prescribed weight → the next
// session starts one step up, with an event saying why, and the weekly
// rollover never adds a second step for the same week.
const USER_ID = "session-progression-user-a";
const START = "2026-08-03"; // Monday
const RULE = { mode: "linear_lb", amount: 5, everyWeeks: 1, capMultiple: 1.3 };

let app: App;
let db: Firestore;

const DAY = {
  name: "Push",
  muscles: [],
  exercises: [
    { name: "Barbell Bench Press", sets: 3, reps: 8, weight: 155, progression: RULE },
    { name: "KB Goblet Squat", sets: 3, reps: 10, weight: 35 },
    { name: "Push-ups", sets: 3, reps: 12, weight: 0 },
    { name: "Plank", sets: 2, reps: 60, weight: 20 },
  ],
};

async function seed() {
  await db.doc(workoutPlanPath(USER_ID, "current")).set({
    userId: USER_ID, planId: "current", source: "coach_generated", days: { Mon: DAY }, updatedAt: `${START}T00:00:00.000Z`,
  });
  await db.doc(trainingProgramPath(USER_ID)).set({
    userId: USER_ID, programId: "current", startDate: START,
    weeks: [0, 1, 2, 3].map((weekIndex) => ({ weekIndex, days: { Mon: DAY } })),
    activeWeekIndex: 0, source: "coach_generated", updatedAt: `${START}T00:00:00.000Z`,
  });
}

// Starts and finishes Monday's session on `date`; `reps(name)` says how many
// reps each set of that exercise got (default: the target).
async function train(date: string, reps: (name: string, target: number) => number = (_name, target) => target) {
  const session = await startWorkoutSession(
    db, USER_ID,
    { dayKey: "Mon", planId: "current", startedAt: `${date}T12:00:00.000Z`, clientDate: date, sessionId: `${date}_mon` },
    {},
  );
  const result = await finishWorkoutSession(db, USER_ID, {
    sessionId: session.sessionId,
    completedAt: `${date}T13:00:00.000Z`,
    clientDate: date,
    exercises: session.exercises.map((exercise) => ({
      ...exercise,
      completedSets: exercise.completedSets.map((set) => ({ ...set, completed: true, reps: reps(exercise.name, exercise.targetReps) })),
    })),
  });
  return { session, result };
}

const anchor = async (key: string) => (await db.doc(exerciseBaselinePath(USER_ID, key)).get()).data();
const planWeight = async (index: number) =>
  (await db.doc(workoutPlanPath(USER_ID, "current")).get()).data()?.days.Mon.exercises[index].weight as number;

describe("session progression", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
    try { db.settings({ ignoreUndefinedProperties: true }); } catch { /* already applied */ }
  });
  beforeEach(async () => { await db.recursiveDelete(db.doc(`users/${USER_ID}`)); });
  afterAll(async () => { await Promise.all(getApps().map((a) => deleteApp(a))); });

  it("every rep hit → next session one step up, with a session_up event and the plan updated", async () => {
    await seed();
    const { result } = await train(START);
    expect(await anchor("barbell_bench_press")).toMatchObject({ anchorWeightLb: 160, anchorDate: START, source: "user_session" });
    // No rule on the kettlebell lift: the default 5 lb step.
    expect(await anchor("kb_goblet_squat")).toMatchObject({ anchorWeightLb: 40 });
    expect(await planWeight(0)).toBe(160);
    expect(await planWeight(1)).toBe(40);

    const event = (await db.doc(progressionEventPath(USER_ID, progressionEventId(`${START}_mon`, "session_up", "barbell_bench_press"))).get()).data();
    expect(event).toMatchObject({ kind: "session_up", fromLb: 155, toLb: 160, date: START, reason: "All 3×8 hit at 155 lb" });

    // The finish result: the journey recap stays as it was, the new one beside it.
    expect(result.recap).toBeDefined();
    expect(TrainingRecap.safeParse(result.trainingRecap).success).toBe(true);
    expect(result.trainingRecap?.nextWeights).toEqual([
      { exerciseName: "Barbell Bench Press", fromLb: 155, toLb: 160, reason: "All 3×8 hit at 155 lb" },
      { exerciseName: "KB Goblet Squat", fromLb: 35, toLb: 40, reason: "All 3×10 hit at 35 lb" },
    ]);

    // The next session is prescribed the new weight.
    const next = await startWorkoutSession(
      db, USER_ID, { dayKey: "Mon", planId: "current", startedAt: "2026-08-05T12:00:00.000Z", clientDate: "2026-08-05" }, {},
    );
    expect(next.exercises[0].targetWeight).toBe(160);
  });

  it("missed reps → no change; bodyweight and timed work never step", async () => {
    await seed();
    await train(START, (name, target) => (name === "Barbell Bench Press" ? target - 2 : target));
    expect(await anchor("barbell_bench_press")).toMatchObject({ anchorWeightLb: 155, source: "plan_seed" });
    expect(await anchor("kb_goblet_squat")).toMatchObject({ anchorWeightLb: 40 });
    expect(await anchor("push_ups")).toBeUndefined();
    expect(await anchor("plank")).toBeUndefined();
    const kinds = (await db.collection(progressionEventsCollection(USER_ID)).get()).docs.map((doc) => `${doc.data().kind}:${doc.data().exerciseKey}`);
    expect(kinds.sort()).toEqual(["session_up:kb_goblet_squat"]);
  });

  it("no double step: the weekly rollover a week later keeps the session's step", async () => {
    await seed();
    await train(START);
    await rolloverTrainingPrograms(db, "2026-08-10");
    expect(await planWeight(0)).toBe(160);
    expect(await anchor("barbell_bench_press")).toMatchObject({ anchorWeightLb: 160, anchorDate: "2026-08-10", holdWeeks: 0 });

    // Untrained week: a hold, written as an event.
    await rolloverTrainingPrograms(db, "2026-08-17");
    expect(await planWeight(0)).toBe(160);
    const hold = (await db.doc(progressionEventPath(USER_ID, progressionEventId("2026-08-17", "hold_not_trained", "barbell_bench_press"))).get()).data();
    expect(hold).toMatchObject({ fromLb: 160, toLb: 160, kind: "hold_not_trained" });

    // Trained again with every rep: one more step, still never two.
    await train("2026-08-17");
    await rolloverTrainingPrograms(db, "2026-08-24");
    expect(await planWeight(0)).toBe(165);
  });

  it("a retried finish neither steps twice nor duplicates events", async () => {
    await seed();
    const { session } = await train(START);
    await finishWorkoutSession(db, USER_ID, {
      sessionId: session.sessionId,
      completedAt: `${START}T13:00:00.000Z`,
      clientDate: START,
      exercises: session.exercises.map((exercise) => ({
        ...exercise,
        completedSets: exercise.completedSets.map((set) => ({ ...set, completed: true })),
      })),
    });
    expect(await anchor("barbell_bench_press")).toMatchObject({ anchorWeightLb: 160 });
    const events = await db.collection(progressionEventsCollection(USER_ID)).get();
    expect(events.size).toBe(2);
    expect(events.docs.map((doc) => doc.id).sort()).toEqual([
      `${START}_mon_session_up_barbell_bench_press`,
      `${START}_mon_session_up_kb_goblet_squat`,
    ]);
  });

  it("a lift worked at a different weight gets a changed_in_workout event and steps from what was lifted", async () => {
    await seed();
    const session = await startWorkoutSession(
      db, USER_ID, { dayKey: "Mon", planId: "current", startedAt: `${START}T12:00:00.000Z`, clientDate: START, sessionId: `${START}_mon` }, {},
    );
    const result = await finishWorkoutSession(db, USER_ID, {
      sessionId: session.sessionId,
      completedAt: `${START}T13:00:00.000Z`,
      clientDate: START,
      exercises: session.exercises.map((exercise) => ({
        ...exercise,
        completedSets: exercise.completedSets.map((set) => ({
          ...set, completed: true, ...(exercise.name === "KB Goblet Squat" ? { weight: 40 } : {}),
        })),
      })),
    });
    const changed = (await db.doc(progressionEventPath(USER_ID, progressionEventId(`${START}_mon`, "changed_in_workout", "kb_goblet_squat"))).get()).data();
    expect(changed).toMatchObject({ fromLb: 35, toLb: 40 });
    expect(await anchor("kb_goblet_squat")).toMatchObject({ anchorWeightLb: 45 });
    // The "keep 40?" card would pull the new anchor back down: not offered.
    expect(result.baselineSuggestions).toEqual([]);
  });

  it("a reduced day (a ramp override) never earns a step", () => {
    const ups = planSessionProgression({
      exercises: [{
        exerciseIndex: 0, name: "Barbell Bench Press", targetSets: 3, targetReps: 8, targetWeight: 80, exerciseDone: true,
        completedSets: [0, 1, 2].map((setIndex) => ({ setIndex, completed: true, reps: 8, weight: 80 })),
      }],
      planDays: { Mon: DAY },
      baselines: new Map(),
      date: START,
    });
    expect(ups).toEqual([]);
  });

  it("rebuilds the training history doc at finish, and lazily when the day changes", async () => {
    await seed();
    await train(START);
    const stored = (await db.doc(trainingHistoryPath(USER_ID)).get()).data();
    expect(TrainingHistory.safeParse({ ...stored, serverUpdatedAt: undefined }).success).toBe(false); // extra key on the doc
    const { serverUpdatedAt: _stamp, ...doc } = stored ?? {};
    const history = TrainingHistory.parse(doc);
    expect(history.today).toBe(START);
    expect(history.lifts.find((lift) => lift.exerciseKey === "barbell_bench_press")).toMatchObject({ currentLb: 160, startLb: 155 });

    const same = await refreshTrainingHistoryIfStale(db, USER_ID, START, new Date(`${START}T13:10:00.000Z`));
    expect(same.rebuilt).toBe(false);
    const nextDay = await refreshTrainingHistoryIfStale(db, USER_ID, "2026-08-04", new Date("2026-08-04T09:00:00.000Z"));
    expect(nextDay.rebuilt).toBe(true);
    expect((await db.doc(trainingHistoryPath(USER_ID)).get()).data()?.today).toBe("2026-08-04");
  });
});
