import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { buildCoachToolRegistry } from "../../../src/coach/toolRegistry.js";
import { executeTool } from "../../../src/tools/executor.js";
import { memoryFactPath, planAdjustmentProposalPath, profilePath, workoutPlanPath } from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

const USER_ID = "tool-registry-user-a";

let app: App;
let db: Firestore;

describe("coach tool registry", () => {
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

  // A Wednesday. Without a pinned date these tests read the wall clock, and
  // rest_of_week drops any dayPatch whose next occurrence falls past Sunday —
  // so every Friday-patch assertion below failed when the suite happened to
  // run on a Saturday or Sunday. Pin the date; never let the calendar decide
  // whether CI is green.
  const TEST_CLIENT_DATE = "2026-07-15";

  it("adapt_plan without scope analyzes but does NOT persist — needsScopeConfirmation instead", async () => {
    await db.doc(workoutPlanPath(USER_ID, "current")).set({
      userId: USER_ID,
      planId: "current",
      source: "coach_generated",
      updatedAt: "2026-07-06T00:00:00.000Z",
      days: {
        Mon: {
          name: "Push",
          muscles: ["Chest"],
          exercises: [
            { name: "Barbell Bench Press", sets: 3, reps: 8, weight: 95 },
            { name: "Incline Dumbbell Press", sets: 3, reps: 10, weight: 40 },
          ],
        },
      },
    });

    const registry = buildCoachToolRegistry(db, { latestPendingProposalId: null, clientDate: TEST_CLIENT_DATE });
    const result = (await executeTool(
      registry,
      "adapt_plan",
      { reason: "time_constraint", userNote: "Only have 15 minutes", dayKey: "Mon" },
      { authenticatedUserId: USER_ID },
    )) as Record<string, unknown>;

    expect(result).toMatchObject({
      ok: true,
      category: "time_limit",
      riskLevel: "low",
      requiresFollowUp: false,
      needsScopeConfirmation: true,
      proposalId: null,
      dayKey: "Mon",
    });

    // Nothing persisted — a scope-less call is a question, not a proposal.
    // Persisting here would orphan a pending doc per scope exchange.
    const pending = await db.collection(`users/${USER_ID}/planAdjustmentProposals`).get();
    expect(pending.empty).toBe(true);
  });

  it("adapt_plan does not flag needsScopeConfirmation once scope is supplied", async () => {
    await db.doc(workoutPlanPath(USER_ID, "current")).set({
      userId: USER_ID,
      planId: "current",
      source: "coach_generated",
      updatedAt: "2026-07-06T00:00:00.000Z",
      days: { Mon: { name: "Rest day", muscles: [], exercises: [] } },
    });

    const registry = buildCoachToolRegistry(db, { latestPendingProposalId: null, clientDate: TEST_CLIENT_DATE });
    const result = (await executeTool(
      registry,
      "adapt_plan",
      { reason: "missed_session", userNote: "Missed Monday", dayKey: "Mon", scope: "today" },
      { authenticatedUserId: USER_ID },
    )) as Record<string, unknown>;

    expect(result).toMatchObject({ ok: true, needsScopeConfirmation: false, category: "skip_or_reschedule" });

    const proposalSnap = await db.doc(planAdjustmentProposalPath(USER_ID, result.proposalId as string)).get();
    expect(proposalSnap.data()).toMatchObject({ appliesTo: { dayKey: "Mon", scope: "today" } });
  });

  it("adapt_plan rejects a model call carrying an identity-shaped field", async () => {
    const registry = buildCoachToolRegistry(db, { latestPendingProposalId: null, clientDate: TEST_CLIENT_DATE });
    await expect(
      executeTool(
        registry,
        "adapt_plan",
        { reason: "time_constraint", userNote: "note", userId: "someone-else" },
        { authenticatedUserId: USER_ID },
      ),
    ).rejects.toThrow(/identity-shaped fields not allowed/);
  });

  it("adapt_plan returns a validation error instead of throwing on malformed args", async () => {
    const registry = buildCoachToolRegistry(db, { latestPendingProposalId: null, clientDate: TEST_CLIENT_DATE });
    const result = (await executeTool(
      registry,
      "adapt_plan",
      { reason: "not_a_real_reason" },
      { authenticatedUserId: USER_ID },
    )) as Record<string, unknown>;

    expect(result).toEqual({ ok: false, error: "invalid_adapt_plan_args" });
  });

  it("locked pain proposal tells the model which fields were missing (self-correcting loop)", async () => {
    const registry = buildCoachToolRegistry(db, {
      latestPendingProposalId: null,
      clientDate: TEST_CLIENT_DATE,
      rawUserText: "my back hurts, can we update this weeks workouts",
    });
    // Pain adapt_plan WITHOUT painTriage or dayPatches — the live E2E
    // failure shape. Must persist high-risk AND explain itself so the
    // model can re-call with the missing fields in the same turn.
    const result = (await executeTool(
      registry,
      "adapt_plan",
      { reason: "pain_or_discomfort", userNote: "back hurts", scope: "rest_of_week" },
      { authenticatedUserId: USER_ID },
    )) as Record<string, unknown>;

    expect(result).toMatchObject({
      ok: true,
      category: "injury_pain",
      riskLevel: "high",
      proposalLocked: true,
    });
    expect(result.lockReason).toMatch(/painTriage/);
    expect(result.lockReason).toMatch(/dayPatches/);
    expect(result.lockReason).toMatch(/call adapt_plan again/);
  });

  it("locked pain proposal with severe raw text says do-not-retry instead", async () => {
    const registry = buildCoachToolRegistry(db, {
      latestPendingProposalId: null,
      clientDate: TEST_CLIENT_DATE,
      rawUserText: "sharp pain shooting down my leg",
    });
    const result = (await executeTool(
      registry,
      "adapt_plan",
      {
        reason: "pain_or_discomfort",
        userNote: "leg pain",
        scope: "rest_of_week",
        dayPatches: [
          {
            dayKey: "Fri",
            dayName: "Easy core",
            replacementExercises: [{ name: "Dead Bug", sets: 3, reps: 10, weight: 0 }],
          },
        ],
        painTriage: {
          redFlagsAsked: true,
          userReportsSevere: false,
          description: "says it is fine",
        },
      },
      { authenticatedUserId: USER_ID },
    )) as Record<string, unknown>;

    expect(result).toMatchObject({ ok: true, riskLevel: "high", proposalLocked: true });
    expect(result.lockReason).toMatch(/Do NOT retry/);
    expect(result.lockReason).not.toMatch(/call adapt_plan again/);
  });

  it("userReportsSevere=true fires do-not-retry even with all fields present", async () => {
    const registry = buildCoachToolRegistry(db, {
      latestPendingProposalId: null,
      clientDate: TEST_CLIENT_DATE,
      rawUserText: "my back hurts",
    });
    const result = (await executeTool(
      registry,
      "adapt_plan",
      {
        reason: "pain_or_discomfort",
        userNote: "back pain",
        scope: "rest_of_week",
        dayPatches: [
          {
            dayKey: "Fri",
            dayName: "Easy core",
            replacementExercises: [{ name: "Dead Bug", sets: 3, reps: 10, weight: 0 }],
          },
        ],
        painTriage: {
          redFlagsAsked: true,
          userReportsSevere: true,
          description: "user reports the pain is severe",
        },
      },
      { authenticatedUserId: USER_ID },
    )) as Record<string, unknown>;

    expect(result).toMatchObject({ ok: true, riskLevel: "high", proposalLocked: true });
    expect(result.lockReason).toMatch(/Do NOT retry/);
  });

  it("severe raw text + missing fields fires do-not-retry, never a retry promise", async () => {
    // The absolute screen means no retry can EVER make this appliable — the
    // lockReason must not promise one just because fields were missing.
    const registry = buildCoachToolRegistry(db, {
      latestPendingProposalId: null,
      clientDate: TEST_CLIENT_DATE,
      rawUserText: "sharp pain shooting down my leg",
    });
    const result = (await executeTool(
      registry,
      "adapt_plan",
      { reason: "pain_or_discomfort", userNote: "leg pain", scope: "rest_of_week" },
      { authenticatedUserId: USER_ID },
    )) as Record<string, unknown>;

    expect(result).toMatchObject({ ok: true, riskLevel: "high", proposalLocked: true });
    expect(result.lockReason).toMatch(/Do NOT retry/);
    expect(result.lockReason).not.toMatch(/call adapt_plan again/);
  });

  it("redFlagsAsked:false gets a guided hint instead of a dead-end validation error", async () => {
    const registry = buildCoachToolRegistry(db, {
      latestPendingProposalId: null,
      clientDate: TEST_CLIENT_DATE,
      rawUserText: "my back hurts",
    });
    const result = (await executeTool(
      registry,
      "adapt_plan",
      {
        reason: "pain_or_discomfort",
        userNote: "back pain",
        scope: "rest_of_week",
        painTriage: {
          redFlagsAsked: false,
          userReportsSevere: false,
          description: "haven't asked yet",
        },
      },
      { authenticatedUserId: USER_ID },
    )) as Record<string, unknown>;

    expect(result).toMatchObject({ ok: false, error: "invalid_adapt_plan_args" });
    expect(result.hint).toMatch(/ask them first/);
  });

  it("triage-cleared pain proposal carries no lock fields", async () => {
    const registry = buildCoachToolRegistry(db, {
      latestPendingProposalId: null,
      clientDate: TEST_CLIENT_DATE,
      rawUserText: "no sharp pain, no numbness, nothing radiating, just a dull ache",
      clientDate: "2026-07-15",
    });
    const result = (await executeTool(
      registry,
      "adapt_plan",
      {
        reason: "pain_or_discomfort",
        userNote: "dull ache in lower back",
        scope: "rest_of_week",
        dayPatches: [
          {
            dayKey: "Fri",
            dayName: "Back-safe core",
            replacementExercises: [{ name: "Bird Dog", sets: 3, reps: 10, weight: 0 }],
          },
        ],
        painTriage: {
          redFlagsAsked: true,
          userReportsSevere: false,
          description: "no sharp pain, no numbness, nothing radiating",
        },
      },
      { authenticatedUserId: USER_ID },
    )) as Record<string, unknown>;

    expect(result).toMatchObject({ ok: true, riskLevel: "low", requiresFollowUp: false });
    expect(result.proposalLocked).toBeUndefined();
    expect(result.lockReason).toBeUndefined();
  });

  it("ask_follow_up_question returns the rendered question", async () => {
    const registry = buildCoachToolRegistry(db, { latestPendingProposalId: null, clientDate: TEST_CLIENT_DATE });
    const result = await executeTool(
      registry,
      "ask_follow_up_question",
      { reason: "ambiguous_goal", question: "What's the main goal for this cycle?" },
      { authenticatedUserId: USER_ID },
    );

    expect(result).toEqual({ ok: true, renderedQuestion: "What's the main goal for this cycle?" });
  });

  it("remember_user_fact writes a confirmed, dated, evidence-backed fact keyed to the message", async () => {
    const registry = buildCoachToolRegistry(db, {
      latestPendingProposalId: null,
      clientDate: TEST_CLIENT_DATE,
      rawUserText: "tweaked my left shoulder on overhead press last tuesday, dull ache, no numbness",
      sourceMessageId: "ios_123",
    });
    const result = (await executeTool(
      registry,
      "remember_user_fact",
      { category: "safety_note", content: "Tweaked left shoulder on overhead press; dull ache, no numbness.", happenedOn: "2026-07-07" },
      { authenticatedUserId: USER_ID },
    )) as Record<string, unknown>;
    expect(result.ok).toBe(true);
    expect(result.factId).toBe("chat_ios_123_1");

    const doc = (await db.doc(memoryFactPath(USER_ID, "chat_ios_123_1")).get()).data();
    // A paraphrase is labelled as the coach's inference, not the user's words.
    expect(doc).toMatchObject({
      userId: USER_ID,
      factId: "chat_ios_123_1",
      category: "safety_note",
      content: "Tweaked left shoulder on overhead press; dull ache, no numbness.",
      source: "coach_inferred",
      state: "confirmed",
      confidence: 0.8,
      sourceMessageId: "ios_123",
      evidenceExcerpt: "tweaked my left shoulder on overhead press last tuesday, dull ache, no numbness",
      happenedOn: "2026-07-07",
      userEditable: true,
    });
    expect(doc?.until).toBeUndefined();
    expect(doc?.expiresAt).toBeUndefined();

    // A second fact in the same turn gets its own id instead of clobbering.
    const second = (await executeTool(
      registry,
      "remember_user_fact",
      { category: "equipment", content: "Hotel gym: dumbbells and a bench only.", until: "2026-07-19" },
      { authenticatedUserId: USER_ID },
    )) as Record<string, unknown>;
    expect(second.factId).toBe("chat_ios_123_2");
    expect((await db.doc(memoryFactPath(USER_ID, "chat_ios_123_2")).get()).get("until")).toBe("2026-07-19");

    // Content lifted verbatim from the message (case/punctuation aside) is user_stated at 1.
    const verbatim = (await executeTool(
      registry,
      "remember_user_fact",
      { category: "safety_note", content: "Dull ache, no numbness" },
      { authenticatedUserId: USER_ID },
    )) as Record<string, unknown>;
    const verbatimDoc = (await db.doc(memoryFactPath(USER_ID, String(verbatim.factId))).get()).data();
    expect(verbatimDoc).toMatchObject({ source: "user_stated", confidence: 1 });
  });

  it("remember_user_fact refuses past 100 live facts and tells the model to prune", async () => {
    const batch = db.batch();
    for (let index = 0; index < 100; index += 1) {
      batch.set(db.doc(memoryFactPath(USER_ID, `bulk_${index}`)), {
        userId: USER_ID, factId: `bulk_${index}`, category: "preference", content: `Pref ${index}`,
        source: "user_stated", confidence: 1, state: "confirmed", createdAt: "2026-07-01T00:00:00.000Z", userEditable: true,
        ...(index === 0 ? { userDeletedAt: "2026-07-02T00:00:00.000Z" } : {}),
      });
    }
    await batch.commit();
    const registry = buildCoachToolRegistry(db, { latestPendingProposalId: null, clientDate: TEST_CLIENT_DATE, sourceMessageId: "m9" });
    // 99 live (one soft-deleted) → one more is allowed…
    const ok = (await executeTool(registry, "remember_user_fact", { category: "preference", content: "Likes rows." }, { authenticatedUserId: USER_ID })) as Record<string, unknown>;
    expect(ok.ok).toBe(true);
    // …then the cap bites.
    const full = (await executeTool(registry, "remember_user_fact", { category: "preference", content: "Likes curls." }, { authenticatedUserId: USER_ID })) as Record<string, unknown>;
    expect(full).toMatchObject({ ok: false, error: "memory_full" });
    expect(typeof full.hint).toBe("string");
  });

  it("remember_user_fact rejects bad categories and dates without throwing, and never trusts an identity field", async () => {
    const registry = buildCoachToolRegistry(db, { latestPendingProposalId: null, clientDate: TEST_CLIENT_DATE, sourceMessageId: "m" });
    const bad = (await executeTool(
      registry,
      "remember_user_fact",
      { category: "diagnosis", content: "x", happenedOn: "last tuesday" },
      { authenticatedUserId: USER_ID },
    )) as Record<string, unknown>;
    expect(bad.ok).toBe(false);
    expect(bad.error).toBe("invalid_remember_user_fact_args");
    expect(typeof bad.hint).toBe("string");

    await expect(
      executeTool(
        registry,
        "remember_user_fact",
        { category: "preference", content: "likes lunges", userId: "someone-else" },
        { authenticatedUserId: USER_ID },
      ),
    ).rejects.toThrow(/identity/);
    const written = await db.collection(`users/someone-else/memoryFacts`).get();
    expect(written.empty).toBe(true);
  });

  it("forget_user_fact soft-deletes one of the user's own facts and reports unknown ids", async () => {
    await db.doc(memoryFactPath(USER_ID, "chat_m_1")).set({
      userId: USER_ID, factId: "chat_m_1", category: "preference", content: "Hates burpees.",
      source: "user_stated", confidence: 1, state: "confirmed", createdAt: "2026-07-01T00:00:00.000Z", userEditable: true,
    });
    const registry = buildCoachToolRegistry(db, { latestPendingProposalId: null, clientDate: TEST_CLIENT_DATE });
    const gone = (await executeTool(registry, "forget_user_fact", { factId: "chat_m_1" }, { authenticatedUserId: USER_ID })) as Record<string, unknown>;
    expect(gone).toEqual({ ok: true, factId: "chat_m_1" });
    expect(typeof (await db.doc(memoryFactPath(USER_ID, "chat_m_1")).get()).get("userDeletedAt")).toBe("string");

    // Already deleted, or never existed (including another user's id) → not found, no throw.
    const again = (await executeTool(registry, "forget_user_fact", { factId: "chat_m_1" }, { authenticatedUserId: USER_ID })) as Record<string, unknown>;
    expect(again).toEqual({ ok: false, error: "fact_not_found" });
    const other = (await executeTool(registry, "forget_user_fact", { factId: "chat_other_9" }, { authenticatedUserId: USER_ID })) as Record<string, unknown>;
    expect(other.ok).toBe(false);
  });
});
