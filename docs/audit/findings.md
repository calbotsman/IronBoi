# Watchdog findings

*Updated 2026-11-05. Most severe first. CONFIRMED = read in the code. PLAUSIBLE = depends on runtime data or a device.*
Audited: #39, #40, #41 (merged), #44 (open; rebased to 86e8a6a, mergeable), #46 (open, own commit 3d9bee2), #49 (89c9e6d), #50 (2f8d8a7+5ba189c), #51 (c8346d6), #47 (3cbb241), #48 (e737fd7), #52 (face928), #53 (55250c7). #49–#51 were reviewed by sub-auditors; the key claims were re-checked by hand, and one #50 claim and one #51 claim were corrected below.

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

## Re-audit: #38 (5ab9ff2 + ef2ad16) and #53 (87a8224)

**Verdict: safe to merge once iOS CI is green** (it was pending at audit time). The launch-crash fix (F42) is now on main via #55, so #38 and #53 can merge in either order.

- **B1 fixed.** `takeLiveMint` decides handover server-side from the user's last mint (`isHandover`: ≥ 60 s since the last mint and within 15 min for Gemini / 65 min for OpenAI). The client flag is advisory. Anonymous uids always get Gemini, whose token locks the session. The ability of a signed-in client to `session.update` its own OpenAI session is recorded as an accepted limit (`liveOpenAI.ts:9-14`).
- **B2 fixed.** Realtime tools run from `response.done`, and only when status is `completed`; cancelled-response calls are dropped and logged. `response.create` waits while a response is active (`requestOpenAIResponse`).
- **B3 fixed.** The policy (md + html) says on by default, names OpenAI Realtime or Gemini Live, and discloses the Gemini/OpenAI TTS path. Nit: `privacy-policy.md:35` has a verbless fragment ("Google Cloud's data-processing terms (…), which do not allow…").
- **B4 fixed.** The mic tap no longer checks `box.socket != nil` (`LiveVoiceSession.swift:1200`), so audio during a reconnect is held and replayed.
- **B5 / F27 fixed.** `handedOver()` no longer resets failures; only `liveHealthy()` does, after 120 s of working live. More than the burst limit of reconnects in the window ends the session, so the policy's backoff and cap decide.
- **B6 fixed.** `handOverToLive()` pushes the context note (`CoachStageView.swift:1683-1684`).
- **F28 fixed** (B4). **F29 mitigated:** a missed pong only counts after a first pong, and reconnects have their own timeout.
- **L3, disputed:** accepted as **not user-facing**. With standby and hand-over, the regular coach listens while live mints, so the mint wait now only delays the switch to live; nobody waits on it. Closed.
- **Latency measurement, disputed:** "speech end" is still the last mic buffer above ~−40 dBFS (`:1392`). With voice processing on that's reasonable; with music on the speaker (VP off) it can be kept fresh by music, so the logged latency is a **lower bound**. Not blocking. Read it alongside the server's VAD (`input_audio_buffer.speech_stopped` on OpenAI) if the numbers look too good.
- Open, minor: L2 (half-duplex with music on speaker) is unchanged; there's no iOS test of OpenAI event handling; no real OpenAI device session has been run yet.

**F42. Launch crash on main (iOS 26.x): `HKHealthStore.workoutSessionMirroringStartHandler` getter. RESOLVED on main by #55 (48127ef)**: verified main no longer reads the getter (flag plus `responds(to:)` setter check, `WatchWorkoutLink.swift:58-68`). A device launch on 26.6 is still to be confirmed.
Main (`20e701b`) `WatchWorkoutLink.swift:53`: `store.workoutSessionMirroringStartHandler == nil` runs in `App.init`. The 26.2 SDK header declares it read/write (`HKHealthStore.h:286`), but the iOS 26.3 simulator's HealthKit binary contains only the `setWorkoutSessionMirroringStartHandler:` selector, not the getter. The read is an unrecognized selector, so the app aborts at launch (Josh's 26.6 crash log, 14:07). The header-vs-runtime mismatch is why the #48 audit's "API exists" check passed. **Fix ef2ad16 is correct:** it never reads the property, tracks installation with a flag, and checks `responds(to: setWorkoutSessionMirroringStartHandler:)`. It's only on #38/#53, so **main still crashes until it's cherry-picked or #38 merges.**

