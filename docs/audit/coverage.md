# Coverage: Josh's ideas and the responsive coach plan

*Watchdog audit, updated 2026-11-05. Sources: `docs/product/ideas.md`, `docs/product/responsive-coach-plan.md`.*
Status values: not started, in PR #N, merged (#N), dropped.

## Ideas (`ideas.md`)

| # | Idea | In plan? | Status | Note |
|---|---|---|---|---|
| I1 | Peloton-style auto-start: Watch app opens on phone Start, streams HR + calories | Yes (§2) | in PR #48 (F30–F32); calories streamed but not shown | Plan says "Calories shown in-app" is out of scope, but the idea asks for calories streamed back. **Partial conflict.** |
| I2 | Other wearables: BLE straps live; Whoop/Oura/Garmin via Health | Yes (§3) | straps/AirPods in PR #52 (F33–F35); Health reads **deferred** (Phase 4, unassigned) | — |
| I3 | Live stats pill (HR, calories, + one; swipe away / tap back) | **No** | in PR #49 (F13–F15) | **Plan gap.** No phone UI for live stats anywhere in the plan. Calories are listed as out of scope. |
| I4 | Colour + grain follow effort (zones from own max HR, ~10 s blend) | **No** | in PR #49 (F13, F15) | **Plan gap.** No Metal shader or atmosphere work in any phase. `HeartZones` (#44) is the only part that could be reused. |
| I5 | MYO mirrors you (blob bounces with high HR, breathes with low) | **No** | in PR #49 (F13, F15) | **Plan gap.** |
| I6 | Rest by recovery ("your HR's back down, let's go") | Partly (§1 rules) | in PR #44 (prompt rule) + #49 (voice line only, F13) | The rule tells the coach to wait. The phone rest timer still says "Go" on its own clock. No HR-driven end of rest. |
| I7 | Works without colour (brightness/contrast/grain; greyscale test) | **No** | in PR #49 (F13, F15) | **Plan gap.** Goes with I4. |
| I8 | Coach responds to HR, workout, music levels, talk style, frequency, kinds, weights, reps | Yes (§1) | in PR #44 (partial) | Sent: rest, sets, minutes, frequency, efforts, voice on/off, music playing. **Not sent:** music *levels* (voiceLevel/musicDip), training type mix, pace. See F3. |
| I9 | "I'm not doing that, I'm going for a run": whole session replaced, logged as a run, from loose speech, no phrase rules | **No** | in PR #51; #41 hijack fixed, but "let's go for a run" is still caught by the rest/hold handlers (F21, F22) | **Plan gap.** Merged #41 catches "I'm going for a run" with a regex and *adds* a 20-min Run to the end of the strength workout (F1). HealthSync (#39) logs every workout as strength or flexibility. |
| I10 | Ask lightly, once ("kettlebell work after?") from the profile's training goals; drop it on "no" | **No** | in PR #51; asks once per *session*, gear from a fixed list (F23) | **Plan gap.** The nearest plan item is "no mobility in 14 days → mention once", and #44 dropped it. Nothing remembers "asked, said no". |
| I11 | Instant start: phone caches a memory brief | **No** | in PR #50 (F16–F18, F20) | **Plan gap.** |
| I12 | Brief rebuilt on the server after each workout or conversation | **No** | in PR #50 (F16–F18, F20) | **Plan gap.** |
| I13 | Brief stays small (~1–2k words, safety/injuries always in) | **No** | in PR #50 (F16–F18, F20) | **Plan gap.** |
| I14 | Deep recall on demand ("what did I bench last spring?") | **No** | in PR #50 (workout logs only; F19); conversations + vector search **deferred** | **Plan gap.** |
| I15 | Social, opt-in (one onboarding question, off by default) | **No** | **deferred** (unassigned) | **Plan gap.** |
| I16 | Join by invite link, no feeds | **No** | **deferred** (unassigned) | **Plan gap.** |
| I17 | Coach brings friends in ("Sam trained this morning") | **No** | **deferred** (unassigned) | **Plan gap.** |
| I18 | Social prototype first | **No** | **deferred** (unassigned) | **Plan gap.** |

**Ideas the plan silently leaves out:** I3 live stats pill, I4/I5/I7 HR atmosphere (colour, grain, MYO mirroring, colour-blind safe), I9 voice workout replacement, I10 ask-once suggestion, I11–I13 cached memory brief, I14 deep recall, I15–I18 opt-in social. None of these has a phase, an owner or an estimate.

| I19 | Bank alternatives so swaps are instant (new, 2026-11-05) | No | in PR #51 (F24) | — |
| I20 | Rep counter must count past target (new, 2026-11-05) | No | in PR #46 | F10–F12 |
| I22 | "10 reps each side": unilateral lifts counted and logged per side (new, 2026-11-05) | No | in PR #47 | Per-side logged from voice counts only; must be ported onto #46's `SetCount`. |
| I21 | Voice weight changes, total vs per-side (bug) | No | in PR #47 | F36–F39 |

