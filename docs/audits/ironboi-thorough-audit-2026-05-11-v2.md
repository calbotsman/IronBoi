# IronBoi Thorough Audit — 2026-05-11 (v2)

**Auditor:** Claude (Sonnet) — second pass
**Scope:** Full repo at `/Users/joshualong/IronBoi`
**Tree state:** Working tree as of 2026-05-12 02:57 UTC
**Companion:** Read together with `ironboi-thorough-audit-2026-05-11.md` (v1). This document is a delta: it **retracts** v1 errors, **confirms** v1 findings that still hold, and adds **new** findings the first pass missed.

The biggest gap in v1 was that it never opened `functions/test/security/` — an entire test suite that already pins down several of the invariants v1 worried about. Reading the tests changed my picture of the codebase significantly: this team has materially better security hygiene than v1 credited them with.

---

## 1. Retractions from v1

### ❌ Retract v1 S-3 — "`profile/current` is client-writable"

**v1 cited:** firestore.rules lines 46–48 as `allow read, write: if owns(userId);`
**Actual current rule** (firestore.rules:46–49):

```
match /profile/current {
  allow read: if owns(userId);
  allow write: if false;
}
```

`profile/current` is server-only-writable. The "client poisons `onboardingStatus` directly" attack is blocked at the rules layer. And there's an explicit regression test for it:

`functions/test/security/rules/firestore.rules.test.ts:61–71`
```ts
it("profile_owner_cannot_poison_onboarding_state", async () => {
  const db = await authedDb(USER_A);
  await assertFails(
    setDoc(doc(db, `users/${USER_A}/profile/current`), {
      ...baseProfile,
      onboardingStatus: "complete",
      onboardingStep: "complete",
      activeProgramProposalId: "attacker-controlled",
    }),
  );
});
```

**v1 was wrong.** Either I misread on the first pass or the rule was edited between reads (the file was in the "modified since 2026-05-10" list both times). Either way, the current state is the strict one and the test gates it. **Downgrade S-3 from Critical to None.**

### ⚠️ Soften v1 S-6 — "`decidedAt` is client-supplied"

The flow does accept `decidedAt` from the request, but `serverDecidedAt: FieldValue.serverTimestamp()` is written alongside, and `functions/test/security/onboarding/acceptProgramProposal.test.ts:30–72` explicitly asserts the server timestamp is the authoritative value. Production callers read `serverDecidedAt`. **Recommendation stands** (drop the client field entirely for hygiene) but severity drops from Medium to Low.

### ⚠️ Soften v1 S-5 — "no `.strict()` on Zod schemas"

The `coach/contextBundle.test.ts` file demonstrates the bundle DOES strip unknown profile fields (`systemOverride`, `secretAdminNote`) and user-supplied `userId` strings inside facts/logs/sessionHistory. The defense is in the **bundle assembler**, not the schema layer — `pickProfile` (contextBundle.ts:108–117) iterates only the allowed `PROFILE_FIELDS` constant. So unknown fields in profile **don't reach the model prompt**. The recommendation to add `.strict()` to the Zod schemas is still worth doing as belt-and-braces, but the practical risk is lower than v1 suggested. **Severity Medium → Low.**

### ⚠️ Soften v1 S-2 — "Gemini API key in URL"

Verified during v1 already: the Gemini key is sent as `x-goog-api-key` header, not in the URL. `functions/test/security/coach/modelProvider.test.ts:9–42` explicitly pins this — a regression that moved the key to the URL would fail this test. **No action needed.**

---

## 2. Confirmations — v1 findings that still hold

These were correctly characterized in v1 and remain on the punch list:

