#!/usr/bin/env node
// Live end-to-end smoke harness against the REAL deployed ironboi-staging
// backend (real Gemini tool loop, IRONBOI_COACH_TOOL_LOOP_ENABLED=true).
//
// What it does, as a throwaway ANONYMOUS user:
//   A. bootstrap  — anon sign-up, minimal profile, regenerate plan
//   B. plain chat — one coach turn, assert a reply doc lands
//   C. injury arc — triage question -> low-risk proposal w/ dayPatches ->
//                   chat-accept -> plan mutated (dailyOverrides)
//   D. recovery   — coachFollowUps doc scheduled after the injury accept
//   E. cleanup    — deleteAccount callable wipes the user; reads 404/403
//
// Assertions are STATE-BASED (Firestore docs via REST), never exact model
// text — Gemini is nondeterministic. HARD failures fail the run (exit 1);
// SOFT warnings are reported but don't.
//
// Budget: <= 12 coach messages, 90s per turn, 15 min wall clock.
//
// Zero dependencies. Node >= 20 (global fetch). Run: node scripts/e2e-staging-smoke.mjs
//
// The Firebase Web API key is the PUBLIC staging client key (shipped inside
// the iOS app bundle) — not a secret. Override with MYO_E2E_API_KEY.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const PROJECT_ID = "ironboi-staging";
const FUNCTIONS_BASE = `https://us-central1-${PROJECT_ID}.cloudfunctions.net`;
const FIRESTORE_BASE = `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents`;
const IDENTITY_SIGNUP = "https://identitytoolkit.googleapis.com/v1/accounts:signUp";

const TURN_TIMEOUT_MS = 90_000;
const POLL_INTERVAL_MS = 3_000;
const MAX_MESSAGES = 12;
const WALL_CLOCK_CAP_MS = 15 * 60_000;
const SESSION_ID = "general";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

function readApiKey() {
  if (process.env.MYO_E2E_API_KEY) return process.env.MYO_E2E_API_KEY;
  const candidates = [
    "ios/IronBoi/IronBoi/Firebase/GoogleService-Info-Staging.plist",
    "ios/IronBoi/IronBoi/GoogleService-Info.plist",
  ];
  for (const rel of candidates) {
    try {
      const plist = readFileSync(join(repoRoot, rel), "utf8");
      const match = plist.match(/<key>API_KEY<\/key>\s*<string>([^<]+)<\/string>/);
      if (match) return match[1];
    } catch {
      // try next candidate
    }
  }
  throw new Error(
    "Could not find the staging Firebase API key. Set MYO_E2E_API_KEY or restore the staging GoogleService-Info plist.",
  );
}

const API_KEY = readApiKey();

// ---------------------------------------------------------------------------
// State + report plumbing
// ---------------------------------------------------------------------------

const startedAtMs = Date.now();
const state = {
  idToken: null,
  uid: null,
  messagesSent: 0,
  turns: [], // { label, messageId, elapsedMs, status, toolNames }
};

/** @type {{name:string, checks:Array<{level:"HARD"|"SOFT"|"INFO", pass:boolean, detail:string}>, elapsedMs:number}[]} */
const scenarios = [];
let currentScenario = null;

function beginScenario(name) {
  currentScenario = { name, checks: [], startMs: Date.now(), elapsedMs: 0 };
  scenarios.push(currentScenario);
  log(`\n=== ${name} ===`);
}

function endScenario() {
  if (currentScenario) currentScenario.elapsedMs = Date.now() - currentScenario.startMs;
  currentScenario = null;
}

function check(level, pass, detail) {
  currentScenario.checks.push({ level, pass, detail });
  const tag = pass ? "PASS" : level === "HARD" ? "FAIL" : "WARN";
  log(`  [${level} ${tag}] ${detail}`);
  return pass;
}

function info(detail) {
  currentScenario?.checks.push({ level: "INFO", pass: true, detail });
  log(`  [INFO] ${detail}`);
}

function log(...args) {
  console.error(...args); // progress goes to stderr; the report goes to stdout
}

class BudgetExceededError extends Error {}