**F41. CI never launches the app. CONFIRMED, high (process)**
F40 (missing plist) and F42 (missing getter) both passed CI because `ci.yml` builds and runs pure unit tests but never installs and launches the app. Both crash in `App.init`, so a launch smoke test would have caught both. Proposed: after the simulator build, `xcrun simctl boot` → `simctl install` → `simctl launch --console-pty` and fail if the process exits within ~10 s or the log shows `Terminating app` / `unrecognized selector`. Also: for device installs, `xcrun devicectl device process launch` plus a 10 s alive check before handing a build to Josh. Watchdog rule added: header presence is not proof an API works at runtime; for any newly used HealthKit/WatchKit property *getter* on the launch path, check the selector in the simulator runtime's framework binary.

## Final pre-merge: #38 OpenAI Realtime (ddc411f) + #53 on top (3b7e6c2)

**Verdict: not yet. Both are close; the blockers are small and listed below.**

Verified fine:
- The OpenAI Realtime protocol is GA-consistent. The key is minted server-side at `/v1/realtime/client_secrets` from the Firebase secret, and the phone only gets a 10-minute `ek_`. Session config (`type:"realtime"`, 24 kHz PCM in and out, `semantic_vad`, voice, tools, instructions) is set in the mint, with no `OpenAI-Beta` header. Every client event name is valid. The phone accepts both GA and legacy audio/transcript delta names, so there's no silent-audio risk.
- Every live tool is declared and handled: the 10 server tools including `recall_training_history`, plus phone-run `replace_session`, `add_session_add_on`, `swap_workout_exercise`, `extend_rest`, `show_exercise` and `set_workout_weight` (`liveSession.ts:233-296`, `AppModel.swift:443-455`). The memory brief goes in as the first `[app]` note.
- **#53 fixes F26/L1:** messages are parsed and decoded on URLSession's queue, `receive` is re-armed before parsing, and only results hop to main, in order. A "message waited N ms for main" log was added.
- **No regression to #46:** mic muting is centralised in `updateLiveUplink()` (`CoachStageView.swift:2693`), which keeps the `repsStoppedAfter` reopen. `liveHeard` still closes the set. The hand-over waits for `setCount == nil && closeCountTask == nil`. Design change from #38: the live mic is now closed for the whole set, not just while counting ("MYO, …" still passes through).

**Blockers**