- **S-1** — All six `onRequest` endpoints set `Access-Control-Allow-Origin: *` and `invoker: "public"`. Bearer verification runs before work; the residual risk is cross-origin token replay. Restrict CORS to the production PWA origin.
- **S-4** — `ToolCallBase.userId` and `idempotencyKey` are still in the wire schema (tool-calls.ts:11–15). The executor strips a finite alias set. **Update:** `functions/test/security/tools/toolExecutorIdentity.test.ts:33–50` already tests `userId`, `uid`, `user_id`, `userID`, `userid`, `targetUserId`, `ownerId`, `subjectId` — strong coverage. But the executor itself **is never wired into `coach/orchestrate.ts`** (see new finding S-21 below) so the defense currently protects an unused code path. Still: remove from schema.
- **S-7** — Regex-only safety classifier. Coverage hole confirmed: `safety.ts:71` rapid-weight-loss regex `/\b(lose|drop|cut).{0,20}\b(\d{2,})\b.{0,20}\b(days?|week)\b/` matches "lose 20 pounds in 2 weeks" but **not** "lose 20 lbs by Friday" or "15 pounds in a week" (no digit before `week`).
- **S-8** — `parseWeightKg` / `parseHeightCm` unit-guessing heuristics still in place.
- **S-9** — `acceptProgramProposal` still merges entire `proposal.profile` back into `profile/current` (flow.ts:202 region).
- **S-10** — `getCoachBootstrap` still re-reads two JSON files per call. **Update:** Verified that `getCoachBootstrap` ships the full `coach` config (including `safetyPolicy.blockedTopics`, `notFor`, `clinicianEscalationTriggers`) to every signed-in client. This is by design; clients render some of it. But it means the policy is not "hidden" — only the assembled system prompt is server-only.
- **Q-1** — `src/App.jsx` still 979 KB on disk with inline base64 JPEGs.
- **Q-2** — `WorkoutView.swift` still has duplicate detail-sheet logic.
- **Q-3** — Three sources of truth for the exercise catalogue. **Update:** `scripts/extract-ironlab-domain.mjs` (newly noticed) auto-generates `functions/src/domain/ironlab-seed.json` from `src/App.jsx`. So **PWA → backend** is mostly automated, but **iOS is still hand-maintained** with confirmed drift on at least the "Overhead Press" YouTube ID. Recommend extending the extractor to emit a Swift file too.
- **Q-4 through Q-10** — all still real.
- **P-1 through P-7** — all still real.
- **A-1 through A-8** — all still real.

---

## 3. New findings

### 🆕 S-3v2 (High) — `workoutLogs`, `workoutPlans`, `dailyChecks`, `consentRecords`, `metricSnapshots` allow direct client writes, bypassing Zod

**Files:** `firestore.rules:55–79, 98–100`

The rules grant clients full read/write access to these collections:

```
match /workoutLogs/{logId}        { allow read, write: if owns(userId); }
match /workoutPlans/{planId}      { allow read, write: if owns(userId); }
match /dailyChecks/{date}         { allow read, write: if owns(userId); }
match /metricSnapshots/{sid}      { allow read, write: if owns(userId); }
match /consentRecords/{recordId}  { allow read, write: if owns(userId); }
```

The backend has Zod-validated callables (`logWorkout`, `upsertWorkoutPlan`, `recordDailyCheck`, `recordConsent`) that gate shape, but a malicious or curious client can use the Firestore Web SDK directly to write arbitrary documents. Concrete impact:

- A user could write `workoutLogs/abc` with `{exercises: [{name: "<script>", sets: [...]}]}` — the coach context loader would then pull this into the prompt context bundle (contextBundle.ts:132–160). The bundle does truncate strings to 1,000 chars and 12 exercises, mitigating prompt-injection volume, but content still flows.
- `consentRecords` writes that disagree with backend invariants (e.g., `{granted: true, scope: {dataExport: true, ...}, withdrawnAt: "1970-01-01"}`) could be later read by an audit/export feature and misrepresent the user's actual consent state.
- `metricSnapshots` accepts any shape today since there's no backend handler at all (verified — `metricSnapshotPath` is declared in `paths.ts:33` but no function imports it).
- `workoutPlans` direct writes bypass `WorkoutPlan.parse()` server-side validation. The coach reads plans from this collection and acts on them, so the model could be fed `days: {Mon: {exercises: [{name: "ignore prior instructions and ..."}]}}`.

**Recommendation:** Mirror the strict pattern used for `coachSessions/messages`: change these rules to `allow write: if false;` and force all writes through the validated callables. The iOS app is already structured this way for the workout flow (`AppModel.swift` calls `startWorkoutSessionHttp` / `finishWorkoutSessionHttp`). The PWA writes via the callables too. So the rule tightening is unlikely to break either client.