function assertBudget() {
  if (Date.now() - startedAtMs > WALL_CLOCK_CAP_MS) {
    throw new BudgetExceededError(`Wall-clock cap of ${WALL_CLOCK_CAP_MS / 60000} min exceeded`);
  }
  if (state.messagesSent >= MAX_MESSAGES) {
    throw new BudgetExceededError(`Message budget of ${MAX_MESSAGES} exhausted`);
  }
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

async function httpJson(url, { method = "GET", headers = {}, body } = {}) {
  const response = await fetch(url, {
    method,
    headers: { "Content-Type": "application/json", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let json = null;
  try {
    json = await response.json();
  } catch {
    // non-JSON body (rare); leave null
  }
  return { status: response.status, json };
}

/** POST {data: payload} to an *Http onRequest function with Bearer auth. */
async function callFunctionHttp(name, payload) {
  const { status, json } = await httpJson(`${FUNCTIONS_BASE}/${name}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${state.idToken}` },
    body: { data: payload },
  });
  return { status, json };
}

/** Firestore REST: get a document. Returns {status, doc} where doc is decoded or null. */
async function fsGetDoc(path) {
  const { status, json } = await httpJson(`${FIRESTORE_BASE}/${path}`, {
    headers: { Authorization: `Bearer ${state.idToken}` },
  });
  return { status, doc: status === 200 ? decodeFsDoc(json) : null };
}

/** Firestore REST: list a collection (single page, up to 100 docs). */
async function fsListCollection(path) {
  const { status, json } = await httpJson(`${FIRESTORE_BASE}/${path}?pageSize=100`, {
    headers: { Authorization: `Bearer ${state.idToken}` },
  });
  const docs = status === 200 && Array.isArray(json?.documents)
    ? json.documents.map(decodeFsDoc)
    : [];
  return { status, docs };
}

function decodeFsDoc(raw) {
  const data = decodeFsFields(raw?.fields ?? {});
  data.__docId = typeof raw?.name === "string" ? raw.name.split("/").pop() : undefined;
  return data;
}

function decodeFsFields(fields) {
  return Object.fromEntries(
    Object.entries(fields).map(([key, value]) => [key, decodeFsValue(value)]),
  );
}

function decodeFsValue(value) {
  if (value == null || typeof value !== "object") return value;
  if ("stringValue" in value) return value.stringValue;
  if ("booleanValue" in value) return value.booleanValue;
  if ("integerValue" in value) return Number(value.integerValue);
  if ("doubleValue" in value) return value.doubleValue;
  if ("timestampValue" in value) return value.timestampValue;
  if ("nullValue" in value) return null;
  if ("mapValue" in value) return decodeFsFields(value.mapValue?.fields ?? {});
  if ("arrayValue" in value) return (value.arrayValue?.values ?? []).map(decodeFsValue);
  return value;
}

/**
 * Poll until predicate() returns a truthy value.
 * Returns the value, or null on timeout. Respects the wall-clock cap.
 */
async function pollUntil(predicate, timeoutMs, intervalMs = POLL_INTERVAL_MS) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (Date.now() - startedAtMs > WALL_CLOCK_CAP_MS) {
      throw new BudgetExceededError("Wall-clock cap exceeded while polling");
    }
    const value = await predicate();
    if (value) return value;
    if (Date.now() >= deadline) return null;
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
}

// ---------------------------------------------------------------------------
// Domain helpers
// ---------------------------------------------------------------------------

function todayLocalISO() {
  const now = new Date();
  const y = now.getFullYear();
  const m = String(now.getMonth() + 1).padStart(2, "0");
  const d = String(now.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

async function signUpAnonymous() {
  const { status, json } = await httpJson(`${IDENTITY_SIGNUP}?key=${API_KEY}`, {
    method: "POST",
    body: { returnSecureToken: true },
  });
  if (status !== 200 || !json?.idToken || !json?.localId) {
    throw new Error(
      `Anonymous sign-up failed (HTTP ${status}): ${JSON.stringify(json?.error ?? json).slice(0, 300)}`,
    );
  }
  state.idToken = json.idToken;
  state.uid = json.localId;
}

/**
 * Send one coach chat message via sendCoachMessageHttp (iOS AppModel shape)
 * and poll for the `<messageId>_coach` reply doc to reach a terminal status.
 * Returns { messageId, reply, elapsedMs } — reply is null on poll timeout.
 */
async function sendCoachTurn(label, content) {
  assertBudget();
  const turnStart = Date.now();
  const messageId = `ios_${Date.now()}`;
  const now = new Date().toISOString();

  const { status, json } = await callFunctionHttp("sendCoachMessageHttp", {
    sessionId: SESSION_ID,
    messageId,
    content,
    timestamp: now,
    startedAt: now,
    toolCallIds: [],
    clientDate: todayLocalISO(),
  });
  state.messagesSent += 1;

  if (status !== 200 || json?.ok !== true) {
    const turn = {
      label, messageId, elapsedMs: Date.now() - turnStart,
      status: `send_failed_http_${status}`, toolNames: [],
    };
    state.turns.push(turn);
    return { messageId, reply: null, sendStatus: status, elapsedMs: turn.elapsedMs };
  }

  const replyPath = `users/${state.uid}/coachSessions/${SESSION_ID}/messages/${messageId}_coach`;
  const reply = await pollUntil(async () => {
    const { doc } = await fsGetDoc(replyPath);
    if (doc && ["complete", "blocked", "error"].includes(doc.status)) return doc;
    return null;
  }, TURN_TIMEOUT_MS);

  const turn = {
    label,
    messageId,
    elapsedMs: Date.now() - turnStart,
    status: reply?.status ?? "reply_timeout",
    errorCode: reply?.errorCode,
    toolNames: reply?.toolNames ?? [],
  };
  state.turns.push(turn);
  log(
    `  turn "${label}": ${turn.status} in ${(turn.elapsedMs / 1000).toFixed(1)}s` +
      (turn.errorCode ? ` (errorCode=${turn.errorCode})` : "") +
      (turn.toolNames.length ? ` (tools: ${turn.toolNames.join(", ")})` : ""),
  );
  return { messageId, reply, sendStatus: status, elapsedMs: turn.elapsedMs };
}

/**
 * sendCoachTurn with a single retry when the turn lands status=error —
 * an "error" doc means the model call died (timeout/orchestration error),
 * so the user never got a reply; one retry keeps a transient provider
 * blip from failing the whole arc. Budget caps still apply.
 */
async function sendCoachTurnWithRetry(label, content) {
  const first = await sendCoachTurn(label, content);
  if (first.reply?.status !== "error") return first;
  // An error doc at ~6.5s means the backend already burned its own 3-attempt
  // transient-retry window (1.5s+3s backoff) against Gemini — retrying
  // immediately just hits the same overload/quota window. Cool down first.
  info(`turn "${label}" errored (${first.reply.errorCode ?? "unknown"}) — cooling down 25s, then retrying once`);
  await new Promise((resolve) => setTimeout(resolve, 25_000));
  return sendCoachTurn(`${label}-retry`, content);
}

async function listPendingProposals() {
  const { docs } = await fsListCollection(`users/${state.uid}/planAdjustmentProposals`);
  return docs.filter((doc) => doc.decision === "pending");
}

function proposalDayPatches(proposal) {
  const patches = proposal?.proposedPlanPatch?.dayPatches;
  return Array.isArray(patches) ? patches : [];
}

function looksLikeQuestion(text) {
  return typeof text === "string" && text.includes("?");
}

// ---------------------------------------------------------------------------
// Scenarios
// ---------------------------------------------------------------------------

async function scenarioAuthAndBootstrap() {
  beginScenario("A. Auth + plan bootstrap");
  try {
    await signUpAnonymous();
    check("HARD", true, `anonymous sign-up ok (uid ${state.uid})`);
  } catch (error) {
    check("HARD", false, `anonymous sign-up failed: ${error.message}`);
    endScenario();
    return false;
  }

  // Fresh anon user must have no plan yet.
  const before = await fsGetDoc(`users/${state.uid}/workoutPlans/current`);
  check(
    "HARD",
    before.status === 404,
    `fresh user has no workoutPlans/current (HTTP ${before.status})`,
  );

  // regenerateWorkoutPlanHttp requires a profile — create a minimal valid one
  // (UserHealthProfile contract; createdAt/updatedAt/userId are server-injected).
  const profileRes = await callFunctionHttp("upsertProfileHttp", {
    ageYears: 30,
    sexOrGender: "prefer_not_to_say",
    goals: ["general_fitness"],
    trainingExperience: "beginner",
    schedule: { daysPerWeek: 3, preferredDays: [] },
    preferences: {},
  });
  if (!check("HARD", profileRes.status === 200 && profileRes.json?.ok === true,
    `upsertProfileHttp accepted minimal profile (HTTP ${profileRes.status}${profileRes.json?.error ? `, ${profileRes.json.error}` : ""})`)) {
    endScenario();
    return false;
  }

  const regenRes = await callFunctionHttp("regenerateWorkoutPlanHttp", {});
  check("HARD", regenRes.status === 200 && regenRes.json?.ok === true,
    `regenerateWorkoutPlanHttp ok (HTTP ${regenRes.status}${regenRes.json?.error ? `, ${regenRes.json.error}` : ""})`);

  const plan = await pollUntil(async () => {
    const { doc } = await fsGetDoc(`users/${state.uid}/workoutPlans/current`);
    return doc && doc.days && Object.keys(doc.days).length > 0 ? doc : null;
  }, 30_000);
  const ok = check("HARD", Boolean(plan),
    plan
      ? `workoutPlans/current exists with days [${Object.keys(plan.days).join(", ")}]`
      : "workoutPlans/current never appeared after regenerate");
  endScenario();
  return ok;
}

async function scenarioPlainChat() {
  beginScenario("B. Plain chat turn");
  const { reply, sendStatus } = await sendCoachTurnWithRetry("plain-chat", "what should I focus on this week?");
  if (sendStatus !== 200) {
    check("HARD", false, `sendCoachMessageHttp returned HTTP ${sendStatus}`);
    endScenario();
    return false;
  }
  check("HARD", true, "sendCoachMessageHttp returned 200");
  const terminalOk = reply && ["complete", "blocked"].includes(reply.status);
  check("HARD", Boolean(terminalOk),
    reply
      ? `coach reply doc status=${reply.status}${reply.errorCode ? ` errorCode=${reply.errorCode}` : ""}`
      : `no coach reply doc within ${TURN_TIMEOUT_MS / 1000}s`);
  check("HARD", Boolean(reply && typeof reply.content === "string" && reply.content.trim().length > 0),
    reply ? `reply content non-empty (${reply.content?.length ?? 0} chars)` : "no reply content");
  if (reply?.modelProvider) info(`model: ${reply.modelProvider}/${reply.model ?? "?"}`);
  endScenario();
  return Boolean(terminalOk);
}

async function scenarioInjuryArc() {
  beginScenario("C. Injury triage arc");

  // --- Turn 1: raise the injury. Triage must NOT be skipped. ---
  const turn1 = await sendCoachTurnWithRetry(
    "injury-open",
    "my back hurts, can we update this weeks workouts",
  );
  if (!check("HARD", Boolean(turn1.reply && ["complete", "blocked"].includes(turn1.reply.status)),
    turn1.reply
      ? `injury turn 1 reply status=${turn1.reply.status}`
      : "injury turn 1: no coach reply within 90s")) {
    endScenario();
    return { proposalId: null };
  }

  const pendingAfterTriageQuestion = await listPendingProposals();
  const lowRiskEarly = pendingAfterTriageQuestion.filter((p) => p.riskLevel === "low");
  check("HARD", lowRiskEarly.length === 0,
    lowRiskEarly.length === 0
      ? "no low-risk pending proposal before triage completed (triage not skipped)"
      : `TRIAGE SKIPPED: low-risk pending proposal ${lowRiskEarly[0].__docId} exists before red-flag answers`);
  check("SOFT", looksLikeQuestion(turn1.reply.content) &&
    /sharp|numb|tingl|radiat|shooting|red.?flag|sever/i.test(turn1.reply.content),
    "coach asked red-flag screening questions before adjusting");

  // --- Turn 2: answer the red flags, ask for the adjustment. ---
  const turn2 = await sendCoachTurnWithRetry(
    "injury-triage-answer",
    "no sharp pain, no numbness, nothing radiating, just a dull ache from yesterday — adjust this week please",
  );
  check("HARD", Boolean(turn2.reply && ["complete", "blocked"].includes(turn2.reply.status)),
    turn2.reply
      ? `injury turn 2 reply status=${turn2.reply.status}`
      : "injury turn 2: no coach reply within 90s");

  let lowPending = (await listPendingProposals()).filter((p) => p.riskLevel === "low");

  // Allowed one extra nudge turn, for two observed staging realities:
  //   1. On weekend runs "this week" can legitimately have no remaining
  //      training days (rest_of_week keeps patches only through Sunday).
  //   2. Large multi-day adapt_plan tool calls frequently die with
  //      coach_orchestration_error (see PR notes) — a single-day ask is a
  //      much smaller function call and survives.
  // The nudge RESTATES the red-flag answers so the model can populate
  // painTriage (without it the proposal lands riskLevel=high, which chat
  // accept refuses), and asks for one day so the tool call stays small.
  if (lowPending.length === 0) {
    info("no low-risk pending proposal after triage answer — sending one nudge turn");
    const nudge = await sendCoachTurnWithRetry(
      "injury-nudge",
      "just to confirm: no sharp pain, no numbness, nothing radiating — only a dull ache. please make my next training day back-friendly; adjusting just that one day is fine",
    );
    check("SOFT", Boolean(nudge.reply && nudge.reply.status === "complete"),
      nudge.reply ? `nudge turn status=${nudge.reply.status}` : "nudge turn: no reply within 90s");
    lowPending = (await listPendingProposals()).filter((p) => p.riskLevel === "low");
  }

  const proposal = lowPending[0] ?? null;
  check("HARD", Boolean(proposal),
    proposal
      ? `low-risk PENDING proposal created: ${proposal.__docId} (category=${proposal.category}, scope=${proposal.appliesTo?.scope ?? "unset"})`
      : "no low-risk PENDING plan-adjustment proposal after triage answers (within 2 turns)");
  if (!proposal) {
    // Diagnostic: a pending-but-not-low proposal usually means the model
    // called adapt_plan WITHOUT painTriage despite clean red-flag answers,
    // so the proposal stayed high-risk and chat accept would refuse it.
    const allPending = await listPendingProposals();
    for (const p of allPending) {
      info(`pending proposal ${p.__docId}: riskLevel=${p.riskLevel}, category=${p.category}, scope=${p.appliesTo?.scope ?? "unset"}, requiresFollowUp=${p.requiresFollowUp}`);
    }
    endScenario();
    return { proposalId: null };
  }

  const patches = proposalDayPatches(proposal);
  check("HARD", patches.length > 0,
    patches.length > 0
      ? `proposal carries ${patches.length} dayPatch(es): [${patches.map((p) => p.dayKey).join(", ")}]`
      : "proposal has no dayPatches (empty proposedPlanPatch.dayPatches)");
  check("SOFT", proposal.category === "injury_pain",
    `proposal category is injury_pain (got: ${proposal.category})`);
  info(`recoveryDays=${proposal.recoveryDays ?? "unset"} requiresFollowUp=${proposal.requiresFollowUp}`);

  // --- Turn 3: accept via chat. ---
  const planBefore = (await fsGetDoc(`users/${state.uid}/workoutPlans/current`)).doc;
  const planSnapshotBefore = JSON.stringify({
    days: planBefore?.days ?? null,
    dailyOverrides: planBefore?.dailyOverrides ?? null,
  });

  const acceptTurn = await sendCoachTurnWithRetry("injury-accept", "yes, update my training");
  check("HARD", Boolean(acceptTurn.reply && ["complete", "blocked"].includes(acceptTurn.reply.status)),
    acceptTurn.reply
      ? `accept turn reply status=${acceptTurn.reply.status}`
      : "accept turn: no coach reply within 90s");

  let proposalAfter = (await fsGetDoc(
    `users/${state.uid}/planAdjustmentProposals/${proposal.__docId}`,
  )).doc;

  // The coach may ask a scope question before accepting — one extra turn.
  if (proposalAfter?.decision === "pending" && looksLikeQuestion(acceptTurn.reply?.content)) {
    info("proposal still pending and coach asked a question — answering scope with 'this week'");
    check("SOFT", false, "accept needed an extra scope-question turn");
    await sendCoachTurn("injury-scope-answer", "this week");
    proposalAfter = (await fsGetDoc(
      `users/${state.uid}/planAdjustmentProposals/${proposal.__docId}`,
    )).doc;
    // The scope exchange can also supersede + re-create the proposal; if so,
    // find whichever proposal is now accepted.
    if (proposalAfter?.decision !== "accepted") {
      const { docs } = await fsListCollection(`users/${state.uid}/planAdjustmentProposals`);
      proposalAfter = docs.find((d) => d.decision === "accepted") ?? proposalAfter;
    }
  }

  const accepted = proposalAfter?.decision === "accepted";
  check("HARD", accepted,
    `proposal decision == accepted (got: ${proposalAfter?.decision ?? "missing"})`);

  const planAfter = (await fsGetDoc(`users/${state.uid}/workoutPlans/current`)).doc;
  const planSnapshotAfter = JSON.stringify({
    days: planAfter?.days ?? null,
    dailyOverrides: planAfter?.dailyOverrides ?? null,
  });
  const overrides = planAfter?.dailyOverrides && typeof planAfter.dailyOverrides === "object"
    ? Object.keys(planAfter.dailyOverrides)
    : [];
  const planMutated = planSnapshotBefore !== planSnapshotAfter;
  const acceptedScope = proposalAfter?.appliesTo?.scope;

  if (overrides.length > 0) {
    check("HARD", true, `workoutPlans/current.dailyOverrides non-empty: [${overrides.join(", ")}]`);
  } else if (planMutated && acceptedScope === "going_forward") {
    // going_forward legitimately patches the template + program, not
    // dailyOverrides — the plan DID mutate, so this is not a hard failure.
    check("HARD", true, "accept mutated the plan (template days changed, scope=going_forward)");
    check("SOFT", false, "no dailyOverrides written (scope was going_forward, not today/rest_of_week)");
  } else {
    check("HARD", false,
      accepted
        ? "accept did NOT mutate the plan: dailyOverrides empty and days unchanged"
        : "plan unchanged (proposal was never accepted)");
  }

  endScenario();
  return { proposalId: proposal.__docId, accepted };
}

async function scenarioRecoveryFollowUp(injuryResult) {
  beginScenario("D. Recovery follow-up doc");
  if (!injuryResult.accepted) {
    check("HARD", false, "skipped: injury proposal was never accepted (see scenario C)");
    endScenario();
    return;
  }
  const followUp = await pollUntil(async () => {
    const { docs } = await fsListCollection(`users/${state.uid}/coachFollowUps`);
    return docs.find((doc) => doc.status === "scheduled") ?? null;
  }, 20_000);
  check("HARD", Boolean(followUp),
    followUp
      ? `coachFollowUps/${followUp.__docId} scheduled (kind=${followUp.kind}, dueAt=${followUp.dueAt})`
      : "no coachFollowUps doc with status=scheduled after injury accept");
  endScenario();
}

async function scenarioCleanup() {
  beginScenario("E. Cleanup (deleteAccount)");
  if (!state.idToken) {
    check("SOFT", false, "no auth session — nothing to clean up");
    endScenario();
    return;
  }
  // onCall REST callable protocol: POST {data:{}} with Bearer auth. This is
  // the product's App Store-required account-deletion surface, so its
  // health is itself a HARD assertion — not just a chore.
  const { status, json } = await httpJson(`${FUNCTIONS_BASE}/deleteAccount`, {
    method: "POST",
    headers: { Authorization: `Bearer ${state.idToken}` },
    body: { data: {} },
  });
  const deleteOk = status === 200 && json?.result?.ok === true;
  check("HARD", deleteOk,
    deleteOk
      ? `deleteAccount ok (deletedAt=${json.result.deletedAt})`
      : `deleteAccount callable failed (HTTP ${status}): ${JSON.stringify(json?.error ?? json)?.slice(0, 200) ?? "non-JSON body"}`);

  let dataWiped = deleteOk;
  if (!deleteOk) {
    // Known staging issue (2026-07-19): some onCall services (deleteAccount,
    // regenerateWorkoutPlan, createCoachSession) 401 at the platform layer —
    // missing public invoker. Fall back to resetMyDataHttp so the throwaway
    // user's DATA never leaks, even while the callable is broken. The bare
    // anonymous Auth record (no email, no data) is inert residue.
    const reset = await callFunctionHttp("resetMyDataHttp", {});
    dataWiped = reset.status === 200 && reset.json?.ok === true;
    check("SOFT", dataWiped,
      dataWiped
        ? "fallback resetMyDataHttp wiped the test user's data (anonymous Auth record remains)"
        : `fallback resetMyDataHttp ALSO failed (HTTP ${reset.status})`);
  }

  if (!dataWiped) {
    check("HARD", false, `test user data NOT wiped — uid ${state.uid}`);
    log(`\n!!! CLEANUP FAILED — ORPHANED TEST USER: uid=${state.uid} (project ${PROJECT_ID}) !!!`);
    log(`!!! Delete manually: users/${state.uid} in Firestore + the Auth user. !!!\n`);
    endScenario();
    return;
  }

  // Owner-read of wiped data must now 404 (docs gone) or 403 (token revoked).
  const after = await fsGetDoc(`users/${state.uid}/profile/current`);
  check("HARD", after.status === 404 || after.status === 403,
    `post-cleanup Firestore read denied/absent (HTTP ${after.status})`);
  endScenario();
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

function printReport() {
  const lines = [];
  const hardChecks = scenarios.flatMap((s) => s.checks.filter((c) => c.level === "HARD"));
  const hardFailures = hardChecks.filter((c) => !c.pass);
  const softWarnings = scenarios.flatMap((s) => s.checks.filter((c) => c.level === "SOFT" && !c.pass));
  const overall = hardFailures.length === 0 ? "PASS" : "FAIL";

  lines.push(`# IronBoi staging E2E smoke — ${overall}`);
  lines.push("");
  lines.push(`- Project: \`${PROJECT_ID}\` (live backend, real Gemini tool loop)`);
  lines.push(`- Test user: anonymous \`${state.uid ?? "n/a"}\` (deleted at end)`);
  lines.push(`- Coach messages sent: ${state.messagesSent} / ${MAX_MESSAGES}`);
  lines.push(`- Wall clock: ${((Date.now() - startedAtMs) / 1000).toFixed(0)}s / ${WALL_CLOCK_CAP_MS / 1000}s`);
  lines.push(`- HARD checks: ${hardChecks.length - hardFailures.length}/${hardChecks.length} passed; SOFT warnings: ${softWarnings.length}`);
  lines.push("");

  for (const scenario of scenarios) {
    const hard = scenario.checks.filter((c) => c.level === "HARD");
    const failed = hard.filter((c) => !c.pass);
    const softFailed = scenario.checks.filter((c) => c.level === "SOFT" && !c.pass);
    const verdict = failed.length > 0 ? "FAIL" : softFailed.length > 0 ? "PASS (soft warnings)" : "PASS";
    lines.push(`## ${scenario.name} — ${verdict} (${(scenario.elapsedMs / 1000).toFixed(1)}s)`);
    lines.push("");
    for (const c of scenario.checks) {
      const tag = c.level === "INFO" ? "info" : c.pass ? `${c.level} pass` : `${c.level} ${c.level === "HARD" ? "FAIL" : "warn"}`;
      lines.push(`- [${tag}] ${c.detail}`);
    }
    lines.push("");
  }

  if (state.turns.length > 0) {
    lines.push("## Turn log");
    lines.push("");
    lines.push("| # | turn | status | seconds | tools |");
    lines.push("|---|------|--------|---------|-------|");
    state.turns.forEach((turn, index) => {
      const status = turn.errorCode ? `${turn.status} (${turn.errorCode})` : turn.status;
      lines.push(
        `| ${index + 1} | ${turn.label} | ${status} | ${(turn.elapsedMs / 1000).toFixed(1)} | ${turn.toolNames.join(", ") || "—"} |`,
      );
    });
    lines.push("");
  }

  console.log(lines.join("\n"));
  return overall === "PASS";
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  let injuryResult = { proposalId: null, accepted: false };
  try {
    const bootstrapped = await scenarioAuthAndBootstrap();
    if (bootstrapped) {
      await scenarioPlainChat();
      injuryResult = await scenarioInjuryArc();
      await scenarioRecoveryFollowUp(injuryResult);
    }
  } catch (error) {
    if (error instanceof BudgetExceededError) {
      if (currentScenario) {
        check("HARD", false, `aborted: ${error.message}`);
        endScenario();
      } else {
        beginScenario("Budget guard");
        check("HARD", false, `aborted: ${error.message}`);
        endScenario();
      }
    } else {
      if (!currentScenario) beginScenario("Unexpected error");
      check("HARD", false, `unexpected harness error: ${error?.stack ?? error}`);
      endScenario();
    }
  } finally {
    try {
      await scenarioCleanup();
    } catch (error) {
      if (!currentScenario) beginScenario("E. Cleanup (deleteAccount)");
      check("HARD", false, `cleanup crashed: ${error?.message ?? error}`);
      log(`\n!!! CLEANUP FAILED — ORPHANED TEST USER: uid=${state.uid} (project ${PROJECT_ID}) !!!\n`);
      endScenario();
    }
  }

  const passed = printReport();
  process.exitCode = passed ? 0 : 1;
}

await main();
