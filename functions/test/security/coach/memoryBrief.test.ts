import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { createRequire } from "node:module";
import {
  MEMORY_BRIEF_MAX_WORDS,
  buildMemoryBrief,
  buildMemoryBriefText,
  countWords,
  memoryBriefAge,
  rebuildMemoryBrief,
} from "../../../src/coach/memoryBrief.js";
import { RecordLiveTurnRequest, buildLiveSystemInstruction, recordLiveTurn } from "../../../src/coach/liveSession.js";
import { assembleCoachPrompt, type CoachConfig } from "../../../src/coach/prompt.js";
import { buildCoachContextBundle } from "../../../src/coach/contextBundle.js";
import { loadCoachContext } from "../../../src/coach/context.js";
import { coachNotesPath, memoryBriefPath, memoryFactPath, profilePath, workoutLogPath } from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

const require = createRequire(import.meta.url);
const coach = require("../../../src/coach/ironboi-coach.v0.json") as CoachConfig;
const TODAY = "2026-11-05";
/** The data half of a live instruction (the rules mention every tag by name). */
const dataOf = (instruction: string) => instruction.split("Everything about this client that you know")[1] ?? "";

function fact(i: number, extra: Record<string, unknown> = {}) {
  return {
    factId: `f${i}`,
    category: "preference",
    content: `Prefers variation number ${i} of a long-winded preference about warm-up music, rest timers and which bench they like to use`,
    source: "user_stated",
    confidence: 1,
    state: "confirmed",
    createdAt: new Date(Date.parse("2026-10-01T00:00:00Z") + i * 3_600_000).toISOString(),
    userEditable: true,
    ...extra,
  };
}

function log(date: string, name = "Barbell Bench Press") {
  return {
    sessionId: `s_${date}`,
    date,
    source: "manual",
    exercises: [{ name, sets: [{ reps: 8, loadKg: 70 }, { reps: 8, loadKg: 70 }, { reps: 6, loadKg: 72.5 }] }],
    postSessionNotes: `Felt solid on ${date}`,
    createdAt: `${date}T18:00:00.000Z`,
  };
}

const KNEE = fact(0, {
  factId: "knee",
  category: "safety_note",
  content: "Left knee hurts on deep squats; physio said no loaded deep flexion",
  createdAt: "2026-01-02T00:00:00.000Z",
});

