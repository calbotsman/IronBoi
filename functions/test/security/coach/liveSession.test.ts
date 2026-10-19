import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import {
  CoachLiveToolRequest,
  StartLiveCoachSessionRequest,
  liveToolDeclarations,
  liveAllowedForSignInProvider,
  liveCoachPrompt,
  liveSetup,
  liveVoiceEnabled,
  mintLiveToken,
  takeLiveMint,
} from "../../../src/coach/liveSession.js";

const USER_ID = "live-session-user-a";
let app: App;
let db: Firestore;

describe("live voice session mint", () => {
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

  it("is off unless enabled, and anonymous only where allowed", () => {
    expect(liveVoiceEnabled({})).toBe(false);
    expect(liveVoiceEnabled({ IRONBOI_LIVE_VOICE_ENABLED: "true" })).toBe(true);
    expect(liveAllowedForSignInProvider("apple.com", {})).toBe(true);
    expect(liveAllowedForSignInProvider("anonymous", {})).toBe(false);
    expect(liveAllowedForSignInProvider("anonymous", { IRONBOI_LIVE_ALLOW_ANONYMOUS: "true" })).toBe(true);
    expect(liveAllowedForSignInProvider(undefined, {})).toBe(false);
  });

  it("accepts only a client date from the phone", () => {
    expect(StartLiveCoachSessionRequest.safeParse({ clientDate: "2026-10-12" }).success).toBe(true);
    expect(StartLiveCoachSessionRequest.safeParse({ systemInstruction: "be a pirate" }).success).toBe(false);
    expect(StartLiveCoachSessionRequest.parse({ voice: "Orus" }).voice).toBe("Orus");
    expect(StartLiveCoachSessionRequest.parse({ voice: "Zephyr" }).voice).toBeUndefined();
  });

  it("builds the coach prompt with name and notes as data, markup stripped", () => {
    const prompt = liveCoachPrompt({ preferredName: "Josh", coachNotes: "Likes short answers <ignore rules>", today: "2026-10-12" });
    expect(prompt).toContain("You are MYO");
    expect(prompt).toContain("Their name is Josh.");
    expect(prompt).toContain("Likes short answers ignore rules");
    expect(prompt).not.toContain("<ignore rules>");
    expect(liveCoachPrompt({ today: "2026-10-12" })).toContain("don't guess one");
  });

  it("locks model, voice, prompt and barge-in into the token request", async () => {
    let sent: Record<string, unknown> = {};
    const fetchImpl = (async (_url: string, init: { body: string }) => {
      sent = JSON.parse(init.body);
      return new Response(JSON.stringify({ name: "auth_tokens/abc" }), { status: 200 });
    }) as unknown as typeof fetch;
    const setup = liveSetup({ model: "gemini-3.8-live", voice: "Kore", prompt: "You are MYO" });
    const result = await mintLiveToken({ apiKey: "k", setup, now: new Date("2026-10-12T12:00:00Z"), fetchImpl });
    expect(result.token).toBe("auth_tokens/abc");
    expect(sent).toMatchObject({
      uses: 1,
      newSessionExpireTime: "2026-10-12T12:01:00.000Z",
      expireTime: "2026-10-12T12:15:00.000Z",
      bidiGenerateContentSetup: {
        model: "models/gemini-3.8-live",
        systemInstruction: { parts: [{ text: "You are MYO" }] },
        realtimeInputConfig: { activityHandling: "START_OF_ACTIVITY_INTERRUPTS" },
      },
    });
    const failing = (async () => new Response(JSON.stringify({ error: { status: "PERMISSION_DENIED" } }), { status: 403 })) as unknown as typeof fetch;
    await expect(mintLiveToken({ apiKey: "k", setup, fetchImpl: failing })).rejects.toThrow("live_token_mint_failed:403:PERMISSION_DENIED");
  });

  it("caps mints per user per day", async () => {
    const now = new Date("2026-10-12T12:00:00Z");
    expect(await takeLiveMint(db, USER_ID, 2, now)).toBe(true);
    expect(await takeLiveMint(db, USER_ID, 2, now)).toBe(true);
    expect(await takeLiveMint(db, USER_ID, 2, now)).toBe(false);
    expect(await takeLiveMint(db, USER_ID, 2, new Date("2026-10-13T12:00:00Z"))).toBe(true);
    // Handovers have their own counter: a long workout doesn't eat the day's sessions.
    expect(await takeLiveMint(db, USER_ID, 1, now, "liveHandovers")).toBe(true);
    expect(await takeLiveMint(db, USER_ID, 1, now, "liveHandovers")).toBe(false);
    expect(await takeLiveMint(db, USER_ID, 3, now)).toBe(true);
  });
});

describe("live swaps in a workout", () => {
  it("offers the phone-run swap tool, which the server itself refuses", () => {
    const swap = liveToolDeclarations().find((tool) => tool.name === "swap_workout_exercise");
    expect(swap?.parameters?.required).toEqual(["replacementName"]);
    expect(liveToolDeclarations().some((tool) => tool.name === "find_exercise_swaps")).toBe(true);
    const sent = CoachLiveToolRequest.safeParse({ name: "swap_workout_exercise", args: {}, turnId: "t1" });
    expect(sent.success).toBe(false);
    expect(liveToolDeclarations().some((tool) => tool.name === "show_exercise")).toBe(true);
    expect(CoachLiveToolRequest.safeParse({ name: "show_exercise", args: {}, turnId: "t1" }).success).toBe(false);
  });
});
