---
title: Training intelligence and progress in History
date: 2026-11-08
status: building
---

# Training intelligence and progress in History

The tester (the app's owner) asked for "intelligence behind workouts" and to
"see progress in History: streaks, weight adjustments, etc.", plus the missed
workout feedback from 2026-11-08 (rest day pulled the wrong session, the coach
couldn't see what was missed, the Plan screen showed no history).

## Decisions (made by the owner)

1. **Weights go up automatically, and the coach says so.** When every set of a
   lift hits its target reps at the prescribed weight, the next session starts
   one step heavier. The exercise intro names it ("Rows, 40 lb today, up 5 from
   last time"); saying "keep it at 35" keeps working as today (set_workout_weight).
2. **The streak counts weeks on plan.** Calendar weeks, Monday to Sunday. A week
   counts when the sessions logged in it reach the plan's training days for that
   week. Rest days never break it. The current week adds once it's met and never
   breaks the streak while in progress.
3. **A missed session is offered once.** On a rest day (or any day) with a
   missed planned session this week, the coach mentions it once per day when the
   app opens; never nags. "Do this today" is always on the Plan screen.
4. **All at once.** One release with all three parts.

## Shared contract (already on the branch; do not change shapes without saying so)

- TypeScript: `functions/src/contracts/coach-agent.ts`: `ProgressionEventKind`,
  `ProgressionEvent`, `PersonalRecord`, `TrainingDayStatus`, `TrainingHistory`,
  `WorkoutRecap` (read the comments, they define the semantics).
- Paths: `functions/src/paths.ts`: `trainingHistoryPath`, `progressionEventPath`,
  `progressionEventsCollection`.
- Swift: `ios/IronBoi/IronBoi/Models/WorkoutModels.swift`: `TrainingHistoryModel`
  and friends, `init?(firestore:)`; `AppModel.trainingHistory` (published, kept
  live by a snapshot listener on `derivedSummaries/training_history`).
- Firestore: `derivedSummaries/*` is owner-readable, server-written (rules
  already allow). `progressionEvents` is server-only (no client rule needed).

Units: History and the app speak **pounds**. Workout logs store `loadKg` per
set; convert with 2.20462 and round to the nearest 0.5 lb for display values.

## Part S: server (functions/)

1. **Progression events.** Every change to a lift's prescribed weight writes a
   `ProgressionEvent` (`progressionEventPath`), with a plain-words `reason`:
   - weekly rollover (`workouts/rollover.ts`, the per-exercise gate:
     advance / hold_missed_reps / hold_not_trained / deload) → `weekly_up`,
     `hold_missed_reps`, `hold_not_trained`, `deload`. Write holds too: they
     explain why a weight didn't move.
   - session progression (below) → `session_up`.
   - at finish, any exercise whose logged working weight differs from what was
     prescribed → `changed_in_workout` (from = prescribed, to = lifted).
   - approved plan adjustments that change a weight → `plan_change` where it's
     simple to do; skip if it isn't.
   Event ids must be deterministic (e.g. `${date}_${kind}_${exerciseKey}` or
   with the sessionId) so retries don't duplicate.
2. **Session progression ("double progression").** In `finishWorkoutSession`
   (`workouts/activeWorkout.ts`): for each lift with load (> 0) where every
   prescribed set was completed with reps ≥ target at a weight ≥ prescribed,
   raise its baseline/anchor one step for next time (use the existing
   progression step for that exercise from `progressionDefaults.ts` /
   `exerciseBaselines.ts`; sensible default 5 lb, 2.5 lb for light isolation
   lifts if the code already distinguishes). Re-anchor (anchorDate = today) so
   the weekly rollover does NOT add a second step for the same week: the weekly
   gate must not double-count. Timed / cardio / bodyweight lifts are excluded.
   Respect the existing ceiling and plate rounding.
3. **Training history builder.** A pure function (like `progress/build.ts`)
   plus a store that writes `trainingHistoryPath`:
   - inputs: workout logs (enough history for the best streak, cap ~1 year),
     the plan (`workoutPlans/current` + `trainingPrograms/current` for which
     weekdays are training days and their names/muscles; muscles can come from
     the exercise catalog per exercise), baselines, progression events,
     profile (createdAt), and `today` (the user's local date: use the
     clientDate the app already sends where available, else server date).
   - streak per decision 2; calendar for the last 8 full weeks + this week;
     `missedThisWeek` (past planned days this week with no log, most recent
     first, with muscles); `recentMuscles` (yesterday + today);
     `thisWeek`; `lifts` (top 12 by recency, with events newest first, e1RM
     series by session, top PRs); `recentRecords`.
   - Personal records: per exercise, heaviest weight; most reps at a weight
     lifted before; best e1RM (Epley, top set). Only count real sets
     (reps and load > 0). A record is "set" on the session that first beats
     the previous best.
   - Rebuilt at the end of `finishWorkoutSession` (don't fail the finish if it
     throws; log it) and lazily when stale (reuse the progress summary's
     staleness callable/flow: when the app asks for progress, also rebuild
     this if older than an hour or missing).
4. **Workout recap.** `finishWorkoutSession` returns `recap: WorkoutRecap` in
   its result (records set this session, next-time weight changes from step
   2, top-set deltas vs the previous time each lift was done, volume vs the
   previous session, streak). Keep the existing return fields unchanged.
5. **Coach context.** Give the coach the week and the progress:
   - in `coach/contextBundle.ts` / `coach/prompt.ts`: a compact `<this_week>`
     (each day Mon→Sun: status + name) and `<lift_progress>` (per lift: start →
     current lb, last change and why, PRs) from the training history doc.
     Also add these to the live voice memory brief / instruction if that is
     where live gets its context (`coach/memoryBrief.ts`, `coach/liveSession.ts`).
   - prompt rules: on a rest day or when asked to train/adjust, if
     `missedThisWeek` is non-empty, offer the most recent missed session that
     doesn't hit `recentMuscles`, by name; a few missed sessions this week are
     NOT a layoff, never propose a returning_from_layoff ramp when the user
     trained in the last 10 days (enforce server-side in the adapt_plan
     validation, not just the prompt); name weight changes plainly ("rows went
     up 5, you hit every rep last time").
6. **Tests.** Unit tests for the builder (streak edge cases: rest days, partial
   current week, plan with N days; calendar statuses; PR detection; lb
   conversion), session progression (all reps hit → up one step; missed reps →
   no change; bodyweight/timed excluded; no double step with the weekly
   rollover), events written with deterministic ids, recap shape, and the
   ramp guard. Follow the existing test layout in `functions/test/security/`.
   Emulator-backed tests: `npx -y firebase-tools emulators:exec --only firestore
   --project demo-ironboi-security "npx vitest run test/security --fileParallelism=false"`.

## Part H: History screen (iOS)

`Features/Record/RecordView.swift` (rewritten recently to the current design:
display headline, `MyoSectionLabel` + `MyoGroupCard` groups, sessions by month).
Read `appModel.trainingHistory`; keep the existing progress sections only where
they don't duplicate the new ones.

1. **Streak** at the top: "N-week streak" big, best streak small, this week's
   "3 of 4 sessions" and a calendar strip of the 9 weeks (7 dots per week:
   done filled, missed marked, rest faint, today ringed, planned outlined).
2. **Lifts**: one row per lift: name, current weight, change since start
   ("+15 lb since Oct 13"), a small e1RM line when ≥ 3 points. Tapping opens a
   detail view (pushed in the same NavigationStack) with the full timeline of
   events, newest first, each with date, from → to and the reason in plain
   words, PR badges, and the e1RM line.
3. **Personal records**: the recent records list ("Heaviest: KB Goblet Squat 35
   lb × 10, Nov 4").
4. **Session detail**: tapping a session row (sessions by month, already there)
   opens every exercise with each set's weight × reps, and "vs last time"
   deltas computed on the phone from `appModel.workoutLogs` (the logs already
   carry sets; extend `WorkoutLogSummary`/`LoggedSet` parsing only if needed).
5. Empty / partial states: no history doc yet → the existing layout; a lift
   with no events → just the weights.

## Part W: the workout brain in the app (iOS)

1. **Post-workout recap.** Decode `recap` from the finish callable's response
   in `AppModel.finishActiveWorkout()` and publish it. Show it on the coach
   stage after a workout (look at `Features/Coach/AfterWorkoutCards.swift` and
   how the effort card / cooldown offer appear) as a simple card: records
   ("New best: …"), "Next time: Rows 40 lb (+5)", streak. The coach's
   wrap-up line says the headline (one PR or one weight up) briefly. Dismissible.
2. **Exercise intro names the weight change.** When introducing an exercise
   (`introduce(exercise:)` in `CoachStageView.swift`), if the lift's latest
   event in `trainingHistory.lifts` is a `session_up`/`weekly_up`/`deload`
   since the last time it was done, add one short clause ("40 lb today, up 5
   from last time"). Never more than one clause; respect tips == .quiet.
3. **Rest day / missed sessions.** `askSkipRestDay` / `answerSkipRestDay` and
   `AppModel.nextPlannedDay`: offer the most recent `missedThisWeek` session
   whose muscles don't overlap `recentMuscles`, by name ("You missed
   Thursday's Upper Pull. Want to do it today?"); fall back to the next planned
   day only when nothing was missed. Once per day when the app opens on a day
   with a missed session and no workout yet: one short offer, stored so it
   isn't repeated that day (UserDefaults keyed by date is fine).
4. **Plan screen** (`Features/Workout/WorkoutView.swift`, `WeeklyPlanView` /
   `PlannedWorkoutDayCard`): each day shows its status from
   `trainingHistory.calendar` for this week: ✓ Done (with the logged name),
   Missed, Today, Upcoming, Rest. Missed days get the "Do this today" button
   (the confirm + land-on-coach flow already exists there).

## Rules for every part

- **No new iOS source files.** The Xcode project (`project.pbxproj`) is
  committed and can't be regenerated here (no xcodegen/Xcode on Linux); CI
  builds the committed project. Add Swift code to existing files only. Tests go
  in existing test files (`ios/IronBoi/IronBoiTests/WeightLoadTests.swift`
  compiles the files listed in `project.yml` for that target).
- There is no Swift compiler here: read your Swift carefully (member names,
  access control, optionals, `@MainActor`, SwiftUI builder rules). Keep
  `CoachStageView.body`'s modifier chain from growing: CI hit "unable to
  type-check this expression in reasonable time" there; add new `.onChange`
  etc. to `animatedStage` or a helper instead.
- Follow the design system (`Theme/`): `MyoGroupCard`, `MyoSectionLabel`,
  `myoStyle`, `MyoColor`, 44 pt targets. Keep it simple and readable from a
  distance.
- Match the surrounding code's style and comment voice (short "why" comments).
- Backend: `npx tsc --noEmit` must pass; run the tests you touch.