describe("memory brief: budget and safety (pure)", () => {
  it("stays inside the word budget with 200 facts and 30 workouts, and says what it left out", () => {
    const facts = [KNEE, ...Array.from({ length: 200 }, (_, i) => fact(i + 1))];
    const logs = Array.from({ length: 30 }, (_, i) => log(new Date(Date.parse(`${TODAY}T00:00:00Z`) - i * 2 * 86_400_000).toISOString().slice(0, 10)));
    const brief = buildMemoryBriefText({ today: TODAY, facts, coachNotes: "Likes it short and direct. ".repeat(40), logs });
    expect(brief.words).toBeLessThanOrEqual(MEMORY_BRIEF_MAX_WORDS);
    expect(brief.words).toBe(countWords(brief.text));
    expect(brief.words).toBeGreaterThan(1_000);
    expect(brief.summarisedFactCount).toBeGreaterThan(0);
    expect(brief.text).toMatch(/\d+ older facts not shown \(preference \d+\)/);
    expect(brief.text).toContain(`Last session:\n${TODAY}:`);
    expect(brief.text).toContain("Earlier training:");
  });

  it("keeps the whole brief inside the budget even with 30 long injury notes, and keeps every one of them", () => {
    const injuries = Array.from({ length: 30 }, (_, i) => fact(1000 + i, {
      factId: `inj${i}`,
      category: "safety_note",
      content: `Injury ${i}: ${"a long description of what the physio said about loading, ranges and timelines ".repeat(6)}`,
    }));
    const facts = [...injuries, ...Array.from({ length: 200 }, (_, i) => fact(i + 1))];
    const logs = Array.from({ length: 30 }, (_, i) => log(new Date(Date.parse(`${TODAY}T00:00:00Z`) - i * 2 * 86_400_000).toISOString().slice(0, 10)));
    const brief = buildMemoryBriefText({ today: TODAY, facts, coachNotes: "Likes it short. ".repeat(80), logs });
    expect(brief.words).toBeLessThanOrEqual(MEMORY_BRIEF_MAX_WORDS);
    expect(brief.safetyFactCount).toBe(30);
    for (let i = 0; i < 30; i += 1) expect(brief.text).toContain(`[id inj${i}]`);
  });

  it("always includes safety and injury facts, even when the budget can't fit anything else", () => {
    const facts = [...Array.from({ length: 60 }, (_, i) => fact(i + 1)), KNEE];
    const brief = buildMemoryBriefText({ today: TODAY, facts, coachNotes: null, logs: [], maxWords: 5 });
    expect(brief.safetyFactCount).toBe(1);
    expect(brief.text).toContain("Left knee hurts on deep squats; physio said no loaded deep flexion");
    expect(brief.text).toContain("[id knee]");
    expect(brief.text).not.toContain("variation number 1 ");
  });

  it("treats an injury filed under another category as safety", () => {
    const shoulder = fact(1, { factId: "sh", category: "exercise_response", content: "Tweaked right shoulder benching" });
    const brief = buildMemoryBriefText({ today: TODAY, facts: [shoulder], coachNotes: null, logs: [], maxWords: 3 });
    expect(brief.safetyFactCount).toBe(1);
    expect(brief.text).toMatch(/Safety and injuries \(always included\):\n- Tweaked right shoulder benching/);
  });

  it("leaves out proposed, deleted and lapsed facts", () => {
    const brief = buildMemoryBriefText({
      today: TODAY,
      facts: [
        fact(1, { content: "PROPOSED one", state: "proposed" }),
        fact(2, { content: "DELETED one", userDeletedAt: "2026-11-01T00:00:00.000Z" }),
        fact(3, { content: "LAPSED travel", until: "2026-11-01" }),
        fact(4, { content: "Has kettlebells at home", category: "equipment" }),
      ],
      coachNotes: null,
      logs: [],
    });
    expect(brief.text).toContain("Has kettlebells at home");
    expect(brief.text).not.toMatch(/PROPOSED|DELETED|LAPSED/);
  });

  it("puts only the last 7 days under This week", () => {
    const brief = buildMemoryBriefText({ today: TODAY, facts: [], coachNotes: null, logs: [log("2026-11-04"), log("2026-11-01", "Deadlift"), log("2026-10-20", "Row")] });
    const week = brief.text.split("This week")[1].split("Earlier training")[0];
    expect(week).toContain("2026-11-01");
    expect(week).not.toContain("2026-10-20");
    expect(brief.text).toMatch(/Earlier training:\n1 sessions from 2026-10-20 to 2026-10-20; most trained: Row ×1/);
  });

  it("always shows the model how old it is", () => {
    expect(memoryBriefAge("2026-11-05T10:00:00.000Z", new Date("2026-11-05T13:00:00.000Z"))).toBe("built 2026-11-05 10:00 UTC, 3 hours ago");
    expect(memoryBriefAge("2026-11-01T10:00:00.000Z", new Date("2026-11-05T10:00:00.000Z"))).toBe("built 2026-11-01 10:00 UTC, 4 days ago");
  });

  it("leaves the text coach's prompt byte-identical when no brief is passed", () => {
    const context = {
      profile: null, recentFacts: [KNEE], recentLogs: [log(TODAY)], sessionHistory: [], pendingProposalCount: 0,
      recentPlanChanges: [], progressSummary: null, coachNotes: "notes", currentPlan: null,
    };
    const bundle = buildCoachContextBundle(context, { userId: "u", sessionId: "general", now: `${TODAY}T00:00:00.000Z` });
    const plain = assembleCoachPrompt(coach, bundle, "hi", { toolsEnabled: true });
    const same = assembleCoachPrompt(coach, bundle, "hi", { toolsEnabled: true, memoryBrief: undefined });
    expect(same).toEqual(plain);
    expect(plain.system).not.toContain("Memory brief:");
    expect(plain.userMessage).toContain("<recent_workouts>");
  });
});