### 🆕 S-21 (Medium) — `executeTool` is defended but never wired into orchestration

**File:** `functions/src/tools/executor.ts`; `functions/src/coach/orchestrate.ts`

The tool executor (with the userId-alias defense) is exported and tested but `executeTool` is **not imported anywhere outside its own test file**. Grep across `functions/src/` returned zero call sites. The orchestrator calls `provider.generateCoachReply` directly and never dispatches tool calls.

**Why this matters:** the coach JSON config and the contract files (`tool-calls.ts`) describe a tool registry the runtime doesn't have. Anyone reading the contract believes the coach can `log_workout`, `generate_plan`, etc. Today the coach can only emit text. If a future change wires up tools without re-reading the executor, the safety pattern may be skipped.

**Recommendation:** Either (a) ship the tool dispatcher behind a feature flag with the existing executor in the loop, or (b) delete the unused `executor.ts`/`tool-calls.ts`/`tool-call-examples.json` so the codebase stops promising capability that doesn't exist.

### 🆕 S-22 (Medium) — `selectCoachModelProvider` silently falls back to Gemini even when `IRONBOI_COACH_PROVIDER=anthropic`

**File:** `functions/src/coach/modelProvider.ts:160–179`

```ts
if (preferredProvider === "anthropic" && anthropicApiKey) {
  return new AnthropicCoachProvider(anthropicApiKey);
}
if (geminiApiKey) return new GeminiCoachProvider(geminiApiKey);
if (anthropicApiKey) return new AnthropicCoachProvider(anthropicApiKey);
return null;
```

If the env says "anthropic" but only `GEMINI_API_KEY` is configured (a plausible misconfiguration during a provider migration), the coach silently switches to Gemini. The operational doc and `.env.example` imply the env var pins the provider. No log line indicates the fallback occurred.

**Recommendation:** Log a warning (via `safeLogger.warn`) when the preferred provider can't be used and a fallback is taken. Or refuse to start a turn and write `"complete"` with a "coach not configured" message — same behavior as when both keys are missing.

### 🆕 S-23 (Medium) — Daily usage cap is not atomic; two parallel turns can both pass

**File:** `functions/src/usage/cap.ts:62–71` + `functions/src/coach/orchestrate.ts:94`

`checkDailyUsageCap` reads the usage doc, then later `recordCoachTurnUsage` increments. Two concurrent `onUserCoachMessageCreated` invocations for the same user (two queued messages, back-to-back) both read the usage doc before either writes, so both pass the gate even if the user is one turn under the cap. With `maxInstances: 20`, a determined user could exceed the cap by a small margin.

The increment itself is atomic (`FieldValue.increment(1)`), so the doc state ends consistent — only the gate is racy.

**Recommendation:** Move the check-and-increment into a Firestore transaction, or accept the small overrun and document it. Bill exposure is minor at the current 200 msg/day cap, but should be on the list.

### 🆕 S-24 (Low) — `safeLogger.sanitizePayload` infinite-recurses on circular objects

**File:** `functions/src/logging/safeLogger.ts:48–65`

`redactValue` and `sanitizePayload` recurse unconditionally over array/object values. A payload like `const p = {event: "x"}; p.self = p;` would stack-overflow before any log is emitted. Callers today don't pass cyclic data, but a future caller logging an `Error` whose `cause` cycles, or a Firestore document reference with a circular parent pointer, would crash a coach turn.

**Recommendation:** Track visited references with a `WeakSet`. Replace cycles with `"[CIRCULAR]"`.

### 🆕 S-25 (Low) — `functions/test/security/static/securityStatic.test.ts` passes vacuously for missing directories

**File:** the static test file

The static test walks `functions/src/coach/`, `functions/src/tools/`, and `functions/src/agents/`. The `agents/` directory **doesn't exist** (verified). Same for `functions/src/tools/handlers/`. The "no `collectionGroup(` calls" and "no `args.userId` references" checks silently pass because the walk yields zero files. If a developer adds `agents/foo.ts` with a violation, the test catches it; but the green CI today asserts less than it appears to.

