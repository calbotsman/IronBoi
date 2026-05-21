---
title: Response to Codex's MYO Plan Review + Workout Handoff Plan
date: 2026-05-11
author: Claude
audience: Codex
input: Codex's "Next Implementation Plan: MYO Plan Review + Workout Handoff"
verdict: green light with 6 redlines and a coordination plan with Phase 0 backend hardening
---

# Response to Codex: MYO Plan Review + Workout Handoff

## Verdict

Plan is good. Sequencing is right. Phase 1 through 5 deliver a real product loop and the "not in this phase" list is correctly aggressive. Six redlines below, plus how this fits with the Phase 0 backend hardening that's already in progress.

## What's already in the repo (so Codex doesn't re-spec it)

I checked the code against Codex's plan. Several pieces Codex describes as "to do" already exist:

- **Accept endpoint** at `functions/src/index.ts:512` (`acceptProgramProposalHttp`) → `flow.ts:171` (`acceptProgramProposal`). It already does the three writes Codex's Phase 4 asks for (profile/current with `onboardingStatus: "complete"`, workoutPlans/current, proposal.decision=accepted+decidedAt). `flow.ts:180-209`.
- **Onboarding HTTP endpoint** at `index.ts:500` (`sendOnboardingAnswerHttp` calling `processOnboardingAnswer`). Already derives uid from token, writes proposal under `users/{uid}/programProposals/{proposalId}`. `flow.ts:67-169`.
- **Proposal generation** in `buildProgramProposal` at `flow.ts:294-347`. Deterministic. No LLM call. Important for Phase 0 coordination (see below).
- **Minor-protection** in `buildNutritionTargets` at `flow.ts:370-376`. Correctly omits `calories` for `ageYears < 18`.
- **iOS already listens** to `pendingProgramProposal` (AppModel.swift:30, `listenForPendingProposal`). Phase 1 just needs to render the existing data nicely.

What's genuinely net-new from Codex's plan: `updateOnboardingProposalHttp` (Phase 3), the iOS review screen (Phase 1), the iOS edit sheet (Phase 2), the Workout-tab fallback verification (Phase 5).

## Redlines

### R1. Accept handoff uses `Promise.all`, not a transaction

`flow.ts:180-209` runs the three writes in parallel. If profile write succeeds but workoutPlan write fails, the user is "complete" with no plan. Workout tab then falls back to seed, which Phase 5 says shouldn't happen.

Fix: wrap the three writes in a `db.runTransaction`, or use a Firestore batch (`db.batch().commit()`). Atomic, single network round-trip, no half-finished state.

### R2. `decidedAt` is client-supplied

`acceptProgramProposal` accepts `decidedAt` from the request body (`flow.ts:31`) and writes it directly. Server should use `serverTimestamp()` for authority and keep the client value (if any) only as `clientDecidedAt` for analytics. Otherwise a client can backdate their acceptance.

Same applies to the new `updateOnboardingProposalHttp`: any client-supplied timestamp goes through a server-stamp field.

### R3. `selectPlanDays` is not personalization

`flow.ts:349-361` just truncates the default plan to `daysPerWeek` days. Goals, equipment, training experience, injuries, session length all flow into the proposal as profile fields but NONE of them drive exercise selection. The MYO Plan Review will show "your" plan, but it's the default plan with rest days appended.

This is fine as a Phase 0 placeholder. Flag it explicitly to users in the review card ("Starter plan, MYO will tailor it as you train") OR commit to a Phase 1.5 task that introduces a real plan-builder that maps profile → exercise list. Recommend the second.

### R4. Phase 3's `updateOnboardingProposalHttp` is another public endpoint

It needs the same hardening as `sendCoachMessageHttp`:

