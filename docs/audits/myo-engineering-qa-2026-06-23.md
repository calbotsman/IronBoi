---
title: MYO Engineering QA Pass + Dispositions
date: 2026-06-23
reviewers: staff eng + 2 senior eng (parallel read-only review agents)
scope: recent work — MyoTheme v2, preview mode, Record tab, protocols/lens, citations, onboarding step
---

# Engineering QA — findings & dispositions

Three engineers ran a read-only QA pass (architecture / SwiftUI / backend). Findings below
with disposition: **FIXED** this pass, **DEFERRED** (with reason), or **VERIFIED-CLEAN**.

## Fixed this pass (verified: backend 95/95, iOS builds clean)

| Area | Issue | Fix |
|---|---|---|
| iOS correctness | `RecordView` signed-out branch gated on `user == nil`, inconsistent with other tabs | → `!hasSession` |
| iOS correctness | Fixed-format `DateFormatter`s (Record date block, `WorkoutLogSummary.day`) had no locale → fail on non-Gregorian/non-Latin device locales | pinned `en_US_POSIX` |
| iOS a11y | Citation "Informed by" line: <44pt tap target, silent no-op when no URL | now a `Button` w/ `minHeight: 44` + `.isLink`, interactive only when a URL exists; static label otherwise |
| iOS state | Save bar re-enabled in the "Saved" state (could re-save unchanged profile); 1.5s reset could clobber a newer save | disabled unless edits-or-failed; added `saveGeneration` guard on the delayed reset |
| iOS doctrine | Two filled **primary** CTAs still in destructive brick ("Start {day}", tag "Add") — escaped the earlier sweep | → `Action.primary` (ochre) + ink text |
| iOS a11y | Decorative `info.circle` in set row read by VoiceOver as unlabeled image | `.accessibilityHidden(true)` |
| iOS a11y | Record date `dayText` could clip at AX Dynamic Type in fixed 52pt block | `lineLimit(1)` + `minimumScaleFactor(0.6)` |
| iOS perf/reliability | `requireFreshFirebaseAuthToken` forced a token refresh on **every** user action | non-forcing `getIDToken()` (SDK auto-refreshes near expiry) |
| backend onboarding | `coachingLens` inserted mid-list in `REQUIRED_FIELDS` → "Last one" copy was a lie + bounced in-flight drafts backward | moved to **end** of required fields (kept as required = the hook, but now honest + non-disruptive) |
| backend retrieval | Short tags/keywords matched substrings ("back" → "background/feedback"); `.sort` ties non-deterministic | word-boundary `matchesTerm()`; deterministic `entryId` tiebreak |

## Deferred — pre-existing release-blockers, need a decision/console step (NOT regressions)

- **BLOCKER — App Check enforced only on the `onCall` twins, not the `*Http` endpoints the app actually uses.** The client now *sends* `X-Firebase-AppCheck`, but no `onRequest` handler verifies it; auth rests on the Firebase ID token alone. Fix is a project, not a quick edit: either migrate the iOS client to the `onCall` functions (which already enforce) and delete the `*Http` set, or add `getAppCheck().verifyToken(...)` inside each `onRequest`. **Enforcing requires the staging App Check debug token registered first**, or dev/sim breaks. Must close before public App Store.
- **MAJOR — Release routes to STAGING.** `IronBoiCallableBaseURL` is set via `INFOPLIST_KEY_*` under `GENERATE_INFOPLIST_FILE`, which Xcode drops for non-Apple keys → always falls back to the staging URL, Release included. Fix: hand-written Info.plist or per-config `.xcconfig` + a Release assertion that the URL isn't staging. (Already noted in code comments.)
- **MINOR — CORS `*` on the public HTTP mutation endpoints** (compounds the App Check gap). Restrict origins or drop CORS (native app doesn't need it).
- **MAJOR — split backend targeting:** 3 calls use the Firebase SDK callable (project from GoogleService-Info) while the rest use the custom wrapper (staging-fallback URL); a misconfigured build could point them at different projects. Resolve when the App Check / endpoint decision lands (prefer one mechanism).
- **MINOR — `consumeAppCheckToken: true` + cached token reuse** will replay-reject if App Check is later turned on for the high-frequency HTTP endpoints without `forcingRefresh`. Address alongside the App Check decision.

## Recommended follow-ups (real, not blockers)

- Migration completeness: Workout (~24) and Onboarding (~15) still use raw `ink.opacity()` instead of `Text.*` roles, and onboarding chips are bespoke rather than `MyoSelectChip`. Mechanical, low-risk sweep.
- Global `.tint(brick)` (IronBoiApp) tints tab selection + pickers + links brick, which sits against "brick = destructive only." **Aesthetic call for Tosh** — keep the red-pen tab selection, or move global tint to ochre and let brick be purely destructive. Left as-is pending your call (you liked the red tabs).
- Blueprint supplement/dosage guardrail is **prompt-only** (+ corpus safetyBoundaries). If hard compliance is needed, add a postflight dosage-pattern check on blueprint-lens turns.
- `finishWorkoutSession` has no idempotency key → a retried finish could double-log.
- Cache the `ISO8601DateFormatter` (allocated per message parse); add fractional-second tolerance to `parseISODate`.
- `randomNonceString` charset is missing `W` (cosmetic; SHA256-hashed, no security impact).

## Verified-clean (raised, checked, no issue)

- DEBUG/preview fencing: `startPreviewSession`, `isPreviewSession`, `signInAsDeveloper`, seed data all `#if DEBUG`; `hasSession` falls back to `user != nil` in Release. No seed-data or auth-bypass leak to production.
- `coachingLens` data-boundary integrity: instruction-to-honor lives in trusted `system`; the value lives in untrusted `<profile>`; Zod-enum constrains it to 5 values — no prompt-injection vector.
- `.strict()` preferences + `coachingLens.default("none")`: old clients omitting the field parse fine.
- Citation `sources`: server-only write, no PII (public guideline names/URLs), `undefined` correctly guarded; written only on the terminal success path (client treats `sources` as optional — correct).
- Corpus scoring: safety entries (+5 keyword, stacked tags) comfortably dominate protocol entries (+3); protocol cannot crowd out injury/pregnancy guidance.