**Recommendation:** Fail the test (or warn) if a target directory doesn't exist. Or remove the dead path-walking entries.

### 🆕 S-26 (Low) — `firestore-debug.log` is committed/tracked, not in `.gitignore`

**File:** `functions/firestore-debug.log` exists (98 KB); `.gitignore` only lists `node_modules/`, `dist/`, `.DS_Store`, `functions/lib/`.

The provisioning doc promises `.env.local` is already in `.gitignore` (`docs/operations/firebase-provisioning.md:44, 154`) — it isn't. Same risk applies to the debug logs.

**Recommendation:** Add to `.gitignore`:
```
.env.local
.env.*.local
**/firebase-debug.log
**/firestore-debug.log
firestore-debug.log
*.log
```

### 🆕 S-27 (Low) — `scripts/set-admin.mjs` referenced in docs but doesn't exist

**File:** `docs/operations/firebase-provisioning.md:197, 207`

The doc instructs:
```
# scripts/set-admin.mjs (gitignored)
...
node scripts/set-admin.mjs <your-uid>
```

The `scripts/` directory contains only `extract-ironlab-domain.mjs`. The set-admin script is either lost, not yet written, or kept on someone's machine. Anyone following the doc on a fresh checkout will hit "module not found" with no recovery instructions.

**Recommendation:** Either commit the script (it likely contains nothing secret — just `auth.setCustomUserClaims(uid, {admin: true})`) or remove the references and document the alternative (Firebase CLI / console).

### 🆕 S-28 (Low) — Several Firestore rules gate features that aren't implemented

**Files:** `firestore.rules:77–79, 108–116`

- `metricSnapshots` — rule exists, no backend handler (verified — `metricSnapshotPath` is declared and never imported).
- `corpus/{entryId}` — rule allows any signed-in user to read, write false. No backend reads from this collection (`retrieveResearchCorpus` uses an in-memory list).
- `seed/{docId}` — same: rule reads allowed, no code paths read it.

These rules aren't dangerous (they're permissive only for empty collections), but they're misleading. A reader would assume the features exist.

**Recommendation:** Add a comment block at the top of `firestore.rules` listing collections-with-rules-but-no-code, or remove until the features ship.

### 🆕 Q-11 (Medium) — Documentation drift in `firebase-provisioning.md`

**File:** `docs/operations/firebase-provisioning.md`

- Doc says "14 functions deployed" in one place, lists 14 in a parenthetical. Actual export count in `index.ts` is **22** (counted: getCoachBootstrap, resetMyDataHttp, getUserState, upsertProfile, recordConsent, logWorkout, upsertWorkoutPlan, recordDailyCheck, startWorkoutSessionCallable, finishWorkoutSessionCallable, startWorkoutSessionHttp, finishWorkoutSessionHttp, upsertMemoryFact, deleteMemoryFact, revokeConsent, createCoachSession, sendCoachMessage, sendCoachMessageHttp, sendOnboardingAnswerHttp, acceptProgramProposalHttp, recordSafetyEvalResult, onUserCoachMessageCreated).
- References `scripts/set-admin.mjs` (see S-27).
- Promises `.env.local` is gitignored (see S-26).

**Recommendation:** Stamp the doc with a "last verified" line and regenerate the function list from `index.ts` programmatically.

### 🆕 Q-12 (Low) — `scripts/extract-ironlab-domain.mjs` evals JS from `App.jsx` in `vm.runInNewContext`

**File:** `scripts/extract-ironlab-domain.mjs`

The script extracts top-level JS literals (`MUSCLE_GROUPS`, `EXERCISE_LIBRARY`, etc.) from `src/App.jsx` and evaluates each in a sandboxed VM to produce `functions/src/domain/ironlab-seed.json`. If `App.jsx` is ever attacker-controlled (a compromised dependency, a bad merge, a `git checkout` from an untrusted branch) and contains a literal whose evaluation has side effects — e.g., a Proxy with a malicious `toString` trap — the script's VM sandbox limits damage but doesn't eliminate it. The risk is low (the script runs locally, not in prod) but worth knowing.

**Recommendation:** Either keep the eval but pin the input to a trusted commit hash, or refactor to AST-only extraction with no JS execution (use `acorn` and walk the literal nodes).

