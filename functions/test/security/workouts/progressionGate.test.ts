import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { finishWorkoutSession, startWorkoutSession } from "../../../src/workouts/activeWorkout.js";
import { rolloverTrainingPrograms } from "../../../src/workouts/rollover.js";
import { reanchorForApprovedEdit } from "../../../src/workouts/exerciseBaselines.js";
import { exerciseBaselinesCollectionPath, trainingProgramPath, workoutPlanPath } from "../../../src/paths.js";

// The rep gate: a step is earned by a trained week with every rep hit.
// Skipped → hold. Missed reps → hold; twice in a row → deload 10%.
const USER_ID = "progression-gate-user-a";
const START = "2026-08-03"; // Monday
const RULE = { mode: "linear_lb", amount: 5, everyWeeks: 1, capMultiple: 1.3 };

let app: App;
let db: Firestore;

function bench(weight: number, extra: Record<string, unknown> = {}) {
  return { name: "Barbell Bench Press", sets: 3, reps: 8, weight, progression: RULE, ...extra };
}

async function seed(days: Record<string, unknown>) {
  await db.doc(workoutPlanPath(USER_ID, "current")).set({
    userId: USER_ID, planId: "current", source: "coach_generated", days, updatedAt: `${START}T00:00:00.000Z`,
  });
  await db.doc(trainingProgramPath(USER_ID)).set({
    userId: USER_ID, programId: "current", startDate: START,
    weeks: [0, 1, 2, 3].map((weekIndex) => ({ weekIndex, days })),
    activeWeekIndex: 0, source: "coach_generated", updatedAt: `${START}T00:00:00.000Z`,
  });
}

// Starts and finishes the Mon session on `date`, reporting `reps` per set.
async function train(date: string, reps: number, dayKey = "Mon") {
  const session = await startWorkoutSession(
    db, USER_ID,
    { dayKey, planId: "current", startedAt: `${date}T12:00:00.000Z`, clientDate: date, sessionId: `${date}_${dayKey}` },
    {},
  );
  await finishWorkoutSession(db, USER_ID, {
    sessionId: session.sessionId,
    completedAt: `${date}T13:00:00.000Z`,
    exercises: session.exercises.map((exercise) => ({
      ...exercise,
      completedSets: exercise.completedSets.map((set) => ({ ...set, completed: true, reps })),
    })),
  });
  return session;
}

const planWeight = async (dayKey = "Mon") =>
  (await db.doc(workoutPlanPath(USER_ID, "current")).get()).data()?.days[dayKey].exercises[0].weight as number;
const baseline = async () =>
  (await db.collection(exerciseBaselinesCollectionPath(USER_ID)).doc("barbell_bench_press").get()).data();

describe("progression rep gate", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
    try { db.settings({ ignoreUndefinedProperties: true }); } catch { /* already applied */ }
  });
  beforeEach(async () => { await db.recursiveDelete(db.doc(`users/${USER_ID}`)); });
  afterAll(async () => { await Promise.all(getApps().map((a) => deleteApp(a))); });

  it("advances after a trained week with every rep hit, and holds through an untrained week", async () => {
    await seed({ Mon: { name: "Push", muscles: [], exercises: [bench(155)] } });
    const first = await train(START, 8);
    expect(first.exercises[0].targetWeight).toBe(155);
    expect((await baseline())?.source).toBe("plan_seed");

    await rolloverTrainingPrograms(db, "2026-08-10");
    expect(await planWeight()).toBe(160);

    // Nobody trained in week 1 → week 2 holds at 160 instead of 165.
    await rolloverTrainingPrograms(db, "2026-08-17");
    expect(await planWeight()).toBe(160);
    expect((await baseline())?.holdWeeks).toBe(1);

    // A retried rollover the same day changes nothing.
    await rolloverTrainingPrograms(db, "2026-08-17");
    expect(await planWeight()).toBe(160);
    expect((await baseline())?.holdWeeks).toBe(1);
  });

  it("holds on missed reps, then deloads 10% and restarts the clock on the second miss", async () => {
    await seed({ Mon: { name: "Push", muscles: [], exercises: [bench(155)] } });
    await train(START, 6); // missed 8s
    await rolloverTrainingPrograms(db, "2026-08-10");
    expect(await planWeight()).toBe(155);
    expect(await baseline()).toMatchObject({ consecutiveHolds: 1, holdWeeks: 1 });

    await train("2026-08-10", 6); // missed again
    await rolloverTrainingPrograms(db, "2026-08-17");
    // Was being prescribed 155 (2 weeks − 1 hold = 1 step… held) → deload 10% of 160 → 144 → 145.
    const after = await baseline();
    expect(after).toMatchObject({ source: "coach", anchorDate: "2026-08-17", holdWeeks: 0, consecutiveHolds: 0 });
    expect(after?.anchorWeightLb).toBe(145);
    expect(await planWeight()).toBe(145);

    // Recovery: hit the reps at the deload weight and the step returns.
    await train("2026-08-17", 8);
    await rolloverTrainingPrograms(db, "2026-08-24");
    expect(await planWeight()).toBe(150);
  });

  it("serves an approved dailyOverride exactly as approved and never seeds an anchor from it", async () => {
    await seed({ Mon: { name: "Push", muscles: [], exercises: [bench(155)] } });
    await db.doc(workoutPlanPath(USER_ID, "current")).set(
      { dailyOverrides: { [START]: { name: "Ramp week 1 · 50%", muscles: [], exercises: [bench(80)] } } },
      { merge: true },
    );
    const session = await startWorkoutSession(
      db, USER_ID, { dayKey: "Mon", planId: "current", startedAt: `${START}T12:00:00.000Z`, clientDate: START }, {},
    );
    expect(session.exercises[0].targetWeight).toBe(80);
    expect((await db.collection(exerciseBaselinesCollectionPath(USER_ID)).get()).empty).toBe(true);
  });

  it("a lift the plan prescribes at two weights is not auto-anchored; both days keep their own numbers", async () => {
    await seed({
      Tue: { name: "Pull", muscles: [], exercises: [{ name: "Deadlift", sets: 4, reps: 6, weight: 135, progression: RULE }] },
      Fri: { name: "Legs", muscles: [], exercises: [{ name: "Deadlift", sets: 5, reps: 5, weight: 155, progression: RULE }] },
    });
    await train("2026-08-04", 6, "Tue");
    expect((await db.collection(exerciseBaselinesCollectionPath(USER_ID)).get()).empty).toBe(true);
    await rolloverTrainingPrograms(db, "2026-08-10");
    expect(await planWeight("Tue")).toBe(135);
    expect(await planWeight("Fri")).toBe(155);
  });

  it("an approved going_forward edit with a new load becomes the anchor instead of being overwritten", async () => {
    await seed({ Mon: { name: "Push", muscles: [], exercises: [bench(155)] } });
    await train(START, 8); // anchor 155
    const changed = await reanchorForApprovedEdit(
      db, USER_ID,
      [{ exercises: [{ name: "Barbell Bench Press", weight: 185 }, { name: "Unanchored Thing", weight: 50 }] }],
      "2026-08-05", "2026-08-05T12:00:00.000Z",
    );
    expect(changed).toBe(1);
    expect(await baseline()).toMatchObject({ anchorWeightLb: 185, anchorDate: "2026-08-05", source: "coach", holdWeeks: 0 });
    // The rollover a week later continues from the coach's number.
    await train("2026-08-06", 8);
    await rolloverTrainingPrograms(db, "2026-08-12");
    expect(await planWeight()).toBe(190);
  });
});