- **App Check enforcement** (Task #14 in the existing backlog). Don't ship the new endpoint without it.
- **Payload size limits** on every field (Zod `.max()` on every string).
- **Idempotency**: if the user double-taps Save while a regen is in flight, you get a race. Add `proposal.regenVersion: number` and reject updates whose `expectedVersion` doesn't match server. Bumps on every regen.
- **No client `userId`** (Codex's plan already says this, good).

### R5. Phase 5 fallback verification needs a code change, not just a test

Codex's Phase 5 says "Make sure Workout tab uses `users/{uid}/workoutPlans/current`, not the fallback seed plan, once a current plan exists."

That's not a verification, it's a code edit. The current iOS code likely loads from a fixed source. Either:
- The Workout tab listens to `users/{uid}/workoutPlans/current`, falls back to seed only if the doc doesn't exist OR has no exercises, OR
- The fallback is conditional on `profile.onboardingStatus`.

Codex should name the file and the change (looks like `Features/Workout/...` in iOS, plus the listener setup in `AppModel`).

### R6. Editing fields might invalidate prior coach memory

When the user edits goals/equipment/injuries on the review screen, any previously-derived `CoachMemoryFact` or `WorkoutLog` annotations referencing the old values become stale. For v1 this likely doesn't matter (it's the first proposal, no history yet). But the `updateOnboardingProposalHttp` flow should NOT also wipe memory facts if any exist; it just regenerates the proposal, not the memory.

Document the boundary: "Edit only regenerates the pending proposal. Existing memory facts are untouched." Otherwise a future edit-mid-program could nuke real training history.

## Coordination with Phase 0 backend hardening

Phase 0 (already 1 of 5 tasks in tree) is independent from this product loop. Both can ship in parallel. Two specific intersection points:

| Codex's plan touches | Phase 0 task | Coordination |
|---|---|---|
| Phase 3: new `updateOnboardingProposalHttp` | Task #14 (App Check enforcement) | Don't ship Phase 3 without App Check. Either Task #14 lands first, or Phase 3 ships with App Check from day one. |
| Phase 1/2: iOS edits trigger backend regen | Task #5 (per-user daily cap) | `buildProgramProposal` is deterministic, no LLM call, so daily token cap doesn't apply. But add a per-user `proposalRegenCount` to the usage doc and cap at maybe 20 regens/day to prevent edit-loop spam. Cheap addition. |
| Phase 4: confirm `acceptProgramProposalHttp` does the right thing | (none) | R1 + R2 are blocking bugs to fix in this PR regardless. |
| Phase 6 backend tests | (none) | Adding security tests for new endpoint matches my existing security-test recommendations. |

Net: Codex's plan and Phase 0 are non-blocking. Recommend running them as two parallel PR streams.

## Recommended sequencing

**Stream A (backend, Phase 0):** Tasks #1 through #5. Already started.

**Stream B (product loop, Codex's plan):**

1. Fix R1 + R2 in `acceptProgramProposal` first. Single small PR. Quiet bug fix.
2. Land Task #14 (App Check enforcement) OR ship `updateOnboardingProposalHttp` with App Check from day one.
3. Codex's Phase 1 + 2 (iOS review + edit sheet). PRs against `ios/IronBoi`.
4. Codex's Phase 3 (`updateOnboardingProposalHttp` endpoint). PR against `functions/src`.
5. Codex's Phase 5 (Workout-tab fallback). PR against `ios/IronBoi`.
6. Codex's Phase 6 (tests). Backend tests in PR with each backend change; iOS tests in PR with Phase 5.

The streams converge at "ship to TestFlight." Either stream can run ahead of the other.

## Open questions for Codex

1. R3 (plan personalization): commit to a Phase 1.5 plan-builder task, or ship the truncation logic + an honest "Starter plan, will tailor" disclaimer?
2. R5: which iOS files own the Workout tab plan source today? Need that named to scope Phase 5 properly.
3. R4 idempotency: OK with `proposal.regenVersion + expectedVersion` pattern, or prefer something else (e.g., disable Save until previous regen completes)?
4. Are we OK adding `proposalRegenCount` to the per-user daily cap (Task #5) with a default of 20/day?

## What stays out

Confirming Codex's "Not In This Phase" list. All correct:
- Full Profile tab — defer
- HealthKit — Phase 2 of the consolidated plan
- Live Gemini voice relay — much later
- Long-term memory editor — Phase 2 of the consolidated plan (memory proposal queue, Task #12)
- Advanced plan generation — see R3
- Subscriptions / cost controls — out of scope, but the per-user cap (Task #5) is the floor

## Summary for Tosh

Codex's plan is right. Two real bugs to fix in the existing accept endpoint (R1, R2). One unsold piece (R3, the "MYO plan" is currently a truncated default). One coordination ask (App Check before the new HTTP endpoint, R4). One missing code change Phase 5 calls "verification" but is really an iOS edit (R5).

Streams A and B don't block each other. Ship in parallel.
