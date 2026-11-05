import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { forgetTurnRecovery } from "../../../src/health/recovery.js";
import { coachSessionMessagePath } from "../../../src/paths.js";

const USER = "health-recovery-user";
const PATH = coachSessionMessagePath(USER, "general", "m1");

let app: App;
let db: Firestore;

describe("forgetTurnRecovery", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });

  beforeEach(async () => {
    await db.recursiveDelete(db.doc(`users/${USER}`));
  });

  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  it("removes recovery from the stored message and keeps the rest", async () => {
    const data = {
      role: "user",
      content: "ready",
      liveContext: {
        delivery: { speaksReplies: true },
        recovery: { restingHr: 63, hrvMs: 31, sleepHours: 5.4, signals: ["hrv_low", "sleep_short"], low: true },
      },
    };
    await db.doc(PATH).set(data);
    expect(await forgetTurnRecovery(db, PATH, data)).toBe(true);
    const stored = (await db.doc(PATH).get()).data();
    expect(stored?.liveContext?.recovery).toBeUndefined();
    expect(stored?.liveContext?.delivery?.speaksReplies).toBe(true);
    expect(stored?.content).toBe("ready");
  });

  it("does nothing without recovery, and never throws", async () => {
    expect(await forgetTurnRecovery(db, PATH, { liveContext: { delivery: {} } })).toBe(false);
    expect(await forgetTurnRecovery(db, PATH, undefined)).toBe(false);
    // The doc doesn't exist: update fails, the turn must not.
    expect(await forgetTurnRecovery(db, PATH, { liveContext: { recovery: { low: false } } })).toBe(false);
  });
});