**B1 (#38). The OpenAI client can rewrite its own coach, and staging makes OpenAI the default. CONFIRMED**
OpenAI ephemeral secrets don't lock the session, so a client can `session.update` its instructions and tools. `liveOpenAI.ts:9-12` says so itself and calls the provider "opt-in… for testing, not the default". But `functions/.env.ironboi-staging:77` sets `IRONBOI_LIVE_PROVIDER=openai`, with `IRONBOI_LIVE_ALLOW_ANONYMOUS=true` (`:68`). The `handover` flag is client-asserted and draws a separate 200/day cap (`index.ts:576-579`, `liveSession.ts:52`). So one anonymous install can mint ~240 rewritable Realtime sessions a day on Josh's key. Prod has no LIVE_ vars, so it's off there. Fix: derive `handover` server-side (or count it against the main cap) and disallow anonymous for OpenAI. Then accept B1 as a known limit, since Josh chose OpenAI.

**B2 (#38). Tool replies race the active response. PLAUSIBLE, high**
`LiveVoiceSession.swift:816-820`: right after a `function_call_output`, `response.create` is sent without waiting for that response's `response.done`. Phone tools (`extend_rest`, `show_exercise`) return instantly, so OpenAI will often reject the request because a response is still active. The error is only logged, so the coach goes silent after a tool. `say()` has the same race. Also, tool calls from a cancelled or interrupted response still run (`function_call_arguments.done` is emitted on cancel), so `replace_session` could fire on a barge-in. Fix: queue `response.create` until `response.done`, and skip calls whose response status isn't `completed`.

**B3 (#38). The privacy policy is wrong. CONFIRMED**
It now names only OpenAI for live voice, but Gemini Live is still a selectable provider. It says live voice is "off by default", but `PreferencesView.swift:9` defaults `liveVoiceBeta = true`. The new Gemini/OpenAI text-to-speech path (`speech.ts`) isn't disclosed. This must be right before any external tester.

**B4 (#53). The reconnect hold buffer is dead code. CONFIRMED**
`LiveVoiceSession.swift:1101`: the mic tap does `guard let chunk = uplink.append(buffer), box.socket != nil else { return }`. During a reconnect `socketBox.socket` is nil (`:553`), so the tap returns before `box.send`, and `SocketBox.hold()`'s "up to ~6 s held" never receives audio. Only the ~2 s before the drop is replayed, so speech during the gap is lost. F28 is still open. One-line fix: drop `box.socket != nil` (`send` already handles nil and holding).

**B5 (#53). F27 is still open and worse on OpenAI. CONFIRMED**
`handedOver()` still resets `failures = 0`. And after ready, an OpenAI socket close goes to `reconnect()` (`LiveVoiceSession.swift` receive failure branch: `ready, resumeHandle != nil || openAI`), not through the policy's backoff. A session that reaches ready and then dies each time reconnects immediately, minting every time until the 40/day cap. Fix: count ready-then-drop as a failure, and route post-ready closes through the backoff.

**B6 (#53). The context note is skipped on a normal hand-over. CONFIRMED**
`CoachStageView.swift:1634-1645`: `handOverToLive(); return` exits before `pushContextNote(appModel.liveContextNote)`, so the live coach starts without #44's rest/HR/rhythm context.

**Not blocking (follow-ups)**
- PLAUSIBLE: `quietForCount` isn't reset on teardown (live dropped mid-count, later outside a workout, could stay silent). And "no mic" in `takeMic` runs `onEnded` before `handedOver()`, which can leave nothing listening outside a workout.
- **F29 mitigated:** a missed pong only counts once a pong has been seen; the 8 s ready timeout still includes the mint.
- **L3 still open:** every start and reconnect awaits the mint. L2 (half-duplex with music on speaker) unchanged.
- The phone's picker can show "Gemini" while staging serves OpenAI (`AppModel.swift:418` only sends `provider` when OpenAI is picked).
- `liveSession.ts:136-195` holds a dead second OpenAI implementation (a different model default, voices and 15-min expiry). Delete it.
- No test exercises the iOS OpenAI event handling, and no real OpenAI session has been run on a device.

## Process

**F40. Main's committed Xcode project didn't bundle GoogleService-Info.plist, so builds crashed at launch. RESOLVED on main by #54** (the plist is now an `optional: true`, `buildPhase: resources` source and is excluded from the folder glob; main's pbxproj has the reference again). Open PRs still without it, as of 2026-11-05 (none rebased onto #54 yet): **#44, #48, #49, #50, #51**. #38, #46, #47, #52 and #53 have the pbxproj entry but not the project.yml fix. Every open PR must rebase onto main and **regenerate with xcodegen**, not hand-merge the pbxproj, so the entry survives.
Reported: a device build from live-voice-fix's worktree aborted in `FirebaseApp.configure()` (`IronBoiApp.swift:24`) with no GoogleService-Info.plist in the bundle.
Root cause: the plist is gitignored and is written by the `Select GoogleService-Info.plist` pre-build script (`project.yml:22-103`). XcodeGen only adds files that exist *when it runs*. Commit **29a375a** ("chore: regenerate Xcode project", merged with #40) was generated in a worktree without the file, and it **removed** the `GoogleService-Info.plist in Resources` entry from `project.pbxproj`. Since then, main, #44, #48, #49, #50, #51 and #53 all lack it (0 references). #46, #47 and #52 happen to have it back (regenerated where the file existed), so whichever merges last decides. CI is green because it only builds; nothing launches the app.
Fix (proposed, for the owning session):
1. `project.yml` → under `IronBoi.sources` add `- path: IronBoi/GoogleService-Info.plist` with `optional: true` and `buildPhase: resources`, so XcodeGen always references it, file or not.
2. Add a build-phase assert (a postBuildScript, or a script after Copy Bundle Resources): `test -f "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/GoogleService-Info.plist" || { echo "error: GoogleService-Info.plist missing from bundle"; exit 1; }`. Then CI fails instead of the phone.
3. Add a CI launch smoke test: `xcrun simctl install` + `simctl launch`, then check the process is alive after ~5 s.
4. Device installs (the direct-to-iPhone loop): after install, launch with `xcrun devicectl device process launch` and confirm it stays up before handing it to Josh.
Watchdog check added: every PR touching `project.pbxproj` must keep exactly one `GoogleService-Info.plist in Resources` (until fix 1 lands).

 (Josh, real workout)

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

## #53 live voice reliability (55250c7)

Verdict: **a fallback and observability PR. It doesn't fix Josh's "laggy".** The never-deaf hand-over between the regular coach and live is real, connection-counter guards hold, and no audio or per-buffer data is logged.

**F26. L1 and L3 are untouched. CONFIRMED**
`LiveVoiceSession.swift:313-338`: receive → `Task { @MainActor }` → parse/decode/play → only then re-arm `receive`. More main-thread work is added (latency check, outbox, a 300 ms hand-over poll in `CoachStageView.swift:1419`). Every start and reconnect still awaits `mint` (`:244`), and live now also waits for 2.5 s of quiet before taking the mic (`:1428`). L2/L4 unchanged.

**F27. Unbounded reconnect loop. CONFIRMED**
`LiveVoicePolicy.swift:109`: `handedOver()` resets `failures = 0`. A session that reaches setupComplete and then dies (quota, post-setup provider error) never hits the 6-try cap. It retries every ~2 s forever, minting a token each time and flipping the mic between coaches. `testReadyResetsTheBackoff` locks this in.

**F28. Deaf gap on goAway reconnect. CONFIRMED**
Before ready, mic audio is dropped (`box.socket` is nil until setupComplete, `:630`), and on a goAway reconnect the state stays `listening` with the "Live" badge while nothing hears for the whole mint + setup. The regular coach doesn't cover the gap, which contradicts "never deaf" in the body.

**F29. Bare-number watchdogs. PLAUSIBLE**
4 s ping / 3 s pong, an 8 s ready timeout (which includes the ~40k-char mint), and any unsatisfied network path each force a fallback and a fresh mint. On gym cellular this could cause the very flapping Josh feels. The latency line measures "speech end" as the last buffer above −40 dBFS, so with gym noise or music it reads near zero (PLAUSIBLE).
Corrected: the sub-audit repeated "any clientContent interrupts". Per Gemini Live docs only `turnComplete: true` does, so **not a finding**. Conflicts: #50 (LiveVoiceSession.swift), #46 (pbxproj test target).

## #48 Watch app, Phase 2 (e737fd7)

Verdict: **APIs all real and correctly gated. The plan's structure is followed.** Checked against the iOS/watchOS 26.2 SDK headers: `workoutSessionMirroringStartHandler` (iOS 17), `startMirroringToCompanionDevice` (watchOS 10), `sendToRemoteWorkoutSession(data:)` async (iOS 17 / watchOS 10), `startWatchApp(with:completion:)` (iOS), `handle(_ workoutConfiguration:)`, and `HKLiveWorkoutBuilder` on the Watch only. The mirroring handler is set at launch (`IronBoiApp.swift:86`). The phone never blocks on `startWatchApp`. The Watch saves with sync id = session id. The target config and usage strings are right. Read permission is asked at the first Watch start. **Resolves F4 and most of F13:** `HeartRateHub` now gets real samples, and trend / `recoveryDrop60` are computed.

**F30. Double save when the phone is slow to finish. CONFIRMED path**
`MYOWatch/WatchWorkoutManager.swift:139`: Watch End → `endRequested` → after 8 s with no answer, the Watch ends and saves itself. The phone's later `endWorkout` (`WatchWorkoutLink.swift:176`) fails because the mirror is gone, so `AppModel+Watch.swift:49-51` falls back to `HealthSync.saveWorkout`. Different Health sources won't merge on sync id, so you get two workouts. The 8 s includes the phone's backend finish call; slow gym Wi-Fi or a failed finish is enough.

**F31. No HR smoothing or hysteresis. CONFIRMED**
The plan asks for 10 s smoothing and 15 s zone hysteresis. Trend compares raw means, and the Watch colours its zone per raw reading (`WatchViews.swift:76`). Wrist noise on presses will flip zones, and with #49 that means flickering atmosphere and coach rules firing on noise.

**F32. A second permission prompt can stall the first Watch start. PLAUSIBLE**
The Watch requests share for heart rate + active energy (`WatchWorkoutManager.swift:62`), which the phone never asked for. The session isn't created until that's answered, leaving the Watch on "Starting…".
Low: no tests (trend, recovery, message round-trip, set-done fallback); a set marked done from the Watch with the coach screen closed starts no rest; Health permission is requested even with saving off (`WatchWorkoutLink.swift:438`); inline 1.5 / 8 / 4.5 / 15 s literals. The PR says plainly it hasn't run on a device.

## #52 straps + AirPods, Phase 3 (face928)

Verdict: **no invented APIs.** The iPhone `HKWorkoutSession`/`HKLiveWorkoutBuilder` (iOS 26) are behind both `#available(iOS 26.0, *)` and `#if compiler(>=6.2)`. CoreBluetooth calls and UUIDs 180D/2A37 are correct. The HRM parser follows the spec (UInt8/UInt16 bpm, energy-expended skipped before RR, RR/1024). AirPods are detected by readings arriving within 20 s, not an invented API. Priority Watch > strap > AirPods, with a 12 s dropout, is fine. No fake peripherals in Release.

**F33. Health permission sheet mid-workout for anyone with Bluetooth headphones. CONFIRMED**
`PhoneWorkoutSession.swift:44-56, 105`: `startIfUseful` fires for *any* Bluetooth output (car audio, plain earbuds) on iOS 26 and requests share for heart rate, a type nobody asked for before. It doesn't check `HealthSync.enabled`. Scenario: Josh with regular earbuds, 15 s into a set, gets a Health sheet. It also starts a full iPhone workout session for ~20 s on every such workout, with an unverified effect on the audio session that live voice uses (PLAUSIBLE).

**F34. Finish can hang, and nothing is saved. PLAUSIBLE**
`PhoneWorkoutSession.swift:70-73`: `end()` awaits a continuation that only resumes on the session's ended-state callback. If the session already ended or failed, it never resumes, so `AppModel+Watch` save stalls and HealthSync never runs.

**F35. Bluetooth off/on mid-workout loses the strap. PLAUSIBLE**
`HeartStrapConnector.swift:150-160`: on power-on only one queued action runs and nothing reconnects; `whenOn` keeps only one pending action.
Low: no committed tests (the body's "parser checked with hand-built packets" isn't in the repo); the pairing screen publishes into the coach's HR hub outside a workout (cleared at start); the scan list hides straps by name, not UUID; inline 15/20/12 s literals.

## #47 weight changes, total vs per-side, each-side logging (3cbb241)

Verdict: **the server tool and log contract are sound; the phone parser fails common gym phrasings, and the tests only cover the device-check phrases.** The sub-auditor compiled `WeightLoad.swift` and ran each phrase; F36 and F37 were re-checked against the code by hand.

**F36. "Go up to 50s" while holding 35s stores 85 lb each. CONFIRMED**
`WeightLoad.swift:155`: the `absolute` regex needs `\b` right after the number, so "50s" isn't a target. "Up" then makes it `.by(50)` → 35 + 50. "Grab the 40s" is ignored entirely.

**F37. The total-or-each guess ignores direction, tuned to one case. CONFIRMED**
`WeightLoad.swift:183-185`: on a two-dumbbell lift, any "to N" closer to 2× current is halved. "Go up to 50" holding 35s → 25 each (lighter), and "go up to 35" holding 20s → 17.5. This fits Josh's "80 while holding 35s", and a "no" to the "Right?" check isn't handled (PLAUSIBLE).

**F38. Barbell plates per side aren't converted to a total. CONFIRMED**
"Put 25s on each side" stores 25 lb total; there's no plate maths (45 + 2×25 = 95). "Add a plate" falls through to the coach.

**F39. Kilos are converted to lb, but there's no unit setting. CONFIRMED**
`:146`: a kg user's "20 kilos" shows as 45 lb, and the UI says lb everywhere.
Medium: side phrases are caught any time on one-side lifts, so "is the other side the same?" during rest never reaches the coach (`CoachStageView.swift:1471-1482`); left/right are logged only from voice counting (taps/stepper log no sides), and `reps` = the weaker side, so tonnage counts one side. The deploy order (server first, since the contract is `.strict()`) is stated in the body. Conflicts: #46 moved side counting into `SetCount.swift`, so #47's side logging must be ported there; both add a test target. Also conflicts with #51 and #44.
Fine: "add ten pounds" on a barbell → +10 total, "make it 135" → 135, "20 each hand" → 20 each, `loadKg` meaning unchanged (no server double-count), and the server's lift tables are drift-tested.

## #46 rep counting past target (3d9bee2, re-push bd3e36b)

**Re-push bd3e36b resolves F10–F12. CONFIRMED.** CI now runs `IronBoiTests` (green on the PR). The live mic reopens once reps stop (`repsStoppedAfter`: 1.5× the slowest rep, at least 3 s, never past the close window), and talking to the coach then closes the set at once. Rest counts from the last rep. `updateSetReps` is removed. Three new tests cover the reopen timing. Small leftovers: when the mic reopens, a late "twelve" reaches the coach before the phone mutes it again. #44's `noteRest` records the planned rest as `endsAt − now`, so a back-dated rest reports e.g. 84 s planned instead of 90.

Verdict: **the fix is real and well tested.** The bug cause in the PR body matches the old code: the set was logged at the target, and the 4 s close window was flat. `SetCount` is a clean pure struct, and the 12 tests exercise real behaviour, not a copy of the code: grinding, dropped words, each side, stray numbers. The constants have stated reasons and aren't tuned to Josh's set. No scope drift.

**F10. #46: the new tests never run in CI. CONFIRMED**
`.github/workflows/ci.yml` only builds the `IronBoi` scheme. The `IronBoiTests` scheme/target isn't in any job, so "12/12 pass" was a local run, and the first regression will go unnoticed.

**F11. #46: live voice stays muted up to 20 s after the last rep. PLAUSIBLE**
`CoachStageView.swift` (`trackReps` / `finishCount`, around line 1650 on the branch): the uplink is muted at the first number and only reopens in `finishCount`. Before, the set closed 4 s after the target. Now it's `quietWindow`: at least 6 s, up to 20 s when an earlier rep in the set was slow (one 10 s breath at rep 5 → 20 s window). Scenario: live voice, last rep at 10, then "that was brutal, how long do I rest?" The coach can't hear it for up to 20 s, and the rest timer (and #44's `restElapsed`) starts that late too. Device check 3 covers the grind; add one for talking to the coach right after racking.

**F12. #46: `AppModel.updateSetReps` is now dead code** (`AppModel.swift:1119` on the branch). Nothing calls it. Delete it, or keep it on purpose.

## #61 Josh's mobile session, nine commits (deb4cb8)

**Verdict: merge after the F53 guard (a few lines). F54 is a product trade-off for Josh to decide, and doesn't block the merge.** CI was pending at audit time.

**F53. The "always answers" re-ask can repeat a tool action. CONFIRMED (code), medium-high.** `LiveVoiceSession.expectAnswer` (`LiveVoiceSession.swift:~1029`) resends the question 8 s after the ask if no live audio has played. Its guard checks speaking, owed, the count and the quiet window. It does not check `openAIResponseActive`, a tool call in flight, or a tool that ran since the ask. `CoachStageView.swift:3856` calls it for anything `isQuestionOrRequest` matches, and that regex includes `add|swap|skip|change`. Failure: "add a set" or "swap bench". The coach calls the tool, and the server round-trip plus the confirmation audio takes more than 8 s. The re-ask fires, "[app] They asked you this… Answer it now", and the model can call the tool a second time: two added sets, or a double swap. Fix: skip the re-ask while a response or tool call is active, or if any tool ran since `lastAskedAt`. Tell the model "answer only, don't repeat any action".

**F54. "One coach voice" removes the Cloud TTS fallback, so a provider outage makes the regular coach mute. PLAUSIBLE, medium (trade-off).** `speech.ts:160-180`: the engine is tried twice, and then the call errors instead of falling back to Cloud TTS. The client shows a tone and the words (`CoachVoice.swift:237`). #53's fallback (live fails → the regular coach) usually happens because the live provider is failing, and the regular coach's TTS uses that same engine. So in an OpenAI or Gemini outage the whole workout is ticks and captions. **Never-deaf still holds:** the mic, STT and the text coach are untouched. What it loses is "never mute". The retry also doubles the worst-case wait, and `speech.ts` sets no fetch timeout. Option: switch voice per session, not per line. After N engine failures, the rest of the conversation uses Cloud TTS: one voice per session, never two in one reply.

**F55. Old progress docs still carry lens framings into the prompt. CONFIRMED, low.** The builder no longer writes `lensHighlights`. But `contextBundle.ts:457` still reads them from persisted progress summaries into `<progress_summary>` (`prompt.ts:241`) until each doc is rebuilt. A user who picked Huberman and hasn't trained since still sends Huberman framings. The prompt's "don't name protocols" rule mostly covers it. Fix: drop `lensHighlights` in `contextBundle`.

**Checked and fine:**
- **Captions mode:** unaffected. The `allowsDeviceVoice` setters in `CoachStageView` are gone and it now defaults to `false`. The phone voice is used only when `fetchAudio` is nil, and the stage, onboarding and preferences always set it. The voice-off gating is unchanged.
- **Share voice log:** shares only `Documents/audio-log.txt` (`AudioHub.logFileURL`), and only from the share sheet the user opens. The log holds timestamps, mic transcripts (≤60 characters per line), coach lines and audio-state notes. A grep of all 124 `AudioHub.log` calls found no tokens, keys, uids or emails. One health line logs only a read error. Nit: the row could say it includes what you said.
- **Protocols removed:** the `protocol_*` corpus entries are gone, with no remaining references in `functions/` or `ios/`. The retrieval test is updated. Onboarding writes `none`, the iOS picker is removed, the enum is kept so old profiles parse, and the prompt says to ignore it. The Schoenfeld citations in `ironlab-seed.json` are research references, not the protocol. Stale doc: `docs/product/habit-journey-plan.md:42`.
- **"of 36 planned" fix** (`build.ts` `firstActiveWeekIndex`) is correct and tested. The bodyweight shortfall wording and the warm-up moves are UI only.
- **Latency:** nothing on the normal path. The re-ask and owed-answer each add a model turn only after a failure.

## #57 CI launch guard (9f0dabf)

**Verdict: merge once its own iOS run is green.** The guards are sound. One gap needs a follow-up (F43).

**F43. CI builds with Xcode 16.4 (iOS 18.5 SDK), so iOS 26-only code is never compiled or launched in CI. CONFIRMED, medium.** The build step uses the runner's default Xcode (the run log says `Xcode 16.4`, `iphonesimulator18.5`). Only the smoke test switches to Xcode 26.3, and it launches the 18.5-SDK binary on the 26.2 runtime. Code behind `#if compiler(>=6.2)` / `#available(iOS 26)`, such as the iPhone `HKWorkoutSession` path from #48, is compiled out. Josh's device builds use Xcode 26, so a crash in that code passes CI. The smoke test does still catch the F42 class: that getter was an iOS 17 API, and the iOS 26 runtime drops it whatever the SDK. Fix: build (or add a second build) with the newest Xcode and smoke-test that product.

**F44. The proof shows the preflight failing, not the launch smoke test. PLAUSIBLE, low.** The throwaway run c22c473 went red at preflight. 6100079 adds `continue-on-error` so the smoke test runs against a build with no plist, and it was still running at audit time. Until that run shows the smoke step red with the Firebase abort, "the smoke test catches a launch crash" is unproven. No run proves the F42 class; that would need a throwaway revert of #55.

**Reliability (Flaky? no evidence).** Two complete runs (be2cfa7, plus 002d185 before it was cancelled) passed both smoke steps: iOS 26.2 on Xcode 26.3 and iOS 18.5 on 16.4. Boot, install and launch took about 2–4 min per runtime. The per-call deadlines (boot 300 s, install 180 s, launch 120 s) leave headroom, and the job timeout is now 45 min. The sources of flakiness are handled: a hung `simctl` is bounded by the deadlines, the crash-report check uses `-newer` and the app name, and a fresh simulator is created and deleted each run. The remaining risk is a slow first launch on a cold 26.x runtime that nears 120 s. If it flakes, raise the deadline; don't retry. Nit: those runs picked iPhone 11 / XS Max. 299f652 ("newest plain iPhone") came after them, so check the device line in the next run.

**Fine:** the preflight regex matches #54's `project.yml` shape, the pbxproj grep matches the `in Resources` entry, and the bundle check lints the plist inside the built `.app`. `MYO_PREVIEW`/`MYO_NO_MIC` exist on main (`CoachView.swift:184`, `VoiceInputEngine.swift:99`), so the launch gets past sign-in without the mic or the backend. `IronBoiTests` was already in CI (F10).

## #59 social prototype (872b0f3)

**Verdict: safe to merge with the flag off. Before setting `IRONBOI_SOCIAL_ENABLED=true`, fix F48–F50.**

**Off really is off, with small caveats.** With the server flag unset, the coach turn (`orchestrate.ts`), the live session and the workout trigger make no extra reads, and the prompt is unchanged: the env check comes before any Firestore call (`store.ts:243`, `:102`). The 4 new callables deploy but throw `social_disabled`. The caveats:
- The `myo://` URL scheme is registered in Info.plist even when the flag is off. The handler ignores it (`SocialModel.swift:175`).
- `recordConsent` now accepts `social_activity`.
- deleteAccount and resetMyData run the social cleanup (two queries and a batch) even when the flag is off. If it throws, account deletion now fails where it used to succeed (F52).

**F48. A friend can read more than the policy says. CONFIRMED, medium.** The policy (`privacy-policy.md:17,38`, the html matches) says friends see "whether you trained today". But the rule (`firestore.rules`, `socialActivity/{userId}`) lets a connected friend read `userId`, `firstName`, `trainedOn` (exact date), `streakWeeks`, and `updatedAt`, a full ISO timestamp that gives roughly when you finished (`store.ts:114-120`). Policy §3 (line 56) says "the day you last trained", which contradicts §1/§2. The policy also says "Leave … deletes what was shared", but Leave only deletes the connection (`store.ts:189`). Fix: drop `updatedAt`/`userId` from the shared doc or the rule, and make the policy match the five fields, including streak.

**F49. Invite codes have no rate limit on accepting. CONFIRMED, medium.** Codes are 8 characters from 31 symbols, about 40 bits (`store.ts:47-48`). `acceptSocialInviteCallable` (`index.ts:~1006`) has no rate limit, and App Check isn't enforced. Any user who has consented can keep guessing, and a hit links them to a stranger. A per-user limit on accepts, or failed accepts, fixes it. Also, `myo://` is a custom scheme that another app can claim; a universal link would avoid that. Expiry (7 days), single use, no self-invite and the inviter-still-consents check are all correct.

**F50. Revoking consent can bypass the cleanup. PLAUSIBLE, medium-low.** Clients may write their own `consentRecords` (`firestore.rules`, owner write). A direct `granted:false` write skips `removeSocialData`, and the friend read rule never re-checks the owner's consent, so friends keep reading. The app always uses the callable, so this is defence in depth. Turning the server flag off after it was on has the same effect: the docs stay readable and Leave refuses. Fix: the friend read rule also requires the owner's current social consent.

**F51. Publish versus delete race. PLAUSIBLE, low.** `publishSocialActivity` checks consent, then writes, outside a transaction (`store.ts:103-122`). A workout trigger running at the same moment as a revoke or deleteAccount can leave the activity doc with the first name behind. Nobody can read it, but it breaks the deletion promise.

**Low:**
- The 20-friend cap is checked only for the accepter, not the inviter (`store.ts:163`).
- The daily friend mention is marked used before the model replies (`orchestrate.ts:280`), so a failed turn loses it for the day.
- F52: the social cleanup in deleteAccount/resetMyData (`index.ts:372,408`) runs even when the flag is off and can fail deletion.

**Fine:**
- Rules: no client writes to any social doc; invites can't be read; connections are visible only to their two members; nothing under `users/` opens up.
- Cleanup: revoke, deleteAccount, resetMyData and `recordConsent(granted:false)` remove both-way connections, invites, the activity doc and the mention record.
- Coach mentions: only "{FirstName} [and N others] trained today.", with the name cut to one word of letters, apostrophes or hyphens, at most 20 characters (`store.ts:66-71`). Prompt injection is negligible.
- The rules tests make real denial assertions against the emulator, and the store tests are real. Not covered: the `index.ts` wiring (flag gate, revoke/delete hooks).

## #60 Phase 4 recovery reads (a565aef)

**Verdict: merge after F45 is fixed in this PR (text only). The code is otherwise sound.**

**F45. Health numbers leave the phone, but the privacy policy says there is no HealthKit integration. CONFIRMED, high.** Resting HR, HRV and sleep (today and the 28-day baseline) go to the backend. From there they reach the model provider, OpenAI or Gemini: `prompt.ts:235` `<health_summary>`, and the `<recovery>` block in the live-voice setup (`liveWorkout.ts` `recoveryRules`). `legal/privacy-policy.md:40` still says "the iOS app has no HealthKit integration yet". That was already stale after #39. The switch caption ("Compared with your own last four weeks…") doesn't say the numbers leave the phone. Apple 5.1.3 requires disclosing Health data shared with third parties. Fix: update policy line 40 (md + html) to cover the reads, what is sent and to whom, and that nothing is stored server-side. Also add "sent to your coach" to the caption.

**F46. "Offered" is recorded when the go-ahead is sent, not when the coach says it. PLAUSIBLE, low.** `AppModel.swift` (live setup, ~line 426, and the coach-message context, ~line 545) calls `noteLighterOffered()` as soon as `offerLighter: true` rides on a payload. If the live session drops before speaking, or the text turn is about something else, the offer is lost for the day. This fails safe (under-offers), so it's acceptable.

**F47. "slept X h last night" is really the last 24 h ending now. PLAUSIBLE, low.** `lastDaySleepHours` uses `now − 24 h … now`. That's fine read in the morning. Read at 8 pm, it can include an afternoon nap and only part of the night.

**Checked and fine:**
- **Runtime APIs (the F42 rule):** `HKStatisticsCollectionQueryDescriptor`, `HKSampleQueryDescriptor`, `HKCategoryValueSleepAnalysis.allAsleepValues`, `enumerateStatistics(from:to:)`, `averageQuantity` and `requestAuthorization(toShare:read:)` are all present in the iOS 26.3 simulator runtime's HealthKit binary. They are method calls, not newly added property getters.
- **Permission:** read-only (`toShare: []`), asked only from the "Coach reads recovery" switch, never at launch. Denial correctly yields empty queries.
- **Thresholds have a written rationale** (`RecoveryBaseline.swift` header): 28-day median baseline with at least 10 days of data, resting HR +7 bpm (the plan's number), HRV ≤ 80 % (wrist SDNN CV 10–20 %), sleep < 6 h, and low only when two or more signals agree. None are tuned to anyone's data.
- **Once-only:** keyed per day in UserDefaults, only on a training day not yet trained and before the first set. A reconnect gets `offerLighter: false`, and the server rules then say "don't offer". This is covered by `testOfferIsOnceADayAndOnlyBeforeTheFirstSet` and the server tests. The offer only goes through `replace_session` / `adapt_plan` (a review card), never as a silent change.
- **Contract:** Swift clamps values to the zod bounds. A bad `recovery` is dropped without dropping the message or the session (tested).
- **Tests are real:** 12 Swift tests on the pure maths (median outlier, window edges, overlap merge) and 8 server tests on behaviour.

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
