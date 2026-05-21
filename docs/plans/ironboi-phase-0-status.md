---
title: IronBoi Phase 0 — Status + Plan for Codex
date: 2026-05-11
last_revised: 2026-05-21
author: Claude (Tosh's studio)
audience: Codex
inputs:
  - ironboi-agent-architecture-security-audit.md (Codex's original)
  - ironboi-architecture-counter-review.md (Claude's response)
  - ironboi-phase-plan.md (consolidated plan)
status: Phase 0 mid-flight — baseline commit landed 2026-05-21, PR #1 (timeout) baked in; PR #2/#3/#4/#5 pending
---

# Phase 0 Status + Forward Plan

This is the working state Tosh wants Codex looped in on. Two prior docs in this folder cover the full audit + counter-review + consolidated plan. This doc is the operational layer: decisions Tosh locked, what's already in the tree, what's next.

## 2026-05-21 revisions

- **Anthropic dropped.** Coach is Gemini-only. `@anthropic-ai/sdk` and `AnthropicCoachProvider` are slated for removal (now PR #3). The `selectCoachModelProvider` abstraction stays.
- **Baseline established.** Prior to this date the entire `functions/` backend, Firestore rules, iOS project, and planning docs were untracked. The 2026-05-21 baseline commits bring them into git so Phase 0 PRs have something to diff against.
- **PR #1 (timeout) is now baked into the baseline.** No separate PR needed — the change ships as part of the initial commit. PR numbering below refers to the four *remaining* PRs.
- **Original PR #3 (Anthropic stream throttle) is moot** because `GeminiCoachProvider` does not stream. That slot is replaced by "Remove Anthropic SDK + dead provider class."

## Decisions Tosh locked (2026-05-11)

| Item | Decision | Notes |
|---|---|---|
| HIPAA compliance | **Skip.** IronBoi is consumer wellness, not a Covered Entity. | Comply with FTC HBNR (2024) + Apple HealthKit terms + CCPA instead. Revisit only if B2B pivot (clinic, EHR, insurance). |
| Spend caps (Phase 0 defaults) | **200 messages/day, 1M input tokens/day, 200k output tokens/day per user.** | Configurable via env later. |
| iOS App Attest | **Yes, configure it.** | New Task #15 created. Pairs with server-side App Check enforcement (#14). |
| Phase 0 delivery | **4 small PRs, not one big one.** | One Phase 0 task per PR for easier review and bisecting. |
| Coach model provider (2026-05-21) | **Gemini only.** Keep `selectCoachModelProvider` for future flexibility; remove Anthropic. | Resolves the question we'd posed to Codex. |

## Phase 0 task list (revised 2026-05-21)

| # | Task | Status |
|---|---|---|
| 1 | Drop coach trigger timeout 540s→60s, set maxInstances:20, retry:false | ✅ landed in baseline 2026-05-21 |
| 2 | Move Gemini API key from URL query to `x-goog-api-key` header | pending |
| 3 | **Remove Anthropic SDK + `AnthropicCoachProvider`** (replaces stream-throttle) | pending |
| 4 | Add `turnId` UUID per coach turn, log + persist | pending |
| 5 | Add per-user daily message + token counter with hard cap | pending |

Tasks #6 onward (prompt restructure, tool executor, memory queue, App Check, account deletion, etc.) are Phase 1+ and not in scope for Phase 0.

## What's already in the working tree (Task #1)

One file modified: `functions/src/index.ts` lines 379-393.

### Diff

```diff
 export const onUserCoachMessageCreated = onDocumentCreated(
   {
     region: "us-central1",
     document: "users/{userId}/coachSessions/{sessionId}/messages/{messageId}",
     secrets: [anthropicApiKey, geminiApiKey],
-    timeoutSeconds: 540,
+    // Bill protection + sanity. A chat turn should never need more than 60s.
+    // maxInstances caps a runaway client at ~20 concurrent coach turns.
+    // retry:false because we never want a coach turn to silently re-run
+    // (would double-bill the model and write conflicting assistant messages).
+    timeoutSeconds: 60,
+    maxInstances: 20,
+    cpu: 1,
+    memory: "512MiB",
+    retry: false,
   },
```

### Rationale

The original `timeoutSeconds: 540` (9 minutes per chat turn) lets a stuck Anthropic stream or a runaway tool loop burn 9 minutes of compute per message. No `maxInstances` meant one spammy client could spawn unlimited concurrent function instances. No explicit `retry` meant a transient model error could re-fire the function and double-bill against the user's daily cap (once that ships in Task #5).

### Test plan for this PR

- Unit test that imports the function config and asserts `timeoutSeconds === 60`, `maxInstances === 20`, `retry === false`. Catches future regressions.
- Existing security suite should pass unchanged.
- Manual: deploy to a test project, send a chat message, confirm reply completes well under 60s with current Gemini config.

### Rollback

Revert the file. No data migration, no schema change.

## Phase 0 PRs #2-#5 — outline

### PR #2 — Gemini key out of URL

**File:** `functions/src/coach/modelProvider.ts:67-89`

**Change shape:**
```ts
// Before
const url = `https://generativelanguage.googleapis.com/v1beta/models/${this.model}:generateContent?key=${this.apiKey}`;
const response = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: ... });

// After
const url = `https://generativelanguage.googleapis.com/v1beta/models/${this.model}:generateContent`;
const response = await fetch(url, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "x-goog-api-key": this.apiKey,
  },
  body: ...,
});
```

**Test:** Mock `fetch`, assert outgoing URL has no `?key=` and header includes `x-goog-api-key`.

### PR #3 — Remove Anthropic SDK (replaces stream-throttle)

**Why this replaces the original PR #3:** Stream throttling was Anthropic-specific; Gemini does not stream today, so there is nothing to throttle. Removing the abandoned provider is the cleaner change and unblocks Phase 1's prompt rewrites.

**Files:**
- `functions/src/coach/modelProvider.ts` — delete `import Anthropic from "@anthropic-ai/sdk"` (L1), delete `AnthropicCoachProvider` class (L36-78), simplify `selectCoachModelProvider` (L160-179) to always pick Gemini while keeping the function signature.
- `functions/src/coach/orchestrate.ts:132` — drop `anthropicApiKey` from `selectCoachModelProvider` call.
- `functions/src/index.ts` — drop `anthropicApiKey` secret (L55), `secrets:` entry (L808), orchestrator arg (L835).
- `functions/package.json` — drop `"@anthropic-ai/sdk": "^0.95.1"` (L19), run `npm install` to update lock.
- Leave the generic `onText` callback in `orchestrate.ts:156-164` in place (cheap, future-proof for when Gemini gets streaming).

**Test:** `npm test` in `functions/` passes. Security suite unchanged.

### PR #4 — turnId correlation

**Files:** `functions/src/index.ts:394` (trigger), `functions/src/coach/orchestrate.ts` (signature + writes), `functions/src/logging/safeLogger.ts:14` (allowedLogKeys).

**Change shape:**
- In the trigger handler, generate `const turnId = randomUUID()` from `node:crypto` and pass to `orchestrateCoachTurn`.
- Add `turnId: string` to `OrchestrateCoachTurnArgs`.
- Write `turnId` onto the assistant message doc on first set.
- Add `"turnId"` to `allowedLogKeys` in `safeLogger.ts`.
- Update existing `safeLogger.error` call in `orchestrate.ts:149-155` to include `turnId`.

**Test:** Mock the trigger, run one turn, grep logs for the same turnId in pre-flight, model call, post-flight, completion. Assert assistant doc has the field.

### PR #5 — Per-user daily spend cap

**Files:** new `functions/src/usage/cap.ts`, modified `functions/src/coach/orchestrate.ts`, modified `firestore.rules`.

**Schema:**
```
users/{uid}/usage/{yyyy-mm-dd} {
  messageCount: number,
  inputTokens: number,
  outputTokens: number,
  capReached: boolean,
  serverUpdatedAt: serverTimestamp
}
```

**Caps (locked by Tosh):** 200 messages/day, 1M input tokens/day, 200k output tokens/day.

**Logic:**
- Before model call: read today's usage doc, check messageCount vs cap, abort with fixed "daily limit reached" assistant message if exceeded.
- After model call: increment counters using `FieldValue.increment` with the input/output token counts from the provider response.
- Anthropic stream provides `usage` on `finalMessage()`. Gemini provides `usageMetadata` on the response. Both need to be wired into the provider return value.

**Firestore rules:** `users/{uid}/usage/{date}` server-only write, owner read.

**Test:** Unit test that mocks a usage doc at cap; assert orchestrator writes the "limit reached" reply and does NOT call the model provider. Second test asserts increment fires after a successful turn.

## What Phase 0 explicitly does not touch

These all stay for Phase 1+:

- Prompt restructure (instructions in system, user data in user message)
- Tool executor identity tightening
- Memory proposal queue
- App Check enforcement (server side)
- App Attest provider setup (iOS)
- Firestore rule schema validation
- Account deletion callable
- HealthKit ingestion
- Corpus retrieval
- The `USER_SCOPED` access policy module

The full Phase 1, 2, 3 sequence is in `ironboi-phase-plan.md` in this folder.

## Open questions for Codex

1. Does Codex agree the Phase 0 sequencing is correct? Bill protection (1, 5) + secret hygiene (2) + Anthropic removal (3) + observability (4) before anything architectural.
2. On PR #5 (spend caps): Tosh locked the defaults at 200/1M/200k. Does Codex see a reason to override per-user (premium tier exemption, internal testing accounts, etc.)? If so, what's the cleanest place to encode that?
3. **Resolved 2026-05-21.** Original Q3 ("is 1500ms safe?") is moot because the streaming-throttle task was dropped. Replaced by: PR #3 now rips out Anthropic entirely. Coach is Gemini-only.
4. Codex's audit F2 listed `memoryFacts` as client-writable. The current `firestore.rules:41` is `allow write: if false`, so this is already server-only. Is Codex willing to retract that finding, or is there a concern we're missing?
5. The audit's "User Capsule v1 manifest" JSON document. The counter-review proposed a `USER_SCOPED` TypeScript module instead, generating Firestore rules from it. Phase 2 task. Does Codex prefer the manifest or the module, and why?

## Forward path

PR #1 (timeout) is now baked into the 2026-05-21 baseline commit on `main`. PRs #2 / #3 / #4 / #5 happen on top of that baseline, on separate branches, in any order. PR #3 (Anthropic removal) is independent and could ship first if we want to clean up dead code before adding new features.
