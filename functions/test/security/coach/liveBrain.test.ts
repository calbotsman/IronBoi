import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { createRequire } from "node:module";
import {
  LIVE_SAFETY_LINE,
  RecordLiveTurnRequest,
  buildLiveSystemInstruction,
  liveBrainSetup,
  recordLiveTurn,
  runLiveTool,
} from "../../../src/coach/liveSession.js";
import { loadCoachContext } from "../../../src/coach/context.js";
import type { CoachConfig } from "../../../src/coach/prompt.js";
import { memoryFactPath, planAdjustmentProposalPath, profilePath } from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

const require = createRequire(import.meta.url);
const coach = require("../../../src/coach/ironboi-coach.v0.json") as CoachConfig;
const USER_ID = "live-brain-user-a";
let app: App;
let db: Firestore;

describe("live voice brain and memory", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });
  beforeEach(async () => {
    await Promise.allSettled([db.recursiveDelete(db.doc(`users/${USER_ID}`))]);
    await db.doc(profilePath(USER_ID)).set({ ...baseProfile, userId: USER_ID, preferredName: "Josh" });
  });
  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  it("saves a spoken exchange into the shared conversation, and the next session knows it", async () => {
    const turn = RecordLiveTurnRequest.parse({
      userText: "I only have dumbbells at home this week",
      coachText: "Got it, dumbbells only this week.",
      startedAt: "2026-10-12T18:00:00.000Z",
    });
    expect(await recordLiveTurn({ db, userId: USER_ID, turn, provider: null })).toEqual({ saved: true, stop: false });

    const context = await loadCoachContext(db, USER_ID, "general");
    const contents = context.sessionHistory.map((m) => `${m.role}:${m.content}:${m.status}`);
    expect(contents).toEqual([
      "user:I only have dumbbells at home this week:complete",
      "coach:Got it, dumbbells only this week.:complete",
    ]);

    const instruction = await buildLiveSystemInstruction({ db, coach, userId: USER_ID, today: "2026-10-12" });
    expect(instruction).toContain("I only have dumbbells at home this week");
    expect(instruction).toContain("\"preferredName\":\"Josh\"");
    expect(instruction).toContain("Never ask them for something they already told you");
    expect(instruction).not.toMatch(/<current_user_message>\s*<\/current_user_message>/);
  });

  it("stops on severe symptoms in the user's own words", async () => {
    const turn = RecordLiveTurnRequest.parse({
      userText: "my chest hurts and my left arm is numb",
      coachText: "Let's keep going with",
      startedAt: "2026-10-12T18:00:00.000Z",
      interrupted: true,
    });
    const result = await recordLiveTurn({ db, userId: USER_ID, turn, provider: null });
    expect(result).toMatchObject({ saved: true, stop: true, line: LIVE_SAFETY_LINE });
    const context = await loadCoachContext(db, USER_ID, "general");
    expect(context.sessionHistory.at(-1)).toMatchObject({ role: "coach", content: LIVE_SAFETY_LINE, riskLevel: "high" });
  });

  it("remembers what was said live, through the same memory tool", async () => {
    const result = await runLiveTool({
      db,
      userId: USER_ID,
      call: {
        name: "remember_user_fact",
        args: { category: "equipment", content: "Only dumbbells at home this week." },
        turnId: "t1",
        rawUserText: "I only have dumbbells at home this week",
      },
    });
    expect(result.ok).toBe(true);
    const fact = (await db.doc(memoryFactPath(USER_ID, String(result.factId))).get()).data();
    expect(fact).toMatchObject({ category: "equipment", state: "confirmed" });
  });

  it("won't accept a proposal in the same spoken turn that produced it", async () => {
    await db.doc(planAdjustmentProposalPath(USER_ID, "p-live")).set({
      userId: USER_ID, proposalId: "p-live", decision: "pending", liveTurnId: "t7",
      createdAt: "2026-10-12T18:00:00.000Z", source: "coach_chat", category: "time_limit", riskLevel: "low",
    });
    const sameTurn = await runLiveTool({
      db, userId: USER_ID,
      call: { name: "accept_plan_adjustment", args: { scope: "today" }, turnId: "t7", rawUserText: "yes do it" },
    });
    expect(sameTurn.ok).not.toBe(true);
    expect((await db.doc(planAdjustmentProposalPath(USER_ID, "p-live")).get()).get("decision")).toBe("pending");
  });

  it("locks tools and a resume handle into the session", () => {
    const setup = liveBrainSetup({ model: "gemini-3.8-live", voice: "Kore", instruction: "x", resumeHandle: "h1" });
    const names = setup.tools[0].functionDeclarations.map((t) => t.name);
    expect(names).toContain("remember_user_fact");
    expect(names).toContain("adapt_plan");
    expect(names).not.toContain("ask_follow_up_question");
    expect(setup.sessionResumption).toEqual({ handle: "h1" });
  });
});
