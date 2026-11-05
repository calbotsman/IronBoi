# Watchdog findings

*Updated 2026-11-05. Most severe first. CONFIRMED = read in the code. PLAUSIBLE = depends on runtime data or a device.*
Audited: #39, #40, #41 (merged), #44 (open; rebased to 86e8a6a, mergeable).

## High

**F1. #41: "I'm going for a run" adds a run to the end of the workout. Josh's idea is that it replaces the session. CONFIRMED**
`ios/IronBoi/IronBoi/Features/Coach/WorkoutEdits.swift:125` (`cardioRequest`; the `i'm going for` alternation is about 6 lines further down).
Scenario: mid-workout, the user says "I'm not doing that, I'm going for a run". The phone matches `i'm going for` plus the cardio word "run" and returns `.addCardio("Run", 20, now: false)`. The coach replies "Got it: run, 20 minutes, added at the end." The strength session stays in place and is later saved to Health as strength (#39). The coach model never sees the turn, because the phone handles it first.
Hardcoding: this is a regex phrase table, the "fixed phrase rules" approach ideas.md rules out. Whoever builds the voice workout replacement has to remove or override this path; adding a coach action on top of it isn't enough.

**F2. #41: three catalog lifts are reclassified as cardio. Their planned reps now run as seconds. PLAUSIBLE**
`functions/src/workouts/exerciseCatalog.ts:267` (`CARDIO_PATTERN`) and its iOS twin in `Models/ExerciseKnowledge.swift`.
The catalog entries "Zone 2 Walk/Jog", "Jump Rope" and "Incline Walk" were never `timed`. They now match the cardio pattern, so `isTimedExercise` and `isCardio` are true for them. Scenario: a plan prescribes Jump Rope 3 × 50. The card shows "3 min" (50 × 3 s), "go" starts a 50 s timer, and the log records `durationSec: 50`. The "count" is now a duration. Words outside the catalog fare similarly: "Bike Crunch", "Duck Walk" and "Sled Walk" also count as cardio. The drift test only checks that the two regex strings match each other, not the catalog.

**F3. #44: plan items dropped without saying so, and one dead field. CONFIRMED**
The PR body only mentions dropping `verbosity`. These are also gone: `paceSecPerRep` and the fatigue rule, `typeMix` and the "no mobility in 14 d" rule, `lastSameDayKey`, and `voiceLevel`/`musicDip`/`captionsOn` in delivery. `session.lastSetSec` is in the zod contract and the server prompt (`functions/src/coach/liveWorkout.ts:89`), but `AppModel.liveCoachContext()` (`AppModel.swift:545` on the PR branch) never sets it, so "Their last set took …" can never appear.

**F4. #44: the heart-rate path has no source, and trend/recovery are never computed. CONFIRMED (disclosed in part)**
`ios/IronBoi/IronBoi/Services/CoachContext.swift:138`: nothing calls `HeartRateHub.publish`. The PR does say the hub is empty until Phase 2. What it doesn't say: nothing anywhere computes `HeartSample.trend` or `recoveryDrop60`. They are optional fields the publisher would have to fill, so the "dropped under 12 bpm" rule has no data until Phase 2 builds it. `CoachStageView` doesn't observe `HeartRateHub`, so even once it's fed, an HR change won't trigger a voice context push. The plan's 30 s HR cadence is missing.

**F5. #44: the voice note leaves out rest elapsed, so device check #1 can't pass. CONFIRMED**
`CoachContext.swift:71` (`voiceNote`) sends "resting (90 s planned)" but not seconds elapsed. Text turns get the elapsed time; live voice doesn't. Scenario: live voice, 40 s into rest, "how long should I rest?" The coach knows only the plan (90 s) and can't answer "50 more". The PR's first device checkbox expects the real rest numbers.

**F6. #44 rebase: resolved.** At 86e8a6a it's mergeable, and #41's cardio wording survives in `liveWorkoutRules`. F3, F4 and F5 are unchanged by the rebase. Five build sessions branch from #44, so they inherit F3–F5 and F8–F9.

## Medium

**F7. #39: the PR says a re-save replaces the workout. With a fixed sync version it doesn't. Activity type is a name match. CONFIRMED**
`ios/IronBoi/IronBoi/Services/HealthSync.swift:66`: `HKMetadataKeySyncVersion: 1` is fixed. The SDK header (HKMetadata.h:143) says an object with the same sync identifier only replaces the existing one if its version is *greater*. So a second save is dropped, not replaced. There are still no duplicates, but the PR claim is wrong, and an edited session can never update in Health.
`HealthSync.swift:78`: `.flexibility` only if the day name contains "mobility"; everything else is strength. A run or cycling session is logged as strength (see F1). Plan Phase 2 needs the same session id as sync identifier, plus the "watch owns the save" flag. Neither exists yet. That's expected, since it's Phase 2.

**F8. #44: "last two felt too much" can span weeks. CONFIRMED**
`CoachContext.swift:29`: `recentEfforts` takes the last 3 *rated* logs and skips unrated ones. Scenario: two too-much ratings in September, then six unrated sessions. The coach is still told "their last two workouts felt like too much". The same applies to the "easy" rule.

**F9. #44: `extend_rest` reports success before anything happens. CONFIRMED**
`AppModel.swift:534–539`: it returns `ok: true, addedSeconds` after setting `restExtensionRequest`. The timer only changes if `CoachStageView` is mounted to catch the `onChange`. Scenario: the user is on another tab and the live coach is still connected. The coach says "I've given you 30 more seconds" and the timer is unchanged. The server tells the coach not to cue the next set until HR drops, but the phone's own rest timer still says "Go." on schedule, so the coach and the app can disagree.

## Low

- **#44 efficiency:** `appModel.liveContextNote` is a computed property read in `CoachStageView`'s body modifier (`CoachStageView.swift:208`). Every re-render, including every counted rep, rebuilds the whole context: it queries `AVAudioSession` and walks all workout logs.
- **#44 hardcoded key:** `CoachContext.delivery` reads `"coachSpeaksReplies"` as a literal instead of `CoachMix.voiceOnKey`.
- **Tests:** there is no iOS test target. All Swift logic is untested: the #41 cardio parser and minutes parser, #44 rhythm/zones/voiceNote, #40 `voiceGainDB`, #39 `activityType`. #44's server tests are mostly `toContain` on prompt strings, so they mirror the implementation. They do usefully cover the stale-HR gate and that a bad `liveContext` is dropped without dropping the message. #41's iOS↔server regex drift test and the emulator log test are real behaviour tests. #39 and #40 have no tests at all.
- **Plan evals (P1.14) not written.**

## Checked and fine

- **Hallucinated APIs: none found.** Checked against the iPhoneOS 26.2 SDK headers and Apple docs, all available at iOS 17: `HKHealthStore.requestAuthorization(toShare:read:)` async, `HKWorkoutBuilder(healthStore:configuration:device:)`, `beginCollection/addMetadata/endCollection/finishWorkout` async, `HKMetadataKeySyncIdentifier/SyncVersion/WorkoutBrandName`, `AVAudioUnitEQ.globalGain`, `kAudioUnitSubType_PeakLimiter`, `voiceProcessingOtherAudioDuckingConfiguration` with `.min`/`.mid` (iOS 17, guarded), `isOtherAudioPlaying`, `secondaryAudioShouldBeSilencedHint`.
- **Gemini Live `clientContent` with `turnComplete: false`:** per the Live API docs only `turnComplete: true` interrupts generation, so #44's context notes shouldn't cut the coach off. Still worth the planned device check.
- **#40 is clean:** gain maths matches its comment (0 dB at default 0.75, +6 at max, +6 Light lift, limiter after), and captions mode really uses `.mixWithOthers` with voice processing off. Haptics are called on the main thread. No scope drift. It is untested on device, and the PR says so.
- **#41 server side** (timed cardio in the prompt, `durationSec` in logs) matches the PR body and is tested.
- **No test or preview data leaks** into real paths in any of the four PRs (`inPreview` in #44 is the existing DEBUG preview gate).
- **Scope:** no unrelated changes in any of the four PRs.
