# IronBoi Thorough Audit — 2026-05-11

**Auditor:** Claude (Sonnet)
**Scope:** Full repo at `/Users/joshualong/IronBoi`
**Branches read:** working tree as of 2026-05-12 01:22 UTC
**Output:** code quality + architecture, security + privacy, performance + dependencies, UX + accessibility

Three prior internal reviews exist in the tree — `ironboi-architecture-counter-review.md`, `ironboi-myo-loop-review.md`, and `ironboi-phase-0-status.md`. They already capture most of the highest-severity items. This audit cross-references them (marked **[prior]**) so engineering effort isn't duplicated, and adds net-new findings (marked **[new]**) from a line-by-line read of the iOS, Firebase Functions, and PWA code.

---

## 1. Executive Summary

IronBoi is a three-surface fitness app:

- **iOS SwiftUI app** (`ios/IronBoi/`) — Sign in with Apple, talks to Firebase Functions over Bearer-token HTTPS, mirrors Firestore via snapshot listeners.
- **Firebase Functions (TypeScript)** (`functions/src/`) — coach orchestration with Anthropic and Gemini providers, Zod-validated callables and HTTP endpoints, regex-based safety classifier, per-user daily token caps.
- **Vite/React PWA** (`src/`) — a single 1,681-line `App.jsx` (979 KB on disk!) with inline base64-encoded exercise images, deployed via Vercel. Labeled "Iron Lab v2" in the HTML title and "legacy_pwa" in the data migration code — this surface appears to be in the process of being deprecated in favor of the iOS app.

**Headline ratings:**