**Deferred, not dropped:** Phase 4 recovery reads, social (I15–I18), deep-recall vector search.

## Plan items (`responsive-coach-plan.md`)

| # | Plan item | Status | Note |
|---|---|---|---|
| P0a | #39 Health write | merged (#39) | F7 |
| P0b | #40 mix / captions | merged (#40) | Clean |
| P0c | #41 cardio | merged (#41) | F1, F2 |
| P1.1 | `CoachLiveContext` struct + store | in PR #44 | `[String: Any]` dict on AppModel, not a separate store. Acceptable. |
| P1.2 | workout: rest elapsed/planned, sets done, minutes in | in PR #44 | — |
| P1.3 | `paceSecPerRep` + "pace slowing >40% → fatigue cue" rule | **dropped (silently)** | `lastSetSec` is in the server contract but the phone never sends it (F3). |
| P1.4 | `recent`: 7d/28d counts, days since, effort trend | in PR #44 | F8 |
| P1.5 | `recent.typeMix` + "no mobility in 14 d" rule | **dropped (silently)** | — |
| P1.6 | `recent.lastSameDayKey` | **dropped (silently)** | — |
| P1.7 | delivery: speaksReplies, voiceLevel, musicDip, captionsOn, musicPlaying | in PR #44 (partial) | Only speaksReplies + musicPlaying. |
| P1.8 | style: tone, lens, name | n/a | Already in the profile bundle. |
| P1.9 | `verbosity` pref | dropped (disclosed) | PR says `coachTips` covers it. Reasonable. |
| P1.10 | `<live_context>` prompt block + contract | in PR #44 | — |
| P1.11 | Voice `clientContent` pushes (turnComplete false, ≤1 per 10 s, every 30 s while HR is live) | in PR #44 (partial) | 3 s debounce, sent only on view re-render; no 30 s HR cadence; rest *elapsed* not in the note (F5). turnComplete false checked against the Gemini Live docs: it doesn't interrupt. |
| P1.12 | `extend_rest` phone tool | in PR #44 | F9 |
| P1.13 | Coach rules table | in PR #44 (partial) | HR, too-much, easy, welcome-back, voice-off and music rules done. Pace, mobility and tone rules not done. |
| P1.14 | Evals per rule in `functions/src/evals` | **not started** | Only a unit test on prompt strings. |
| P2 | Watch app, auto-start, mirroring, HeartRateHub feed, Watch UI, Watch saves workout | in PR #48 | Real HR feed + trend/recovery now computed (resolves F4). F30–F32. |
| P3 | BLE straps, AirPods HR | in PR #52 | — |
| P4 | Recovery reads (resting HR, HRV, sleep) | **deferred** (unassigned) | — |

## Not an idea, but tracked

| Live voice "weird and laggy" (Josh, real workout) | #53 (3b7e6c2) fixes L1 (off-main decode). L3 (mint wait) and L2 (half-duplex with music) are still open; #38 B2 may cause silent gaps after tools. |

## Merged vs device-tested (2026-11-05, end of day)

| PR | What | Merged | Device-tested | Open watchdog findings carried in |
|---|---|---|---|---|
| #39 | Health save | yes | **no** (3/3 checks unticked) | F7 |
| #40 | Captions, mix | yes | no (PR says signing blocked) | — (and caused F40, now fixed) |
| #41 | Cardio add | yes | no | F2 (F1 fixed by #51) |
| #44 | Live context | yes | no (0/4) | F3, F5, F8, F9 |
| #46 | Rep count past target | yes | no | — |
| #47 | Weight / sides | yes | no | F36–F39 unless fixed after the audit |
| #48 | Watch app | yes | no (0/12); **crashes main at launch (F42)** | F30 (8 s Watch-end timeout still on main), F31, F32 |
| #49 | Atmosphere | yes | no | F14, F15 (F13 mostly resolved by #48's real HR) |
| #50 | Memory brief | yes | no | F16–F20 |
| #51 | Session switch | yes | no (0/3) | F21–F25 |
| #52 | Straps / AirPods | yes | no (0/10) | F33 now gated on `HealthSync.enabled` on main (partly fixed); F34, F35 |
| #54 | F40 plist fix | yes | build-verified | — |
| #38 | OpenAI Realtime live voice | **no** (safe once iOS CI is green) | no | B1–B3 fixed; carries the F42 crash fix |
| #53 | Live voice reliability | **no** (safe once iOS CI is green) | no | B4–B6, F27, F28 fixed |

**Nothing has been device-tested.** Every merged feature has compiled and passed CI but has never run on a phone; the one device attempt (live-voice-fix) crashed on F40. Priority device run: a full workout with the Watch, Spotify on the speaker, and live voice on, to cover F30, L2, B2 and #46 together.
