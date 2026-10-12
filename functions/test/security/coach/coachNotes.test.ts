import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { COACH_NOTES_EVERY_TURNS, cleanCoachNotes, refreshCoachNotesIfDue } from "../../../src/coach/coachNotes.js";
import type { CoachModelProvider } from "../../../src/coach/modelProvider.js";
import { coachNotesPath } from "../../../src/paths.js";

const USER_ID = "coach-notes-user-a";
let app: App;
let db: Firestore;

function fakeProvider(reply: string, calls: string[]): CoachModelProvider {
  return {
    provider: "openrouter",
    model: "test",
    async generateCoachReply({ userContent }) {
      calls.push(userContent);
      return { content: reply, usage: { inputTokens: 1, outputTokens: 1 }, toolCalls: [] };
    },
  };
}

const conversation = [
  { role: "user", content: "MYO, it's Josh. Keep it short, I hate long explanations." },
  { role: "coach", content: "Got it, Josh." },
  { role: "user", content: "Shoulder press felt heavy today" },
  { role: "coach", content: "Drop five pounds next set." },
  { role: "user", content: "Can I do these seated?" },
];

describe("coach notes", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });
  beforeEach(async () => {
    await Promise.allSettled([db.recursiveDelete(db.doc(`users/${USER_ID}`))]);
  });
  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  it("strips markup, caps length, and rejects empty output", () => {
    expect(cleanCoachNotes("<coach_notes>Who they are: Josh</coach_notes> and more")).toBe("Who they are: Josh and more");
    expect(cleanCoachNotes("x".repeat(5000))?.length).toBe(1200);
    expect(cleanCoachNotes("  ")).toBeNull();
  });

  it("writes first notes once there's enough conversation, then waits N turns", async () => {
    const calls: string[] = [];
    const provider = fakeProvider("Who they are: Josh.\nHow to coach them: short answers.", calls);
    const args = { db, provider, userId: USER_ID, profile: null, facts: [], conversation };

    await refreshCoachNotesIfDue(args);
    expect(calls).toHaveLength(1);
    expect(calls[0]).toContain("(none yet)");
    expect((await db.doc(coachNotesPath(USER_ID)).get()).data()).toMatchObject({
      content: "Who they are: Josh.\nHow to coach them: short answers.",
      turnsSince: 0,
    });

    for (let i = 1; i < COACH_NOTES_EVERY_TURNS; i += 1) await refreshCoachNotesIfDue(args);
    expect(calls).toHaveLength(1);
    await refreshCoachNotesIfDue(args);
    expect(calls).toHaveLength(2);
    expect(calls[1]).toContain("Who they are: Josh.");
  });

  it("never throws when the model fails", async () => {
    const provider: CoachModelProvider = {
      provider: "openrouter",
      model: "test",
      async generateCoachReply() { throw new Error("402"); },
    };
    await expect(refreshCoachNotesIfDue({ db, provider, userId: USER_ID, profile: null, facts: [], conversation })).resolves.toBeUndefined();
    expect((await db.doc(coachNotesPath(USER_ID)).get()).get("content")).toBeUndefined();
  });
});