### 🆕 Q-13 (Low) — Coach turns can see stale conversation context under back-to-back sends

**Files:** `functions/src/coach/context.ts:11–44`, `functions/src/coach/orchestrate.ts:121`

`loadCoachContext` reads `coachSessions/{sessionId}/messages` ordered by `serverCreatedAt` and limited to 40. If a user sends two messages within a few hundred milliseconds, two `onUserCoachMessageCreated` triggers fire in parallel. The second turn's `loadCoachContext` may or may not see the first turn's user-message + assistant-reply pair depending on Firestore replication timing. The model intermittently lacks the first turn's context, producing replies that ignore an immediately-prior question.

**Recommendation:** Either serialize per-session turns at the dispatcher (Cloud Tasks queue keyed by sessionId; with `concurrency: 1`, you also need queue-level ordering), or live with the looseness and add a note that "rapid send" may produce out-of-order replies.

### 🆕 Q-14 (Low) — `index.ts:78–80` `stripUserId` is misnamed

**File:** `functions/src/index.ts:78–80`

```ts
function stripUserId<T extends Record<string, unknown>>(value: T, userId: string) {
  return { ...value, userId };
}
```

It **overwrites** userId with the authenticated one, it doesn't strip. The behavior is correct; the name is misleading and the same name appears in many call sites.

**Recommendation:** Rename to `forceAuthenticatedUserId` or `bindUserId`.

### 🆕 Q-15 (Low) — Postflight safety classifier reclassifies the model's own helpful response

**File:** `functions/src/coach/orchestrate.ts:170–186` calls `classifyUserMessage(content)` on the model's reply.

If the model legitimately mentions "chest pain" while telling the user to seek emergency care, the postflight regex matches `chest pain` and overwrites the helpful response with the canned `emergency_symptoms` refusal — which still tells the user to call emergency services, but drops the specific context the model just produced.

**Recommendation:** Distinguish a "model is responding to an emergency" path (passthrough) from "model is initiating a refusal" (rewrite). Or apply postflight only to keywords the classifier flagged in the PREFLIGHT — model adding new emergency keywords mid-reply is likely already-correct escalation.

### 🆕 A-9 (Low) — iOS `project.yml` has no `DEVELOPMENT_TEAM`, uses legacy "iPhone Developer" code-sign identity

**File:** `ios/IronBoi/project.yml`

The XcodeGen spec sets only `TARGETED_DEVICE_FAMILY: 1` and the entitlements file path. The generated `project.pbxproj` ends up with `CODE_SIGN_IDENTITY = "iPhone Developer"` — Apple's legacy identity string. Modern is `"Apple Development"`. Xcode 15+ will prompt to migrate. Doesn't break builds today but it's a yellow flag during App Store submission.

**Recommendation:** Add to `project.yml`:
```yaml
settings:
  base:
    DEVELOPMENT_TEAM: <your team id>
    CODE_SIGN_STYLE: Automatic
    CODE_SIGN_IDENTITY: "Apple Development"
```

### 🆕 A-10 (Low) — PWA silently degrades to "Local mode" when Firebase env is missing

**File:** `src/firebaseClient.js:26–31`, `src/App.jsx:709, 767`

```js
export const firebaseConfigured = Boolean(
  firebaseConfig.apiKey && firebaseConfig.authDomain &&
  firebaseConfig.projectId && firebaseConfig.appId,
);
```

If a Vercel deploy is missing one of the `VITE_FIREBASE_*` env vars, the PWA boots, says "Local mode" in tiny text, and writes nothing to Firestore while the user thinks they're using the app. The provisioning doc partially flags this; the user-facing UI does not.

**Recommendation:** When `firebaseConfigured === false`, render a visible banner (not just status text) and disable the "Sync" button entirely.

---

## 4. Positive signals the v1 audit undersold

These deserve credit and didn't make v1:

