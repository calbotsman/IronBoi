# Watchdog findings

*Updated 2026-11-05. Most severe first. CONFIRMED = read in the code. PLAUSIBLE = depends on runtime data or a device.*
Audited: #39, #40, #41 (merged), #44 (open; rebased to 86e8a6a, mergeable), #46 (open, own commit 3d9bee2), #49 (89c9e6d), #50 (2f8d8a7+5ba189c), #51 (c8346d6). #49–#51 were reviewed by sub-auditors; the key claims were re-checked by hand, and one #50 claim and one #51 claim were corrected below.

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

## Live voice "weird and laggy" (Josh, real workout)

Ranked by likely contribution. L1–L3 are in code already merged or in #44, not in the new PRs.

**L1. Coach audio is decoded on the main thread, and the next message waits for it. CONFIRMED**
`LiveVoiceSession.swift` `receive(on:)` → `Task { @MainActor }` → JSON parse, base64 decode, Int16→Float conversion (`buffer(fromPCM16:)`) and `scheduleBuffer`. `task.receive` for the next message is only called after that. Any main-thread work during a workout therefore delays or gaps the coach's voice. Main-thread loaders found: #44 rebuilds the whole live context (an `AVAudioSession` query plus a walk over all logs) on every `CoachStageView` render; #49 redraws `CoachView`/`CoachStageView` every second and runs a 30 fps full-screen shader timeline (F14). Fix direction: decode off-main, re-arm `receive` immediately, and keep per-second state out of the stage view.

**L2. Half-duplex whenever echo cancellation is off. CONFIRMED (pre-existing)**
`uplink.halfDuplex = !hub.canTalkOver`: with music playing on the phone speaker, voice processing is off (`wantsEchoCancellation` requires `!isOtherAudioPlaying`), so the mic is dropped while the coach talks. You can't cut in, which feels like lag. #40's default Light dip keeps music up, so this is the normal case with Spotify on the speaker.

**L3. Every session start waits on the server. CONFIRMED**
`connect()` awaits `backend.mint` (the server builds a ~35–43k-char instruction and mints a token) before opening the socket, and the mic tap is only installed after `setupComplete`. #50 doesn't remove this wait (F16).

**L4. #46 mutes the coach while counting**, and now for up to 20 s after the last rep; coach audio arriving meanwhile is dropped (`play` returns when `uplinkMuted`). See F11.

**L5. #40 is not a live-voice cost.** The session release-and-retake on a dip change is skipped while live voice is active (`SoundMixSheet(canRetake: !live.isActive)`). PLAUSIBLE edge: `SoundMixControls()` in Preferences defaults to `canRetake: true`, so a dip change there during a live session would tear the audio session down.

## #49 atmosphere (89c9e6d)

