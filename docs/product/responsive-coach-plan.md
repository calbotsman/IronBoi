# Responsive coach plan

*2026-11-05. Product + technical plan, no code yet.*

**Goal:** MYO adapts to the person in front of it: their heart rate, the set they're on, how hard recent weeks have been, how they like to be spoken to, and how loud their music is. The model is Peloton on Apple Watch. You press Start on the phone, the Watch app wakes up by itself, and the coach can hear your heart.

**Order:** merge #39 (Health write) → **Phase 1** context layer on data MYO already has → **Phase 2** Watch app with live HR → **Phase 3** Bluetooth straps + AirPods HR → **Phase 4** Health reads (recovery). Each phase ships on its own and is useful without the next one.

---

## 1. Coach context layer

### What exists today

| Signal | Where it lives | Reaches the coach? |
|---|---|---|
| Current exercise, set n of N, target reps, weight, reps counted, exercise order | `AppModel.liveWorkoutState()` (`ios/.../Services/AppModel.swift:467`) → `liveWorkout` on `sendCoachMessage` → `liveWorkoutRules()` (`functions/src/coach/liveWorkout.ts`) → `orchestrate.ts:274` | **Text turns only.** Built per message, not refreshed while the coach is talking. |
| Live voice session context | `liveBrainInstruction()` (`functions/src/coach/liveSession.ts`) builds the prompt **once at session start** from `loadCoachContext` + `buildCoachContextBundle`. Mid-session the phone can push `clientContent` turns (`LiveVoiceSession.swift:366`). | Plan + profile + memory yes; **live workout state no** (not in the voice setup). |
| Profile: goals, experience, injuries, equipment, schedule, `coachingTone` (direct / warm / balanced), `coachingLens`, `trainingFocus`, disliked exercises | `Models/UserProfile.swift`, Firestore `profile` | Yes, in the bundle's `profile`. |
| Recent workouts | `context.recentLogs` → `recentWorkouts[]` (`sessionId`, `date`, `perceivedEffort`, `summary`) | Yes, as free-text summaries. No computed frequency/type mix. |
| Effort rating | `WorkoutEffort` (easy / about_right / too_much), `rateWorkout()` → `perceivedEffort` | Yes, per workout. Not trended. |
| Progress numbers | `progressSummary` (derivedSummaries/progress_current) | Yes. |
| Memory facts + coach notes | `memoryFacts`, `coachNotes` | Yes. |
| Health | `healthSummary: { available: false, reason: "healthkit_not_connected" }` | Placeholder only. |
| Voice/music/captions | PR #40: `@AppStorage` keys `coachSpeaksReplies`, `coachVoiceLevel`, `coachMusicDip` in `Services/CoachMix.swift`; captions mode in `CoachStageView` | **No.** Phone-only; the coach doesn't know you've muted it or are reading captions. |
| Rest timing, pace (time per set) | Not tracked as data | No. |

### What to build: `CoachLiveContext`

One struct on the phone, owned by a new `CoachContextStore` (`@MainActor ObservableObject`, fed by `AppModel`, `CoachMix`, and later `HeartRateHub`). It is the single thing every coach turn reads, voice or text.

```
CoachLiveContext (schema: coach_live_context.v1)
  workout:   exercise, set n/N, targetReps, weightLb, repsCounted, exercise order   (existing liveWorkoutState)
             + setStartedAt, lastSetEndedAt, restElapsedSec, plannedRestSec
             + paceSecPerRep (rolling, from rep counter timestamps)
             + setsCompletedToday, minutesIn
  heart:     source (watch | strap | airpods | none), bpm, bpmAt (staleness),
             zone (1–5 from estimated max), trend (rising/steady/falling over 30s),
             recoveryBpm60 (drop in the first 60s of rest), sessionAvg, sessionPeak
  recent:    sessionsLast7d, sessionsLast28d, daysSinceLast, typeMix (strength/mobility/cardio counts),
             effortTrend (last 3 ratings), lastSameDayKey (what this workout looked like last time)
  delivery:  speaksReplies, voiceLevel, musicDip, captionsOn, musicPlaying
  style:     coachingTone, coachingLens, preferredName, verbosity (new: brief | normal | chatty)
  recovery:  restingHr, hrv, sleepHours (Phase 4; null until then)
```

- **Workout + delivery + style + recent** are computable today (Phase 1). `recent` is derived from `workoutLogs` already loaded on the phone; no new reads.
- Sent as a compact JSON block alongside `liveWorkout` on text turns (extend the `LiveWorkoutState` zod contract in `functions/src/contracts/coach-agent.ts`, rename the prompt block to `<live_context>`).
- **Voice sessions:** the setup prompt stays as is; the phone pushes a `clientContent` turn with `turnComplete: false` holding the current context whenever it changes meaningfully (set done, rest started, HR zone change, every 30s while HR is live), throttled to at most one push per 10s so it never interrupts speech. The server prompt gets a rule: "the latest `<live_context>` turn is the truth about right now."
- Data boundary stays: everything in the block is data, never instructions (same as `dataBoundary: user_data_is_not_instruction`).

