# MYO handoff, 2026-10-14

For a fresh session picking up from the 2026-10-13/14 work. Josh wants short, plain replies.

## Where things are

- **Code:** everything through PR #36 is merged to `main` (merge commit `de8681c`). Later work is on the branch **`claude/build-58`** (pushed, **no PR yet**): build 58, the talk-or-tap onboarding start, build 59. Open a PR from it to `main` when Josh is happy.
- **Josh's phone:** build **59**, installed directly from the Mac (not TestFlight). It's the newest code.
- **TestFlight:** the newest real build is **58** (merged `main`). Builds 47, 52, 53 and 57 are stray uploads from Xcode on the old `main`, with the old onboarding; ignore them. `~/IronBoi` is now pulled up to date with `main`.
- **Backend:** staging (`ironboi-staging`) runs the latest functions. 630 security tests pass.
- **Josh's staging account:** freshly reset at 12:58 on 10-14, ready for a new onboarding run. His real pre-testing data is in `~/IronBoi-backups/josh-staging-2026-10-13-0645.json`; `restore-josh.py` restores it.

## What was built (all in main or claude/build-58)

- **Onboarding** (`ios/.../Features/Onboarding/OnboardingStageView.swift`):
  - First screen: talk or tap. **Voice mode** is almost UI-free: the coach asks, the mic opens, two misses show taps, "yes" accepts the week. **Tap mode** is cards.
  - Steps: goal, what you like to do (demand data), experience, gear, days and time, about you, a 4-page health screen, color, voice and coaching style.
  - The plan shows as one line at the top that opens into the full list.
- **Health screen:**
  - `functions/src/onboarding/healthScreen.ts` holds the ACSM-2015 logic: symptoms, or known heart/diabetes/kidney disease while inactive, means no plan until "My doctor cleared me". Other conditions mean a moderate start, with notes the coach sees.
  - Adults only (18+).
  - The wording is ours and still needs a clinician's review before any public launch.
- **Look and feel:**
  - The coach color picker is a hue ribbon plus a soft/vivid track.
  - 8 coach voices: female or male × warm, upbeat, firm, calm. They're on a server allowlist and also used by live voice.
  - 6 paper themes on the You screen.
- **Body:**
  - Moves as data (`Orb/MoveSpec.swift`, `Orb/MoveLibrary.swift`), with 16 new moves.
  - A celebrate move at the end of a workout.
  - A live-voice `show_exercise` tool that runs on the phone.
- **Voice:**
  - Apple's iOS 26 SpeechAnalyzer recognizer (`Services/AnalyzerRecognition.swift`), with SFSpeech as the fallback. It only compiles on the Xcode 26 SDK, behind `#if compiler(>=6.2)`, because CI's Xcode is older.
  - Counting each side, a more forgiving count parser, and echo filtering.
  - Coach replies wait while you count. Live voice is silent during a count.
  - Live voice can swap exercises with `swap_workout_exercise`, which runs on the phone.
  - An audio-engine rebuild when the mic hits error -50.
- **Workouts:**
  - Timed holds and carries, flagged `timed` in the catalog on both server and phone; a test keeps the two lists in step. Say "go", or tap Start hold, for a countdown that logs the seconds.
  - The workout finish celebrates. Session duration is logged.
- **Coach:**
  - It's honest that yoga, running and sport plans aren't built yet.
  - A "yoga day" request gives real mobility and core work.
  - It reads misheard phrases in context.

## Open items (in order)

1. **Josh tests a workout** on his phone (build 59), ideally one with a plank and a single-arm row. Then pull the voice log and fix counting from real data:
   This command was tested on 10-14 and works. The log already shows the new recognizer in use ("heard (analyzer)"), and a first clue: "dumbbells" heard as "and bells" during gear.
   ```bash
   xcrun devicectl device copy from --device A4AE52FB-983F-5BFB-B46B-0BC8B6E3741A --domain-type appDataContainer --domain-identifier com.thecombinationrule.ironboi --source Documents/audio-log.txt --destination ./audio-log.txt
   ```
2. **Check voice-mode onboarding** with Josh's real voice. Only the first four steps were checked, with simulated speech.
3. **Row demo:** Josh said it looked off. It hasn't been checked on screen; the second simulator's display is broken.
4. **Decision pending: live voice on by default** to fix reply latency. The regular coach takes 3–12 s.
5. **Open a PR** for `claude/build-58`.
6. **Bigger plan:** `docs/product/flexible-training-plan.md` (revised after the adversarial review; Josh's decisions are in §10). It's gated: voice and the safety screen first, then mobility inside lifting, then the AI planner, then running or yoga only when testers ask for them. No reviewer yet, so no new mobility or pose content ships. Testers: just Josh.

## How to work here

- **Fast test loop:** build Debug for the device and install directly. See memory `ironboi-direct-device-install`.
  ```bash
  xcodebuild -project ios/IronBoi/IronBoi.xcodeproj -scheme IronBoi -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath <scratch>/dd-device -allowProvisioningUpdates build
  xcrun devicectl device install app --device A4AE52FB-983F-5BFB-B46B-0BC8B6E3741A <scratch>/dd-device/Build/Products/Debug-iphoneos/IronBoi.app
  ```
- **TestFlight:**
  1. `./scripts/ios-bump-build.sh N`, then commit.
  2. `xcodebuild archive` (Release, `generic/platform=iOS`, `-allowProvisioningUpdates`).
  3. `xcodebuild -exportArchive` with an ExportOptions.plist: method `app-store-connect`, destination `upload`, teamID `SGQ2WLB6M9`, signingStyle `automatic`.
  4. Check the archive contains new strings before uploading, e.g. `strings …/IronBoi | grep "Four quick health questions"`.
- **Deploy functions:** `cd functions && npx firebase-tools deploy --only functions --project ironboi-staging --non-interactive`. If auth expires: `npx firebase-tools login --reauth`.
- **Backend tests:** `cd functions && npx firebase-tools emulators:exec --only firestore --project demo-ironboi-security "npx vitest run test/security --fileParallelism=false"`.
- **Reset Josh's account:** `python3 ~/IronBoi-backups/reset-josh-fresh.py --go`. Josh runs it himself; Claude's permissions block bulk deletes. If gcloud asks for a password, run `gcloud auth login --update-adc` in a terminal tab for him; he only clicks Allow.
- **Simulator checks:** set `coachSpeaksReplies` to false with `xcrun simctl spawn <udid> defaults write com.thecombinationrule.ironboi coachSpeaksReplies -bool false`, so nothing talks. Restore it afterwards. `SIMCTL_CHILD_MYO_FAKE_SPEECH="a | b | c"` feeds spoken answers.

## Gotchas

- **Xcode auto-numbers uploads** from `~/IronBoi`. That's how old-onboarding builds 47, 52, 53 and 57 got onto TestFlight. Keep `~/IronBoi` on current `main`.
- **Edit only your own worktree.** A hook blocks the Write tool on other worktrees' files.
- **Claude can't** merge PRs without Josh saying so in chat, bulk-delete Firestore data, or enter passwords. Auto-merge is disabled on the repo.
- **TypeScript strings in `coach/prompt.ts`** are double-quoted: escape inner quotes (an unescaped pair broke every coach test once).
- **Old app builds** drop plan exercises missing `sets`/`reps` (`AppModel.makePlannedExercise`), and server schemas are `.strict()`. Any data-model change needs dual-write (see the plan's §1 migration).