**F13. Nothing real feeds heart rate, so most of the feature is inert in Release. CONFIRMED**
The only `HeartRateHub.publish` caller is the DEBUG `HeartRateSimulator.swift:53` (gated by `#if DEBUG` and `MYO_HR_SIM`; it doesn't leak into Release, which is good). In Release, time in zone, recovery, "Recovered" and HR-driven colour/grain never happen; effort follows workout state only. The simulator also labels its data `source: .watch`, so DEBUG coach context looks like real Watch data.
"Rest by recovery" is a voice line only: `sayRecovered` (`CoachView.swift:~301`) never touches `restEndsAt`, so rest isn't shortened and there's no "let's go".

**F14. A weight-based calorie estimate is shown as a reading. CONFIRMED**
`Effort.swift:108`: without HR, a flat 3.5 MET from body weight, accumulated over the whole session including rests. The pill shows "N kcal"; only the VoiceOver label says "About". The plan put calories out of scope, and #39 deliberately refused to show guessed calories.

**F15. The pill's state re-renders the whole coach screen every second, and the shader ticks at 30 fps. PLAUSIBLE (perf; feeds L1)**
`CoachView.swift:11` owns `@StateObject vitals`, ticked every second (`:65`), so `CoachView`'s body, and `CoachStageView` with it, re-evaluates each second. `WorkoutAtmosphere.swift:20-33` rebuilds the shader every frame (parsing a hex colour each time) and keeps ticking under Reduce Motion. Only the pill should observe `vitals`.
Fine: every SwiftUI/Metal API exists at iOS 17, and the stitchable signature matches the Swift call; the ~10 s easing is as specified; the orb edits are in scope. No tests. The greyscale check measures real-shader screenshots, but the screenshots aren't committed, so it can't be re-run.

## #50 memory brief (2f8d8a7, 5ba189c)

**F16. "Instant start" isn't instant: live voice still waits on `mint`. CONFIRMED**
`LiveVoiceSession.swift:161` still awaits `backend.mint`, which builds the full instruction server-side. The cache only skips a few reads (~7 ms by the PR's own table), and a first build without a cache is slower than before.

**F17. Live conversations never rebuild the brief. CONFIRMED**
The rebuild sits in `onUserCoachMessageCreated` after `if (... data.status !== "queued") return` (`index.ts:~1075`), and live turns are saved as `complete`. Text turns rebuild on every message (~180 reads each), duplicating the fact and notes triggers.

**F18. The "~1,500-word" brief can reach ~3,900 words, and the injury guarantee is narrower than claimed. CONFIRMED**
`memoryBrief.ts:25-30`: safety facts are outside the budget (30 × 80 words). Safety facts beyond 30 are dropped silently. The injury query only reads the `safety_note`/`constraint` categories, so an injury filed elsewhere and older than the newest 100 facts drops out.

**F19. "Last spring" points to the wrong year. CONFIRMED**
`toolRegistry.ts:312`: "'last spring' = roughly March to May of last year relative to <today>". On 2026-11-05 that sends the model to 2025; the most recent spring is 2026. Recall covers workout logs only, not conversations (the PR says so). "Nothing found" is explicit, which is good.

**F20. Reset → facts deleted → each deletion fires a rebuild, which re-creates the brief the phone just cleared. CONFIRMED.** The server never compares the phone's `memoryBriefBuiltAt` with the stored brief, so a stale cache can still carry a forgotten fact (PLAUSIBLE).

Corrected: the sub-audit said mid-session brief refreshes interrupt the coach. They're sent with `turnComplete: false`, and per Gemini Live docs only `turnComplete: true` interrupts, so **not a finding**. Real cost: each refresh appends ~1,500 words to the session, and with sliding-window compression the opening brief is the first thing dropped in long sessions (PLAUSIBLE).
Fine: rules allow client read only, with no writes (tested); the brief is labelled as data; recall is uid-scoped; no trigger loop; no hardcoded phrases.

## #51 session switch, banked swaps, ask-once (c8346d6)

The #41 hijack (F1) is gone: "I'm not doing that, I'm going for a run", "I'd rather go for a run today" and "nah, let's do a run instead" now reach the coach, which can call `replace_session`, and the switched session logs and saves to Health as a run. Banked swaps are local for the swap sheet and the live `find_exercise_swaps`.

**F21. "Let's go for a run" is still hijacked on the phone, now by the rest and hold handlers. CONFIRMED**
`WorkoutEdits.swift:132-134` makes `cardioRequest` return nil on "go for", so the rest/hold guards no longer skip it. While resting, "let's go for a run" (5 words) matches `let's go` in `handleRestCommand` (`CoachStageView.swift:~1861`): the rest is skipped, "Go." is said, and the coach never hears it. Before an unstarted plank or carry, the same sentence starts the hold timer (`:1731`). (The sub-audit said "I'm going for a run" triggers this; it doesn't, because `\bgo\b` doesn't match "going". "Let's go for a run" does.)

**F22. The fix is another phrase table. CONFIRMED**
`WorkoutEdits.swift:132-134` adds "instead / rather / not doing / go for / going for…" regexes that decide on the phone before the model hears anything. That's the approach ideas.md (a) rules out. It works for the phrasings listed and will miss others.

**F23. Ask-once is once per session, not once. CONFIRMED**
`addOnAsked` resets when the session id changes (`AppModel.swift:~49`) and is only stored with the in-progress workout. A "no" isn't remembered, so it asks again next time. The add-on gear comes from the fixed list `FINISHER_GEAR` (`sessionAlternatives.ts:354`, kettlebell first), not from what the profile says they train toward.

**F24. Banked swaps go stale after equipment changes. CONFIRMED**
The bank only refreshes on a plan change or at workout start (`AppModel.swift:~38, ~839`) but is served before the network. An `update_training_setup` equipment change is ignored until the next refresh. Injuries aren't filtered in the bank or in the server swap (pre-existing).

**F25. A switched session saves its whole span to Health as Running. PLAUSIBLE**
`AppModel.swift:~1445` saves start→finish as Running, including the lifting done before the switch; if a Watch or Strava also records the run, Health gets a duplicate.
Fine: every tool declared has a handler; the HealthKit activity types exist; no live-voice latency added; server tests check real behaviour. No iOS tests for the new routing, which is where F21 lives. Device checks unticked.

## #46 rep counting past target (3d9bee2)

Verdict: **the fix is real and well tested.** The bug cause in the PR body matches the old code: the set was logged at the target, and the 4 s close window was flat. `SetCount` is a clean pure struct, and the 12 tests exercise real behaviour, not a copy of the code: grinding, dropped words, each side, stray numbers. The constants have stated reasons and aren't tuned to Josh's set. No scope drift.

**F10. #46: the new tests never run in CI. CONFIRMED**
`.github/workflows/ci.yml` only builds the `IronBoi` scheme. The `IronBoiTests` scheme/target isn't in any job, so "12/12 pass" was a local run, and the first regression will go unnoticed.

**F11. #46: live voice stays muted up to 20 s after the last rep. PLAUSIBLE**
`CoachStageView.swift` (`trackReps` / `finishCount`, around line 1650 on the branch): the uplink is muted at the first number and only reopens in `finishCount`. Before, the set closed 4 s after the target. Now it's `quietWindow`: at least 6 s, up to 20 s when an earlier rep in the set was slow (one 10 s breath at rep 5 → 20 s window). Scenario: live voice, last rep at 10, then "that was brutal, how long do I rest?" The coach can't hear it for up to 20 s, and the rest timer (and #44's `restElapsed`) starts that late too. Device check 3 covers the grind; add one for talking to the coach right after racking.

**F12. #46: `AppModel.updateSetReps` is now dead code** (`AppModel.swift:1119` on the branch). Nothing calls it. Delete it, or keep it on purpose.

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