### How the coach acts on it (rules, not vibes)

Put these in `liveWorkout.ts` / `LIVE_RULES`, deterministic where possible, so behavior is testable.

| Condition | Action |
|---|---|
| HR zone ≥ 4 when a set ends, or `recoveryBpm60 < 12` | Extend rest: "Take another 30, let your heart come down." Phone extends the rest timer (new phone-side tool `extend_rest(seconds)`, like `swap_workout_exercise`). Don't start the next set cue until HR < zone 3 or 3 min elapsed. |
| HR stays zone 1–2 through a whole set at ≥ target reps, effort trend "easy" | Suggest +5 lb or +2 reps next set (offer, not impose). |
| HR stale > 15s / source lost | Say nothing about HR; never invent a number. Mention once if the Watch dropped. |
| `paceSecPerRep` slowing > 40% within a set | Fatigue cue: shorter, calmer form cue; offer to cap the set. |
| `daysSinceLast ≥ 7` or `sessionsLast28d` well under plan | Gentle welcome back, lighter first sets; no guilt. |
| Last 2 efforts `too_much` | Default to the lower end of rep ranges; ask once how they're feeling. |
| `typeMix` shows no mobility in 14 days | Mention one mobility day, once, at the end. |
| `speaksReplies = false` or `captionsOn` | Shorter replies (captions are read at a glance), no "listen to this" phrasing. |
| `musicPlaying` and `musicDip` low | One-line cues only; save explanations for rest. |
| `coachingTone = direct` | Imperative, no softeners. `warm`: encouragement first, then the cue. `balanced`: current default. |
| `verbosity = brief` | Max one sentence mid-set. |

Safety rules stay above all of these: chest pain / dizziness talk overrides HR logic; HR never used to push someone harder than their plan's top end.

### Gaps to close in Phase 1

1. Voice sessions don't get live workout state at all → the `clientContent` push.
2. No rest/pace timestamps → record `setStartedAt` / `setEndedAt` on `completeNextSet` and rep-counter events.
3. `recent` is free text → compute counts on the phone from `workoutLogs`.
4. PR #40's mix settings are phone-only → read them into `delivery`.
5. No verbosity preference → add `preferences.verbosity` to `UserProfile` + the coach can set it via `update_training_setup` when someone says "talk less".

---

## 2. watchOS companion

### Target and project