const USER = "memory-brief-user-a";
const OTHER = "memory-brief-user-b";
let app: App;
let db: Firestore;

describe("memory brief: build, store and live voice (emulator)", () => {
  beforeAll(() => {
    app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });
  beforeEach(async () => {
    await Promise.allSettled([db.recursiveDelete(db.doc(`users/${USER}`)), db.recursiveDelete(db.doc(`users/${OTHER}`))]);
    await db.doc(profilePath(USER)).set({ ...baseProfile, userId: USER, preferredName: "Josh" });
  });
  afterAll(async () => {
    await Promise.all(getApps().map((activeApp) => deleteApp(activeApp)));
  });

  it("keeps an old injury that 120 newer facts would push out of the recent window", async () => {
    await db.doc(memoryFactPath(USER, "knee")).set({ ...KNEE, userId: USER });
    const batch = db.batch();
    for (let i = 1; i <= 120; i += 1) batch.set(db.doc(memoryFactPath(USER, `f${i}`)), { ...fact(i), userId: USER });
    await batch.commit();
    await db.doc(memoryFactPath(OTHER, "theirs")).set({ ...fact(1, { content: "OTHER USER secret" }), userId: OTHER });
    await db.doc(workoutLogPath(USER, "s1")).set({ ...log("2026-11-04"), userId: USER });
    await db.doc(coachNotesPath(USER)).set({ content: "Wants short answers, hates burpees." });

    const brief = await buildMemoryBrief(db, USER, new Date(`${TODAY}T12:00:00Z`), TODAY);
    expect(brief.text).toContain("Left knee hurts on deep squats");
    expect(brief.text).toContain("Wants short answers, hates burpees.");
    expect(brief.text).toContain("Last session:\n2026-11-04:");
    expect(brief.text).not.toContain("OTHER USER");
    expect(brief.words).toBeLessThanOrEqual(MEMORY_BRIEF_MAX_WORDS);
  });

  it("stores the brief at derivedSummaries/memory_brief", async () => {
    await db.doc(memoryFactPath(USER, "knee")).set({ ...KNEE, userId: USER });
    const stored = await rebuildMemoryBrief(db, USER, "test", new Date(`${TODAY}T12:00:00Z`));
    const snap = await db.doc(memoryBriefPath(USER)).get();
    expect(snap.get("schema")).toBe("memory_brief.v1");
    expect(snap.get("text")).toBe(stored?.text);
    expect(snap.get("builtAt")).toBe(`${TODAY}T12:00:00.000Z`);
  });

  it("a delete never recreates a brief that reset already removed", async () => {
    await db.doc(memoryFactPath(USER, "knee")).set({ ...KNEE, userId: USER });
    expect(await rebuildMemoryBrief(db, USER, "test", new Date(), { updateOnly: true })).toBeNull();
    expect((await db.doc(memoryBriefPath(USER)).get()).exists).toBe(false);
    await rebuildMemoryBrief(db, USER, "test");
    expect(await rebuildMemoryBrief(db, USER, "test", new Date(), { updateOnly: true })).not.toBeNull();
  });

  it("a live conversation rebuilds the brief, at most every 10 minutes", async () => {
    await db.doc(memoryFactPath(USER, "knee")).set({ ...KNEE, userId: USER });
    const turn = RecordLiveTurnRequest.parse({ userText: "hey", coachText: "Hey Josh.", startedAt: `${TODAY}T10:00:00.000Z` });
    await recordLiveTurn({ db, userId: USER, turn, provider: null, now: new Date(`${TODAY}T10:00:00Z`) });
    expect((await db.doc(memoryBriefPath(USER)).get()).get("builtAt")).toBe(`${TODAY}T10:00:00.000Z`);
    await recordLiveTurn({ db, userId: USER, turn, provider: null, now: new Date(`${TODAY}T10:05:00Z`) });
    expect((await db.doc(memoryBriefPath(USER)).get()).get("builtAt")).toBe(`${TODAY}T10:00:00.000Z`);
    await recordLiveTurn({ db, userId: USER, turn, provider: null, now: new Date(`${TODAY}T10:11:00Z`) });
    expect((await db.doc(memoryBriefPath(USER)).get()).get("builtAt")).toBe(`${TODAY}T10:11:00.000Z`);
  });

  it("live voice: the server's brief, with its age, replaces raw memory sections", async () => {
    await db.doc(memoryFactPath(USER, "knee")).set({ ...KNEE, userId: USER });
    await db.doc(memoryFactPath(USER, "kb")).set({ ...fact(1, { factId: "kb", category: "equipment", content: "Has kettlebells at home" }), userId: USER });
    await rebuildMemoryBrief(db, USER, "test", new Date(`${TODAY}T09:00:00Z`));
    const instruction = await buildLiveSystemInstruction({ db, coach, userId: USER, today: TODAY, now: new Date(`${TODAY}T12:00:00Z`), env: {} });
    expect(instruction).toContain("<memory_brief>");
    expect(instruction).toContain("Has kettlebells at home");
    expect(instruction).toContain("built 2026-11-05 09:00 UTC, 3 hours ago");
    expect(dataOf(instruction)).not.toContain("<recent_workouts>");
    expect(dataOf(instruction)).not.toContain("<coach_notes>");
    // Safety facts are read fresh into <memory_facts> as well.
    expect(instruction).toMatch(/<memory_facts>\[.*Left knee hurts/);
  });

  it("live voice: with the brief on the phone, the server reads no memory but still carries safety facts", async () => {
    await db.doc(memoryFactPath(USER, "knee")).set({ ...KNEE, userId: USER });
    await db.doc(memoryFactPath(USER, "kb")).set({ ...fact(1, { factId: "kb", category: "equipment", content: "Has kettlebells at home" }), userId: USER });
    await db.doc(memoryFactPath(USER, "p")).set({ ...fact(2, { factId: "p", state: "proposed" }), userId: USER });
    const instruction = await buildLiveSystemInstruction({ db, coach, userId: USER, today: TODAY, memoryBriefOnPhone: true, env: {} });
    expect(instruction).toContain("The brief arrives as the first [app] line");
    expect(dataOf(instruction)).not.toContain("<memory_brief>");
    expect(instruction).not.toContain("Has kettlebells at home");
    expect(instruction).toMatch(/<memory_facts>\[.*Left knee hurts/);
    expect(instruction).toContain("<pending_proposal_count>1</pending_proposal_count>");
  });

  it("live voice: builds and stores a brief on the spot when none exists yet", async () => {
    await db.doc(memoryFactPath(USER, "knee")).set({ ...KNEE, userId: USER });
    const instruction = await buildLiveSystemInstruction({ db, coach, userId: USER, today: TODAY, env: {} });
    expect(instruction).toContain("<memory_brief>");
    expect((await db.doc(memoryBriefPath(USER)).get()).exists).toBe(true);
  });

  it("live voice: IRONBOI_LIVE_MEMORY_BRIEF=off goes back to the raw sections", async () => {
    await db.doc(memoryFactPath(USER, "kb")).set({ ...fact(1, { factId: "kb", category: "equipment", content: "Has kettlebells at home" }), userId: USER });
    const instruction = await buildLiveSystemInstruction({ db, coach, userId: USER, today: TODAY, env: { IRONBOI_LIVE_MEMORY_BRIEF: "off" } });
    expect(instruction).not.toContain("Memory brief:");
    expect(dataOf(instruction)).toContain("<recent_workouts>");
    expect(instruction).toContain("Has kettlebells at home");
  });

  it("parity: live voice remembers at least what the text coach does", async () => {
    await db.doc(memoryFactPath(USER, "knee")).set({ ...KNEE, userId: USER });
    for (let i = 1; i <= 25; i += 1) await db.doc(memoryFactPath(USER, `f${i}`)).set({ ...fact(i, { content: `Fact number ${i} about them` }), userId: USER });
    const text = buildCoachContextBundle(await loadCoachContext(db, USER, "general"), { userId: USER, sessionId: "general", today: TODAY });
    const instruction = await buildLiveSystemInstruction({ db, coach, userId: USER, today: TODAY, env: {} });
    for (const remembered of text.memoryFacts) expect(instruction).toContain(remembered.content);
  });
});