| Area | Rating | One-liner |
|---|---|---|
| Architecture | **B−** | Clear server/client split and tight Firestore rules, but several "documentation pretending to be enforcement" patterns. |
| Code quality (iOS) | **B** | Reasonable SwiftUI; one duplicated detail-sheet block; stringly-typed onboarding step coupling. |
| Code quality (PWA) | **D** | Monolithic 1,681-line file with **base64 JPEG payloads inlined into JS** (~900 KB bloat). Deferred — being replaced. |
| Code quality (functions) | **B+** | Strong Zod usage, parameterized secrets, careful tool-arg sanitization. Some schema-coverage gaps. |
| Security | **B** | Server-only writes for sensitive collections; userId always derived from auth on the server. Several footguns documented below. |
| Performance | **B−** | No N+1 queries; usage caps in place; iOS snapshot listeners well-scoped. Some unbounded subcollections (counter-review #7). |
| Accessibility / UX | **B−** | Dynamic Type is mostly correct; a few fixed-point heights will clip at larger text sizes. PWA has zero accessibility affordances. |

**Top 5 things to fix this week:**

1. **Confirm `profile/current` is server-only-writable.** If the Firestore rule allows client writes, onboardingStep and activeProgramProposalId can be poisoned. **[new]**
2. **Remove `userId` and `idempotencyKey` from `tool-calls.ts` schemas.** They invite the alias-bypass the counter-review already warned about — defense should live entirely in the executor. **[new]**
3. **Add `.strict()` to every Zod object schema in `contracts/`.** Today Zod silently strips unknown fields. **[new]**
4. **Inline base64 images in `src/App.jsx` are 900+ KB on disk.** Move to `/public/exercises/*.jpg` or hosted CDN URLs and lazy-load. **[new]**
5. **The four Phase 0 PRs (timeout caps, Gemini key in header, streaming write throttle, turnId correlation, per-user daily cap) are critical-path** and already scoped — ship them. **[prior]**

---

## 2. Architecture Overview

```
┌──────────────────────────┐         ┌──────────────────────────┐
│  iOS app (SwiftUI)       │         │  Web PWA (React/Vite)    │
│  - Apple Sign-In         │         │  - Apple OAuth popup     │
│  - AppModel listeners    │         │  - localStorage cache    │
│  - Voice input (Speech)  │         │  - Inline base64 imgs    │
└──────────┬───────────────┘         └─────────────┬────────────┘
           │ HTTPS Bearer                          │ Callable
           │ + Firestore snapshot                  │ + Firestore snapshot
           ▼                                       ▼
┌─────────────────────────────────────────────────────────────┐
│  Firebase Functions (us-central1, Node 22)                   │
│  ── HTTP endpoints (CORS *, manual bearer verify)            │
│     resetMyDataHttp, startWorkoutSessionHttp,                │
│     finishWorkoutSessionHttp, sendCoachMessageHttp,          │
│     sendOnboardingAnswerHttp, acceptProgramProposalHttp      │
│  ── onCall endpoints (auto-verified)                         │
│     getCoachBootstrap, getUserState, upsertProfile, etc.     │
│  ── onDocumentCreated trigger                                │
│     onUserCoachMessageCreated → orchestrateCoachTurn         │
│       ├─ classifyUserMessage (regex preflight)               │
│       ├─ checkDailyUsageCap                                  │
│       ├─ loadCoachContext + buildCoachContextBundle          │
│       ├─ retrieveResearchCorpus (in-memory, 13 entries)      │
│       ├─ assembleCoachSystemPrompt                           │
│       ├─ selectCoachModelProvider → Anthropic OR Gemini      │
│       └─ classifyUserMessage (postflight on model output)    │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
              ┌────────────────────────────┐
              │  Firestore                 │
              │  Strict per-user rules,    │
              │  server-only writes on     │
              │  messages/activeWorkout/   │
              │  programProposals/usage    │
              └────────────────────────────┘
```

The split is clean. The HTTP surface duplicates much of the callable surface — primarily, it appears, because the iOS app talks to it directly with a manually constructed Bearer-token POST rather than using the Firebase Functions iOS SDK callable. That choice is worth revisiting (it forces the team to maintain bespoke CORS, manual ID-token verification, and per-endpoint method/route plumbing in 6+ places), but it works.

---

## 3. Findings

Severity scale:
- **Critical** — exploitable today or causes near-term outage.
- **High** — credible abuse vector or significant correctness bug.
- **Medium** — quality, perf, or maintainability issue likely to bite within 6 months.
- **Low** — polish, cleanup, or a notable footgun.

### 3.1 Security & Privacy

#### S-1 (High, [prior]) — HTTP endpoints set `Access-Control-Allow-Origin: *` and `invoker: "public"`
**Files:** `functions/src/index.ts:289–290, 438–439, 473–474, 593–594, 669–670, 700–701`

All six `onRequest` handlers (`resetMyDataHttp`, `startWorkoutSessionHttp`, `finishWorkoutSessionHttp`, `sendCoachMessageHttp`, `sendOnboardingAnswerHttp`, `acceptProgramProposalHttp`) advertise `Access-Control-Allow-Origin: *` and accept any caller. The bearer-token verification (`verifyBearerUserId`, line 129) does run before any state-changing work — verified. So the realistic risk is not unauthenticated abuse but: any malicious site can trick a signed-in user into making cross-origin requests with their own Firebase ID token (via a stolen token from a vulnerable PWA, since the PWA doesn't currently use HttpOnly cookies for the ID token).

**Recommendation:** Restrict CORS to the production PWA origin and the iOS app's bundle ID. The iOS app uses native URLSession and doesn't need CORS at all — for those endpoints, prefer `cors: false` and rely on bearer auth only.

#### S-2 (High, [prior]) — Gemini API key in URL path
**Files:** `functions/src/coach/modelProvider.ts:92`

`https://generativelanguage.googleapis.com/v1beta/models/${this.model}:generateContent` with `x-goog-api-key` header — actually the header form is correct here; the model name is in the path, not the key. Re-verified the counter-review's #2 item: it stated "Gemini API key in URL" but the current code passes it via `x-goog-api-key`. **This may already be fixed**; verify against the original concern.

#### S-3 (Critical, [new]) — `profile/current` writes may not be gated
**Files:** `firestore.rules:46–48` shows `allow read, write: if owns(userId);` for `profile/current`. **Confirmed: this is client-writable.**

The onboarding state machine in `functions/src/onboarding/flow.ts:82` reads `current.onboardingStep` directly from the profile to decide which field to normalize from the next answer. A client can write `onboardingStep` themselves before posting an answer to force normalization into a different bucket — e.g., the client claims they're answering `weightKg` while actually replying to the `goals` step, and the parser stores `weightKg=undefined`. Recoverable but a poison vector.

Worse: a client could also write `activeProgramProposalId` and `onboardingStatus = "complete"` directly into `profile/current` and the iOS app would happily skip onboarding entirely (`IronBoiApp.swift:25`), bypassing safety policy collection.

**Recommendation:** Split the profile document. Move onboarding state (`onboardingStep`, `onboardingDraft`, `onboardingStatus`, `onboardingMissingFields`, `activeProgramProposalId`) to a sibling doc like `profile/onboardingState` with `allow read: if owns(userId); allow write: if false;` so only the server can mutate it. Keep user-editable identity fields (`heightCm`, `weightKg`, `goals`, etc.) on `profile/current`.

#### S-4 (High, [new]) — `userId` is part of the tool-call wire schema
**File:** `functions/src/contracts/tool-calls.ts:11`

`ToolCallBase.userId: z.string().min(1)` is required on every tool call. The `tools/executor.ts:14` registry strips a finite alias set (`userId`, `uid`, `user_id`, `userID`) before re-injecting from auth context — defensive, but only as good as the alias set. If a model invents `targetUserId`, `ownerId`, `subjectId`, or `userid` (lowercase!), the strip misses it and the tool sees a foreign user. The schema literally instructs the model to include this field.

**Recommendation:** Remove `userId` and `idempotencyKey` from `ToolCallBase`. Validate with a userId-free schema, then have the executor unconditionally inject `userId: ctx.authenticatedUserId`. Add a unit test that supplies four alias variants and asserts none reach the handler.

#### S-5 (High, [new]) — Zod schemas silently strip unknown fields
**File:** `functions/src/contracts/coach-agent.ts`, `functions/src/contracts/tool-calls.ts`

No `.strict()` calls anywhere. Default Zod behavior on `z.object({...})` is `.strip()` — unknown fields are silently dropped. This means:

- A model that hallucinates `{"tool":"log_workout","workout":{...},"system":"sudo"}` parses cleanly, with `system` silently dropped — fine if you trust the strip, dangerous if any downstream code does `Object.assign(persisted, parsedToolCall)`.
- A regression that adds a new safety field server-side won't be caught by old client builds that send the old shape — they'll silently fail to send the new field.

**Recommendation:** Add `.strict()` to every object schema in the contracts. Failures should be loud.

#### S-6 (Medium, [new]) — `decidedAt` and `timestamp` are client-supplied
**Files:** `functions/src/onboarding/flow.ts:31, 229`; `functions/src/index.ts:625–642`

`AcceptProgramProposalRequest.decidedAt: z.string().datetime()` is taken from the client and used as the canonical `decidedAt` on the proposal document. `serverDecidedAt` is captured alongside, so the truth is recoverable, but downstream consumers may use the client value.

`sendCoachMessageHttp` similarly trusts `timestamp` from the client and writes it onto the user message doc. Coupled with `messageId` collision risk (the iOS code uses `ios_\(Int(Date().timeIntervalSince1970 * 1000))` — millisecond-precision int, line 132 of `AppModel.swift`), a determined client can post-date or backdate messages.

**Recommendation:** Strip these from the wire schema and let `serverCreatedAt` / `FieldValue.serverTimestamp()` be the only timestamps. The `timestamp` field is useful for ordering optimistic UI but not for any business-logic decision.

#### S-7 (Medium, [prior]) — Regex-only safety classifier
**File:** `functions/src/coach/safety.ts:20–108`

The counter-review (#4) already covers this. Regex preflight catches obvious phrasings ("ignore policy", "chest pain") but trivially bypassed with stylistic variation ("I cnt breathe", "I'm having chst pn"). The classifier doubles as the postflight check on model output — meaning model-generated dangerous content has the same blunt detection.

**Recommendation:** Add an LLM-based judge as a second layer for the postflight pass. The preflight can stay regex (latency-sensitive); postflight has more budget.

#### S-8 (Medium, [new]) — `parseWeightKg` defaults to pounds with no unit hint
**File:** `functions/src/onboarding/flow.ts:555`

`parseWeightKg` accepts any digits and multiplies by 0.45359237 unless the user mentions "kg" explicitly. A non-American user typing "70" (kg) gets stored as 31.8 kg. This isn't a security issue per se, but it's a correctness bug that downstream nutrition math (calorie targets line 494) silently propagates.

`parseHeightCm` has a similar heuristic (line 548): `numeric > 100 ? cm : numeric * 2.54`. 100 cm is treated as inches → 254 cm. 99 cm same. Real children's heights fall in the collision zone.

**Recommendation:** Add a unit-selector to the onboarding UI (kg/lb toggle, cm/in toggle) rather than guessing from free text. The iOS app already has tap-mode (`CoachInputMode.tap`) — use it.

#### S-9 (Medium, [new]) — `acceptProgramProposal` merges entire proposal blob back into profile
**File:** `functions/src/onboarding/flow.ts:202`

Inside the accept transaction, `transaction.set(profileRef, proposal.profile, { merge: true })` writes every field of the proposed profile back to live. The proposal doc is server-only-written today, but if any future code path lets the model influence proposal content (e.g., a regen endpoint), arbitrary fields land on the canonical profile.

**Recommendation:** Whitelist the fields copied back: `["ageYears","sexOrGender","heightCm","weightKg","goals","equipment","trainingExperience","schedule","preferences","injuriesOrLimitations","dietaryConstraints"]`. Anything else on the proposal is metadata, not profile.

#### S-10 (Medium, [prior]) — `getCoachBootstrap` reads two static JSON files every call
**File:** `functions/src/index.ts:270–284`

The counter-review's #8 notes this should be cacheable. Each authenticated user gets the full `ironboi-coach.v0.json` (~5 KB) and `ironlab-seed.json` returned on demand. Add a `Cache-Control: public, max-age=3600` header or hash-pin the content.

#### S-11 (Low, [new]) — `safeLogger` regex for PII is permissive
**File:** `functions/src/logging/safeLogger.ts:43–46`

The suspicious-key regex matches `content|message|injury|weight|...`. But "memoryKind" and "agentName" are explicitly allowed (line 38–40), and `numericOrZero` results that contain weight values can leak through nested logs if they aren't keyed under one of the suspicious keys. Spot-check: a log payload like `{event: "log_workout", outcome: "saved", weight: 215}` would be partly redacted ("weight" matches suspiciousKey), but `{event: "log_workout", details: {kg: 97.5}}` would not — neither `details` nor `kg` matches suspiciousKey.

**Recommendation:** Combine an allow-list approach (only the keys in `allowedLogKeys` pass through, plus a few numeric-only allowed paths). Currently it's allow-list-with-deny-overlay; pure allow-list is safer.

---

### 3.2 Code Quality & Architecture

#### Q-1 (High, [new]) — PWA `src/App.jsx` is one 1,681-line file with base64 images inlined
**File:** `src/App.jsx`

The file is 979 KB on disk. The bloat is `EXERCISE_IMGS` (line 63), a dictionary of base64-encoded JPEGs that lives inside the React bundle. Lines 70, 77, 83, 90, 96 each contain 25–60 KB of base64 text. This:

- Inflates the JS bundle to ~1 MB before any user interaction.
- Cannot be cache-keyed independently (a single image change rebusts the JS hash).
- Defeats CDN image optimization and lazy loading.
- Triggers slow re-renders if React has to traverse the constant on hot reload.

Even though Vercel's `vercel.json:11–17` correctly disables caching on `index.html` and `/assets/*` so users get fresh code, every visit re-downloads the entire blob.

**Recommendation:** Move each image to `/public/exercises/{slug}.jpg`, reference by path, and add native `loading="lazy"` to the `<img>` tags. If this surface is being deprecated, leave it; otherwise this is the single biggest perf win available.

#### Q-2 (Medium, [new]) — Detail sheet logic duplicated in `WorkoutView.swift`
**File:** `ios/IronBoi/IronBoi/Features/Workout/WorkoutView.swift`

`PlannedExerciseDetailSheet` (line 249) and `ExerciseDetailSheet` (line 566) re-implement `hero`, `statsRow`, `musclesSection`, `cuesSection`, `videoButton`, `isTimed`, and `videoURL` near-verbatim. Same drift risk pattern as the PWA's `EXERCISE_DB` and the iOS `ExerciseKnowledge.database` — three sources of truth for the same exercise catalogue (`functions/src/domain/ironlab-seed.json`, `ios/.../ExerciseKnowledge.swift:22–64`, `src/App.jsx:381–423`).

**Recommendation:** Extract a shared `ExerciseDetailContent` SwiftUI view taking an `ExerciseLike` protocol. Move the exercise catalogue to a single source — likely Firestore `seed/{docId}` (already read by clients per `firestore.rules:113`) generated from the TS seed file at build time.

#### Q-3 (Medium, [new]) — Three sources of truth for exercise catalogue
**Files:** `src/App.jsx:14–60, 381–423, 541–576` · `ios/.../ExerciseKnowledge.swift:22–64` · `functions/src/domain/ironlab-seed.json`

`EXERCISE_LIBRARY`, `SWAP_OPTIONS`, `EXERCISE_DB`, `YT_VIDEOS` in PWA. `ExerciseKnowledge.database` in iOS. `ironlab-seed.json` in functions. There's already drift: the PWA's `Overhead Press` video ID is `2yjwXTZtzDM` (line 547) while the iOS app's is `2yjwXTZQDDI` (`ExerciseKnowledge.swift:28`) — different YouTube videos. Same exercise, two different "form tutorial" videos shown to users depending on platform.

**Recommendation:** Generate iOS and PWA constants from the JSON source at build time. Add a CI step that fails if they drift.

#### Q-4 (Medium, [new]) — iOS onboarding is stringly-typed
**File:** `ios/IronBoi/IronBoi/Features/Onboarding/OnboardingView.swift:195–244`

`choicesForCurrentStep` switches on `appModel.onboardingStep: String`. The backend's `REQUIRED_FIELDS` array in `functions/src/onboarding/flow.ts:40` is also strings. A rename on either side silently breaks: backend renames `goals` to `goalsList`, iOS silently shows no quick-choice chips for any user.

**Recommendation:** Generate a Swift enum from the TypeScript source of truth, or at minimum add a runtime assertion in the iOS view that every backend-emitted step has a matching case.

#### Q-5 (Medium, [new]) — `sessionId` collision risk in `startWorkoutSession`
**File:** `functions/src/workouts/activeWorkout.ts:47`

`sessionId` defaults to `${startedAt.slice(0,10)}_${dayKey.toLowerCase()}`. Two starts on the same day with the same `dayKey` (user starts Monday's workout, abandons, restarts an hour later) silently overwrite the previous active session and its workoutSession doc. No "session N for this day" suffix.

**Recommendation:** Append a UUID or wall-clock-ms suffix. Detect existing active session and surface "resume or restart?" to the user.

#### Q-6 (Medium, [new]) — `proposalId` uses `Date.now()`
**File:** `functions/src/onboarding/flow.ts:371`

Two rapid submissions in the same ms (very unlikely, but) or two devices in flight collide. Use `randomUUID()` — already imported in `index.ts:2`.

#### Q-7 (Low, [new]) — `App.jsx` `FitnessApp()` is a single 977-line React component
**File:** `src/App.jsx:705–1681`

Five views (planner, tracker, history, coach, philosophy) rendered conditionally in one component, twenty-something `useState` hooks. Local-mode is the same component as Firebase-mode with branches sprinkled throughout. Hard to test, hard to refactor.

**Recommendation:** Split into `<Planner />`, `<Tracker />`, `<History />`, `<Coach />`, `<Philosophy />` and lift state into a small context/store. This is moot if the PWA is being deprecated.

#### Q-8 (Low, [new]) — `localStorage.setItem` wrapped in `try {} catch {}` everywhere
**File:** `src/App.jsx:713, 718, 750, 781, 786, 801, 815, 874, 883, 889`

Tens of bare `try { localStorage.setItem(...) } catch {}` calls. Storage quota errors silently swallowed — user keeps typing, "Synced" flickers, data is gone.

**Recommendation:** Centralize storage in one wrapper that logs the quota error and warns the user.

#### Q-9 (Low, [new]) — `defaultPlan` `Sun/Sat/Fri` all duplicate the same `Pull · Width + Detail` workout
**File:** `src/App.jsx:269–295`

The default 7-day program ships with Friday/Saturday/Sunday as the exact same workout. Probably a paste-error in the seed file. The functions seed JSON would have the same issue; verify.

#### Q-10 (Low, [new]) — `coach/orchestrate.ts` writes the assistant doc 4–5 times per turn
**File:** `functions/src/coach/orchestrate.ts:79, 96, 151, 160, 188`

Initial create, optional usage-cap write, model-provider write, streaming-text writes (throttled to 1.5s), final write. The `STREAM_WRITE_INTERVAL_MS = 1_500` cap is already in (Phase 0 PR #3 from the status doc). Document expected write count per turn so cost forecasting is accurate.

---

### 3.3 Performance & Dependencies

#### P-1 (High, [new]) — PWA bundle is 900+ KB before user interaction
See **Q-1** above. The single largest issue on this surface.

#### P-2 (Medium, [prior]) — Unbounded `coachSessions/messages` subcollection
**File:** `firestore.rules:85–89` allows append-only writes, no cap.

Counter-review #7. A user with a long thread eventually hits per-document and per-query limits. `loadCoachContext` already limits to 40 most recent messages (`coach/context.ts:32`), so the LLM cost is bounded, but the doc count grows forever.

**Recommendation:** Add a TTL field override (`firestore.indexes.json` currently empty), then a scheduled cleanup function. Or rotate sessions — current code uses sessionId `"general"` (`src/App.jsx:735`, `AppModel.swift:31`), one session forever per user.

#### P-3 (Medium, [new]) — `onUserCoachMessageCreated` has `concurrency: 1`
**File:** `functions/src/index.ts:763`

A single message creation occupies one whole instance for up to 60 seconds. With `maxInstances: 20`, the global ceiling is 20 in-flight coach turns. Single-tenant today; will need raising before broader rollout. Documented intentionally in the comment at line 757–767 — keep tracking.

#### P-4 (Medium, [new]) — Snapshot listener fan-out on iOS sign-in
**File:** `ios/.../AppModel.swift:60–67`

On every auth state change, six snapshot listeners attach simultaneously (`listenForCoachMessages`, `listenForOnboardingState`, `listenForOnboardingMessages`, `listenForPendingProposal`, `listenForCurrentWorkoutPlan`, `listenForActiveWorkout`). Each pulls full doc state down. For a returning user with months of messages, that's a large initial sync.

**Recommendation:** Lazy-attach. Only listen to coach messages when the Coach tab is selected; only listen to active workout when on the Workout tab. SwiftUI's `task(id:)` modifier per view is the natural pattern.

#### P-5 (Low, [new]) — `fonts.googleapis.com` loaded synchronously in PWA
**File:** `src/App.jsx:322–328`

Document-head `<link>` injected at module evaluation. Render-blocking for first paint. Bebas Neue + DM Sans both fetched. Consider `display=swap` (already used) plus preconnect.

#### P-6 (Low, [new]) — Firestore `serverCreatedAt` index assumption
**Files:** `src/firebaseClient.js:81` orders messages by `serverCreatedAt`, but `validUserCoachMessage` rule (firestore.rules:18) doesn't require it on user writes. Server adds it via `FieldValue.serverTimestamp()` for assistant writes; user writes get it from `sendCoachMessage(Http)`. If the PWA ever writes directly via SDK without going through the function, the orderBy would silently exclude those docs.

**Recommendation:** Add `serverCreatedAt` to `validUserCoachMessage` allowed keys and require it be a server timestamp (rules-version 2 supports this).

#### P-7 (Low, [prior]) — Counter-review #5 (streaming write storm) marked as Phase 0 PR #3
Already throttled to 1.5s in `coach/modelProvider.ts:30`. Verify the PR has shipped.

---

### 3.4 UX & Accessibility (iOS)

#### A-1 (Medium, [new]) — `frame(maxHeight: 430)` on `ProposalReviewCard`
**File:** `ios/.../OnboardingView.swift:407`

Fixed-point height won't scale with Dynamic Type. On `accessibilityLarge` text size, the bottom of the proposal card is clipped — meaning the Accept button can be off-screen for visually-impaired users at the most critical moment of onboarding.

**Recommendation:** Replace with `presentationDetents([.medium, .large])` or remove the cap and let the scroll view own the height.

#### A-2 (Medium, [new]) — "Thinking…" pending state has no VoiceOver announcement
**File:** `ios/.../Features/Coach/CoachView.swift:165`

The pending coach bubble shows "Thinking…" but doesn't trigger an `accessibilityAnnouncement`. A screen reader user has to manually re-explore the chat to discover the response state.

**Recommendation:** Add `.accessibilityLabel("Coach is composing a reply")` when `isPendingCoachReply` becomes true, or fire `UIAccessibility.post(notification: .announcement, argument: "Coach is replying")`.

#### A-3 (Medium, [new]) — Alert merges error sources
**File:** `ios/.../Features/Coach/CoachView.swift:27–42`

`appModel.errorMessage` and `voiceInput.errorMessage` are bound to the same alert. Two simultaneous errors collide — second one overwrites first.

**Recommendation:** Two alerts with explicit `isPresented` per source, or a single shared error queue.

#### A-4 (Low, [new]) — Color hardcoding throughout iOS views
**Files:** `WorkoutView.swift:79, 147, 184, 222, 300, 313, 334, 391, 482, 484, 540, 613, 622, 633, 647, 651, 700` (`Color.yellow` literal)

No design-token layer. Brand color "yellow" is used as accent everywhere via the SwiftUI literal. Dark mode + high-contrast accommodations require updating ~16 call sites.

**Recommendation:** Define `Color.brandAccent`, `Color.brandSuccess`, etc. in an `Assets.xcassets` color catalog with light/dark/highContrast variants.

#### A-5 (Low, [new]) — `Image(systemName:).font(.system(size: 30))` fixed-size icons
**Files:** `CoachView.swift:134, 154`; similar pattern in OnboardingView

Fixed-point SF Symbols don't scale with Dynamic Type. For 44pt-hit-target buttons this is sometimes intentional; verify per-call-site.

#### A-6 (Low, [new]) — "Held" string on `MetricPill` when range is nil
**File:** `ios/.../OnboardingView.swift:544`

"Held" reads as the past tense of "to hold" — confusing for "withheld for safety." Reword to "Not shown" or "Suppressed for safety."

#### A-7 (Low, [new]) — Reset destructive action lives next to Sign Out in toolbar
**File:** `ios/.../OnboardingView.swift:26, 32`

Both buttons have similar prominence. The confirmation dialog mitigates fat-finger risk, but a `.tint(.red)` on Reset (matching the destructive role) would make the visual hierarchy correct.

#### A-8 (Low, [new]) — PWA has effectively zero accessibility affordances
**File:** `src/App.jsx`

Buttons use `<button>` elements (good) but no `aria-label` for icon-only buttons (e.g., the ▶ play button, line 1411). No `role="status"` on the toast (line 1652). No `aria-live` on the sync-status row (line 1074). Color contrast on `C.textDim` (`#444`) against `C.bg` (`#0a0a0a`) is 3.06:1 — below WCAG AA 4.5:1 for normal text.

**Recommendation:** If the PWA stays in service, run an axe-core audit. If it's being deprecated, document the gap.

---

## 4. What's Done Well

It would be unbalanced to only list problems. Specific strengths:

- **`tools/executor.ts:14–48` userId aliasing defense.** Detects and logs identity-override attempts. The right pattern, even with the schema-shaped footgun in S-4.
- **`safeLogger` PII redaction.** A real attempt at structured logging hygiene. Most apps don't bother.
- **Server-only writes on `coachSessions`, `activeWorkout`, `programProposals`, `usage`, `workoutSessions`** in `firestore.rules`. The threat model of "client controls only what it should" is implemented carefully.
- **Per-user daily usage caps** (`usage/cap.ts`) — message count, input tokens, output tokens, all capped, capReached flag persisted. Mature beyond what most early-stage AI products ship with.
- **`onUserCoachMessageCreated` Cloud Function config** (`index.ts:761–767`) — `timeoutSeconds: 60, maxInstances: 20, concurrency: 1, retry: false` with explanatory comments. This is exactly how to think about LLM trigger functions: each parameter has a stated reason.
- **Bearer-token verification before any state-changing work** on every HTTP endpoint, including OPTIONS short-circuit. Boilerplate done correctly.
- **`requireAdmin`** (`index.ts:82`) for the safety eval results endpoint. Admin-claim-gated, not just authenticated.
- **iOS sign-in with Apple uses a CryptoKit-derived nonce** (`AppModel.swift:71–84, 728–755`) — replay-resistant, no shortcuts.
- **The four Phase 0 PRs**, the counter-review, and the loop review collectively demonstrate this team takes feedback seriously. The audit-on-audit cadence is mature.

---

## 5. Recommended Next Steps (Ordered)

1. **Verify and remediate S-3** — confirm `profile/current` rule allows client writes today, then split out onboarding state to a server-only-writable sibling doc. Pair this with a unit test that asserts a client *cannot* set `onboardingStatus = "complete"` directly.
2. **Land the four Phase 0 PRs** if any are still open (per `ironboi-phase-0-status.md`).
3. **S-4 + S-5 together:** Add `.strict()` everywhere in `contracts/`, remove `userId` from `ToolCallBase`, write a test that supplies `targetUserId`, `ownerId`, `subjectId`, `userid` and asserts each is stripped.
4. **Q-3** — collapse three exercise catalogues into one generated from `ironlab-seed.json` at build time. Highest maintainability ROI.
5. **P-1 / Q-1** — if the PWA stays in service, deinline the base64 images. If it's being deprecated, add a banner pointing users to the iOS app.
6. **A-1** — fix the fixed-height `ProposalReviewCard` before any external user testing.
7. **S-7** — add an LLM judge layer to the postflight safety pass.
8. **Q-5 + Q-6** — switch `sessionId` and `proposalId` to UUIDs.

Items beyond this list are valuable but not on the critical path. The counter-review's items #8 (bootstrap caching), #10 (Anthropic stream cancellation), #12 (account deletion flow), and #13 (HealthKit per-sample shape) remain solid backlog.

---

## 6. Methodology & Coverage

**Files read in full:**
- `firestore.rules`, `firestore.indexes.json`, `firebase.json`, `vercel.json`, `vite.config.js`, `package.json`, `functions/package.json`, `index.html`, `.env.example`, `.gitignore`
- All of `src/`: `App.jsx` (1,681 lines, in chunks), `main.jsx`, `firebaseClient.js`
- All of `functions/src/`: `index.ts`, `firebase.ts`, `paths.ts`, `validate-phase0.ts`, `logging/safeLogger.ts`, `usage/cap.ts`, `tools/executor.ts`, `security/collectionGroup-allowlist.ts`, `firestore/userScopedCollections.ts`, `coach/{context,contextBundle,modelProvider,orchestrate,prompt,safety}.ts`, `coach/ironboi-coach.v0.json`, `contracts/{coach-agent,tool-calls}.ts`, `corpus/researchCorpus.ts`, `onboarding/flow.ts`, `workouts/activeWorkout.ts`
- All of `ios/IronBoi/IronBoi/`: `IronBoiApp.swift`, `IronBoi.entitlements`, `Services/{AppModel,VoiceInputEngine}.swift`, `Models/{CoachMessage,OnboardingModels,WorkoutModels,ExerciseKnowledge}.swift`, `Features/Coach/CoachView.swift`, `Features/Workout/WorkoutView.swift`, `Features/Onboarding/OnboardingView.swift`
- Existing audit docs: `ironboi-architecture-counter-review.md`, `ironboi-myo-loop-review.md`, `ironboi-phase-0-status.md`, `docs/audits/*`

**Files inspected but not deeply analyzed:**
- `functions/src/coach/ironlab-seed.json` and exercise/research data files (read enough to confirm structure)
- `docs/plans/*.md` (skimmed for context)
- `node_modules`, `.build/DerivedData`, `dist/`, `.git`, `.vercel` (deliberately excluded)

**Not in scope:**
- App Store / TestFlight provisioning state
- Firebase project IAM, console settings, or backup configuration
- Anthropic / Gemini billing account configuration
- Vercel project environment variables
- The actual TestFlight build of the iOS app (would need device or simulator)

**Confidence:** High for everything called out with line citations. Medium for cross-cutting claims about firestore.rules vs functions writes (would want a small enforcement test for each of the 12 server-only write rules to be sure). Low only for the deprecation hypothesis around the PWA — the "legacy_pwa" string in `App.jsx:123` strongly suggests intent, but I didn't find a roadmap doc that confirms.

---

*End of audit.*