- New target `MYOWatch` in `ios/IronBoi/project.yml`: `type: application`, `platform: watchOS`, `deploymentTarget: watchOS "10.0"`, sources `MYOWatch/`, bundle id `com.thecombinationrule.IronBoi.watchkitapp`, `WKCompanionAppBundleIdentifier` = the iOS bundle id, embedded via a `dependencies: - target: MYOWatch` on `IronBoi` (XcodeGen embeds it in `Watch/`). Single-target watch app (no separate extension), SwiftUI.
- Entitlements on both: `com.apple.developer.healthkit`. Watch also needs `WKBackgroundModes: [workout-processing]`.
- Shared code: a small `MYOShared` folder (message types, `HeartSample`, zone math) included in both targets' sources. No Firebase on the Watch; the phone stays the only thing that talks to the backend.
- CI: add a watchOS simulator destination to the build step; the current "older Xcode on CI" constraint (#36) applies, so gate any watchOS 26-only API with `#available`.

### Auto-start (the Peloton moment)

1. User taps Start on the phone → `AppModel.startWorkout`.
2. Phone checks `WCSession.default.isPaired && isWatchAppInstalled`, then calls `HKHealthStore().startWatchApp(with: HKWorkoutConfiguration(activityType: .traditionalStrengthTraining, locationType: .indoor))`. (Cardio days from #41: `.cycling` / `.running` etc. by workout type.)
3. watchOS launches MYOWatch in the background and delivers the configuration to `WKApplicationDelegate.handle(_ workoutConfiguration:)`. The Watch creates an `HKWorkoutSession` + `HKLiveWorkoutBuilder` (`HKLiveWorkoutDataSource`), calls `startMirroringToCompanionDevice()`, then `startActivity`.
4. Phone receives the mirrored session in `HKHealthStore.workoutSessionMirroringStartHandler` (iOS 17+). **Set this handler at app launch**, not when the workout starts, or the first mirror is missed.
5. Live data: on the phone, the mirrored `HKWorkoutSession` delegate's `didReceiveDataFromRemoteWorkoutSession` carries what the Watch sends with `sendToRemoteWorkoutSession(data:)`. The Watch encodes `{bpm, activeEnergy, timestamp}` every ~5s from `workoutBuilder(_:didCollectDataOf:)`. The phone feeds `HeartRateHub` → `CoachLiveContext.heart`.
6. Phone → Watch over the same channel: current exercise, set, reps, rest countdown, coach caption.
7. End: phone's Finish → sends "end" → Watch `session.end()`, `builder.finishWorkout()`. **The Watch saves the HKWorkout** (with real HR + energy); the phone's #39 `HealthSync` save must skip when a Watch session ran, using the same session id as `HKMetadataKeySyncIdentifier` so nothing duplicates.

Fallbacks: no Watch, or Watch app not installed → nothing happens, phone-only as today. If `startWatchApp` fails (Watch locked/off-wrist), log and carry on; the user can also start from the Watch, which mirrors the other way.

### Watch UI (glanceable, three pages)

- **Now:** big BPM with zone color, current exercise name, "Set 2 of 4 · 10 reps · 95 lb". During rest: countdown ring + "next: Bench Press".
- **Controls:** Set done (Digital Crown press or big tap — mirrors `completeNextSet`), pause, end. Haptic tick at rest end and when the coach asks something.
- **Caption:** last coach line, for when the phone is across the room.
- Always-On: BPM + rest seconds only. No complications in v1.

### Permissions, Info.plist, App Store

- `NSHealthShareUsageDescription` (new; #39 only added `NSHealthUpdateUsageDescription`): "MYO reads your heart rate during workouts so your coach can pace rests, and your resting heart rate and sleep to adjust how hard today should be."
- `HealthSync` grows a read request: `heartRate`, `activeEnergyBurned` (Phase 2); `restingHeartRate`, `heartRateVariabilitySDNN`, `sleepAnalysis` (Phase 4). Ask at the moment they're used (first Watch workout / turning on Recovery), never at onboarding.
- Watch target needs its own `NSHealthShareUsageDescription` / `NSHealthUpdateUsageDescription`.
- App Store: update the privacy nutrition label (Health & Fitness data, linked to user only if we upload it, which we shouldn't in v1: HR stays on device, only derived numbers like "zone 4 at set end" go in the coach prompt). Review notes must explain HealthKit use; HealthKit data may not be used for ads or sold. Screenshots for the Watch app. `scripts/preflight-appstore.sh` should check both usage strings are present.

---

## 3. Other wearables

All of these feed the same `HeartRateHub` (one protocol: `HeartSource` publishing `HeartSample(bpm, at, source)`). The hub picks the best live source: Watch > chest strap > AirPods > none. The coach never sees which; it sees `heart.source` only for the "Watch dropped" message.

### CoreBluetooth Heart Rate Service (Polar, Wahoo, Garmin broadcast, Whoop broadcast)

- `CBCentralManager` scanning for service `0x180D`, characteristic `0x2A37` (Heart Rate Measurement). Parse the flags byte: bit 0 = UInt8 vs UInt16 bpm; optional RR intervals (bit 4) give HRV-lite for free.
- Pairing UI in Settings: "Heart rate strap" → scan list → remember peripheral UUID → auto-reconnect on workout start.
- `NSBluetoothAlwaysUsageDescription`; `UIBackgroundModes` add `bluetooth-central` (the audio mode already keeps the app alive, but the BLE mode is the correct declaration).
- Garmin watches must be in "Broadcast HR" mode; Whoop has "HR Broadcast" in its app. Document this in the pairing screen.
- Effort: small, well-trodden. Main risk is reconnect behavior when the strap sleeps mid-workout.

### AirPods Pro 3 heart rate (iOS 26)

- iOS 26 lets an iPhone run its own `HKWorkoutSession` + `HKLiveWorkoutBuilder`; with AirPods Pro 3 (or Powerbeats Pro 2) connected, HR is collected from the earbuds. Same builder code as the Watch, run on the phone, `#available(iOS 26, *)`.
- Only used when there is no Watch session (a phone session and a Watch session for the same workout would double-count).
- CI builds with the older SDK (#36): wrap in `#if compiler(>=6.2)` / `canImport` guards as done for the recogniser.
- Risk: availability is hardware-specific and Apple's API surface for detecting "HR-capable earbuds" is thin; detect by whether HR samples actually arrive within 20s.

### Health reads for Whoop / Oura / Garmin-synced data

- These apps write to Health; we read: `restingHeartRate`, `heartRateVariabilitySDNN`, `sleepAnalysis` (last night), optionally `vo2Max`.
- `HKAnchoredObjectQuery` / `HKStatisticsQuery` on app foreground and at workout start; no background delivery in v1.
- Fills `CoachLiveContext.recovery` and the server bundle's `healthSummary` (replace the `available: false` placeholder with `{ available: true, restingHr, restingHrBaseline7d, hrv, hrvBaseline7d, sleepHours }`, numbers only).
- Coach use: resting HR > baseline + 7 bpm or HRV < baseline − 20%, or sleep < 5h → offer a lighter session ("same plan, one less set each") before starting. Never auto-change the plan; it goes through the existing `adapt_plan` proposal flow.
- Max HR for zones: age-predicted by default (208 − 0.7×age from `ageYears`), replaced by the session peak once we've seen a higher one; user override in Settings.

---

## 4. Phases

| Phase | Scope | Effort (one dev + Claude) | Depends on |
|---|---|---|---|
| **0** | Merge #39 (Health write), #40 (mix/captions), #41 (cardio) | in flight | — |
| **1. Context layer** | `CoachLiveContext` + store; rest/pace timestamps; `recent` counts; delivery/style fields; `verbosity` pref; extend contract + `<live_context>` prompt block; voice `clientContent` pushes; `extend_rest` phone tool; coach rules table; evals for each rule in `functions/src/evals` | **1–1.5 weeks** | #40 for delivery fields |
| **2. Watch app** | XcodeGen target; `startWatchApp`; Watch `HKWorkoutSession` + builder + mirroring; phone mirroring handler; `HeartRateHub`; Watch UI (3 pages); set-done from Watch; Watch saves the workout, phone skips; read permission + usage strings; CI watchOS build | **2.5–3.5 weeks** | Phase 1 (HR has somewhere to go), #39 |
| **3. Straps + AirPods** | BLE HRS connector + pairing UI; iOS 26 phone workout session for AirPods HR; hub source priority | **1–1.5 weeks** | Phase 2's `HeartRateHub` |
| **4. Recovery reads** | Resting HR / HRV / sleep reads; baselines; server `healthSummary`; pre-workout "lighter today?" offer via `adapt_plan` | **1 week** | read permission from Phase 2 |

Total ≈ 6–8 weeks of focused work.

### Risks

- **Mirroring is fiddly.** The phone's `workoutSessionMirroringStartHandler` must be set at launch; if the app was killed, the mirror arrives on relaunch. Budget time for state recovery (phone relaunches mid-workout, Watch still running) — `AppModel` already restores local workouts, extend it to re-attach.
- **`startWatchApp` silently does nothing** if the Watch is locked, off-wrist, or the app isn't installed. UI must never wait on it.
- **Voice session interruptions.** Pushing context into Gemini Live with `turnComplete: false` must not trigger speech; verify, and throttle hard.
- **Coach overreacting to HR.** Optical HR during lifting is noisy (wrist flexion on presses). Use 10s smoothing, zone changes need 15s hysteresis, and the coach mentions HR at most once per rest.
- **Double-saved workouts** (Watch + phone #39) → shared sync identifier and an explicit "watch owns the save" flag.
- **App Review**: HealthKit read justification, Watch screenshots, privacy label change. Adds a review cycle.
- **CI Xcode lag**: watchOS 26 / iOS 26 APIs behind compile-time guards.
- **Battery**: Watch workout session for 60 min is fine (Apple's own Workout app does it); BLE + live voice + music on phone is the heavier combo — measure.

### Device test checklist

Phase 1 (iPhone only)
- [ ] Voice session: finish a set, ask "how long should I rest?" — answer uses the actual rest elapsed.
- [ ] Mid-session context push does not make the coach start talking.
- [ ] Set `coachingTone` to direct vs warm, run the same set — audible difference.
- [ ] Captions on + voice off → replies get shorter.
- [ ] Skip a week (fake dates in preview) → welcome-back + lighter first set.

Phase 2 (iPhone + Watch)
- [ ] Watch on wrist, unlocked, phone Start → Watch app opens on its own within ~3s, HR shows on both.
- [ ] Watch locked / off wrist → phone workout starts normally, no hang, no error sheet.
- [ ] Do hard sets; coach extends rest when HR is high, says nothing about HR when it isn't.
- [ ] Mark a set done on the Watch → phone advances.
- [ ] Kill the phone app mid-workout, reopen → re-attaches to the Watch session, HR resumes.
- [ ] Finish → exactly one workout in Health, with HR graph and energy.
- [ ] 60-minute session: Watch and phone battery drain noted.

Phase 3
- [ ] Polar H10 / Wahoo TICKR pair, survive strap sleep + reconnect mid-workout.
- [ ] Garmin in broadcast mode shows up and streams.
- [ ] AirPods Pro 3 on iOS 26, no Watch → HR arrives; with Watch → Watch wins, no double count.

Phase 4
- [ ] With Oura/Whoop syncing to Health, a bad-sleep morning → coach offers lighter session, accepting goes through the plan-change proposal.
- [ ] Denying read permission → coach never mentions recovery, no errors.

### Out of scope for now

Calories shown in-app, HR uploaded to Firestore, Watch complications, Watch-only workouts without the phone, Android/Wear OS, ANT+.