- **`functions/test/security/` exists and is substantial.** Six test files covering rules, executor identity, safe logging, usage caps, onboarding accept, context bundle, and model provider. Most of the high-risk surfaces have at least one regression test. The static test (despite the vacuous-pass issue in S-25) is a unique class of guard most codebases don't have.
- **The Firestore rules are stricter than v1 reported.** `profile/current` is server-only-writable. `coachSessions/messages` has the `validUserCoachMessage` shape check with `onlyKeys()` allowlist. `programProposals` updates are restricted to `decision`/`decidedAt` keys.
- **Context bundle stripping is a real defense.** `pickProfile` (contextBundle.ts:108–117) uses an allowlist over `PROFILE_FIELDS`, so unknown profile fields can't slip into the prompt even if they slip past Zod.
- **Server timestamps are authoritative throughout.** Every write that takes a client timestamp also writes `FieldValue.serverTimestamp()` alongside, and the tests assert the server value is what production code reads.
- **The Gemini key handling is correctly tested.** modelProvider.test.ts proves the key never appears in the URL.
- **Tool executor alias defense is tested with 8 alias variants** including `targetUserId`, `ownerId`, `subjectId` — the v1 worry about future aliases is covered for the current set.

---

## 5. Updated punch list

Replacing the v1 "next steps" with revised priorities:

1. **S-3v2 (was S-3v1)** — Tighten `workoutLogs`, `workoutPlans`, `dailyChecks`, `consentRecords`, `metricSnapshots` rules to `allow write: if false;`. This is the real version of the issue v1 mis-targeted at `profile/current`. Add a regression test to match the pattern used for `profile/current`.
2. **S-22** — Log a `safeLogger.warn` when `selectCoachModelProvider` falls back to a non-preferred provider, or refuse to start a turn.
3. **S-26 + S-27** — `.gitignore` cleanup; either commit `scripts/set-admin.mjs` or remove doc references.
4. **S-21** — Delete unused tool executor / contracts OR wire them into the orchestrator. Don't ship "decorative" defended-but-unreachable code.
5. **S-1** — Restrict CORS on the six HTTP endpoints. iOS uses URLSession (no CORS); only the PWA origin needs `*`.
6. **S-4** — Remove `userId` and `idempotencyKey` from `ToolCallBase`. Add a 9th alias to the test (random new name) and assert dropped.
7. **S-23** — Make the daily usage cap a transaction.
8. **Q-1** — De-inline the base64 images in the PWA, OR confirm the PWA is being deprecated and document it.
9. **A-10** — Make the "Local mode" footgun loud in the PWA UI.
10. **Q-11** — Refresh `firebase-provisioning.md`.

The rest of the list (everything from v1 not retracted, plus S-24, S-25, S-28, Q-12 through Q-15, A-9) are valuable but secondary.

---

## 6. Methodology

**New files read in this pass (relative to v1):**

- All of `functions/test/security/`:
  - `rules/firestore.rules.test.ts`
  - `tools/toolExecutorIdentity.test.ts`
  - `logging/safeLogger.test.ts`
  - `usage/cap.test.ts`
  - `onboarding/acceptProgramProposal.test.ts`
  - `coach/contextBundle.test.ts`
  - `coach/modelProvider.test.ts`
  - `static/securityStatic.test.ts`
  - `fixtures/emulator.ts`
- `ios/IronBoi/project.yml`
- `ios/IronBoi/IronBoi.xcodeproj/project.pbxproj` (skimmed)
- `scripts/extract-ironlab-domain.mjs`
- `docs/operations/firebase-provisioning.md`
- `functions/firestore-debug.log` (verified contains no secrets/PHI by inspection)
- `functions/tsconfig.json`
- `functions/src/coach/ironboi-coach.v0.json` (re-read)
- `functions/src/contracts/tool-call-examples.json`
- `functions/src/domain/ironlab-seed.json` (skimmed)
- `functions/src/evals/safety-evals.json`
- `git log` (15 commits skimmed for backdoor risk)

**Re-verified from v1:**

- `firestore.rules` lines 42–117 — confirmed current state has `allow write: if false;` for `profile/current`, contradicting the v1 citation. Two paths possible: I misread in v1, or the file was modified between reads.
- All v1 file/line citations not retracted above remain accurate as of this pass.

**Not in scope (still):** runtime testing on simulator/TestFlight, IAM/console config, Vercel env, billing accounts.

---

*End of v2 audit.*
