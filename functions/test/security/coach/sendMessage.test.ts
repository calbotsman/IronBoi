import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import {
  IosCoachMessageRequest,
  handleSendCoachMessage,
  maybeApplyWorkoutPlanAdjustment,
} from "../../../src/coach/sendMessage.js";
import {
  coachSessionMessagePath,
  coachSessionPath,
  profilePath,
  workoutPlanPath,
} from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

// Callable-migration parity suite: BOTH sendCoachMessage (onCall) and
// sendCoachMessageHttp route through handleSendCoachMessage, so these tests
// pin the behavior the iOS app depends on for either transport:
//   - the exact iOS payload (clientDate/startedAt/turnId/structuredAnswer)
//     parses, where the pre-migration onCall's strict CoachMessage.extend
//     parse rejected it
//   - the session doc is upserted (the app never calls createCoachSession)
//   - the deterministic weight-update path runs and patches matching
//     dailyOverrides

const USER_ID = "send-coach-message-user-a";

// Pinned fixture dates (never wall-clock): 2026-01-05 is a Monday.
const MONDAY_DATE = "2026-01-05";
const MONDAY_TS = "2026-01-05T12:00:00.000Z";

let app: App;
let db: Firestore;

function basePlan() {
  return {
    userId: USER_ID,
    planId: "current",
    source: "coach_generated",
    updatedAt: "2026-01-01T00:00:00.000Z",
    days: {
      Mon: {
        name: "Push Day",
        exercises: [
          { name: "Bench Press", sets: 3, reps: 8, weight: 135 },
          { name: "Overhead Press", sets: 3, reps: 10, weight: 95 },
        ],
      },
    },
    dailyOverrides: {
      [MONDAY_DATE]: {
        name: "Push Day (reduced)",
        exercises: [{ name: "Bench Press", sets: 2, reps: 8, weight: 135 }],
      },
    },
  };
}

function iosPayload(overrides: Record<string, unknown> = {}) {
  // Mirrors AppModel.sendCoachMessage exactly — including the empty
  // structuredAnswer dictionary it sends when the user has no workout
  // context attached.
  return {
    sessionId: "general",
    messageId: "ios_1767614400000",
    content: "hello coach",
    timestamp: MONDAY_TS,
    startedAt: MONDAY_TS,
    toolCallIds: [],
    structuredAnswer: {},
    clientDate: MONDAY_DATE,
    ...overrides,
  };
}

describe("shared coach-message handler (callable/*Http parity)", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });

  beforeEach(async () => {
    await Promise.allSettled([db.recursiveDelete(db.doc(`users/${USER_ID}`))]);
    await db.doc(profilePath(USER_ID)).set({ ...baseProfile, userId: USER_ID });
  });

  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  it("accepts the exact iOS payload (clientDate + startedAt + turnId)", () => {
    const parsed = IosCoachMessageRequest.parse(
      iosPayload({ turnId: "turn-1" }),
    );
    expect(parsed.clientDate).toBe(MONDAY_DATE);
    expect(parsed.startedAt).toBe(MONDAY_TS);
    expect(parsed.turnId).toBe("turn-1");
    expect(parsed.inputMode).toBe("text");
  });

  it("still accepts an older-client payload without clientDate/startedAt", () => {
    const { clientDate: _c, startedAt: _s, ...older } = iosPayload();
    const parsed = IosCoachMessageRequest.parse(older);
    expect(parsed.clientDate).toBeUndefined();
    expect(parsed.startedAt).toBeUndefined();
  });

  it("upserts the session and writes the message with clientDate/turnId", async () => {
    const parsed = IosCoachMessageRequest.parse(iosPayload({ turnId: "turn-2" }));
    const result = await handleSendCoachMessage(db, USER_ID, parsed);

    expect(result).toMatchObject({
      ok: true,
      userId: USER_ID,
      sessionId: "general",
      messageId: parsed.messageId,
      planAdjustment: null,
    });

    const sessionSnap = await db.doc(coachSessionPath(USER_ID, "general")).get();
    expect(sessionSnap.data()).toMatchObject({
      userId: USER_ID,
      sessionId: "general",
      startedAt: MONDAY_TS,
      outcome: "active",
    });

    const messageSnap = await db
      .doc(coachSessionMessagePath(USER_ID, "general", parsed.messageId))
      .get();
    expect(messageSnap.data()).toMatchObject({
      userId: USER_ID,
      sessionId: "general",
      messageId: parsed.messageId,
      role: "user",
      content: "hello coach",
      timestamp: MONDAY_TS,
      inputMode: "text",
      status: "queued",
      clientDate: MONDAY_DATE,
      turnId: "turn-2",
    });
    expect(messageSnap.data()?.serverCreatedAt).toBeTruthy();
  });

  it("runs the deterministic weight update and patches matching overrides", async () => {
    await db.doc(workoutPlanPath(USER_ID, "current")).set(basePlan());

    // NOTE: parseRequestedPounds takes the FIRST "<n> lb" match in the
    // content, so this fixture mentions exactly one weight. (The iOS
    // askCoachAboutWorkout prefix "…currently 3x8 at 135 lb." would win
    // over the user's requested weight — a pre-existing *Http behavior
    // this migration preserves, flagged in the PR.)
    const parsed = IosCoachMessageRequest.parse(
      iosPayload({
        content: "Bump bench press to 145 lbs please",
        structuredAnswer: {
          kind: "workout_plan_adjustment",
          dayKey: "Mon",
          exerciseName: "Bench Press",
          currentSets: 3,
          currentReps: 8,
          currentWeight: 135,
        },
      }),
    );
    const result = await handleSendCoachMessage(db, USER_ID, parsed);

    expect(result.planAdjustment).toEqual({
      dayKey: "Mon",
      exerciseName: "Bench Press",
      targetWeight: 145,
    });

    const planSnap = await db.doc(workoutPlanPath(USER_ID, "current")).get();
    const plan = planSnap.data()!;
    const monday = plan.days.Mon.exercises as Array<Record<string, unknown>>;
    expect(monday[0]).toMatchObject({ name: "Bench Press", weight: 145 });
    // Only the targeted exercise changes.
    expect(monday[1]).toMatchObject({ name: "Overhead Press", weight: 95 });
    // The active same-weekday override is patched too, or the user would
    // never see the change on the card they are looking at.
    expect(plan.dailyOverrides[MONDAY_DATE].exercises[0]).toMatchObject({
      name: "Bench Press",
      weight: 145,
    });
    expect(plan.source).toBe("user_edited");
  });

  it("does not touch the plan without workout_plan_adjustment context", async () => {
    await db.doc(workoutPlanPath(USER_ID, "current")).set(basePlan());

    const direct = await maybeApplyWorkoutPlanAdjustment(
      db,
      USER_ID,
      "let's go with 145 lbs",
      {},
    );
    expect(direct).toBeNull();

    const planSnap = await db.doc(workoutPlanPath(USER_ID, "current")).get();
    expect(planSnap.data()?.days.Mon.exercises[0]).toMatchObject({ weight: 135 });
    expect(planSnap.data()?.source).toBe("coach_generated");
  });
});
