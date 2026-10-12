# Live voice brain: replacing MYO's voice pipeline with Gemini Live

**Status:** design proposal, not built. Written 2026-10-12.
**Scope:** the Coach voice loop only. Typed messages, quick taps and the
Conversation screen stay on today's text pipeline.

---

## 0. Today in one paragraph

The phone transcribes on-device (`VoiceInputEngine.swift`, a 1.4 s pause ends
your turn). `CoachStageView.handleUtterance` either handles the words locally
(counts, "set done", weight, rest) or writes a `queued` message. That message
triggers `orchestrateCoachTurn` (`functions/src/coach/orchestrate.ts`):
preflight screen → context bundle → Gemini 2.5 Flash tool loop → postflight
screen. The phone then speaks the reply through Chirp 3 HD (`CoachVoice.swift`).
A full round trip plus speech synthesis comes before every word Coach says;
that is the dead air.

## 1. What the user will feel

| Changes | Stays the same |
|---|---|
| Coach starts talking about 0.5–1 s after you stop, instead of after a server round trip plus speech synthesis. | Rep counting, ticks, "set done", the rest timer and weight changes are instant and handled on the phone. |
| You can talk over Coach at any point and it stops and listens. Today that is reliable only with echo cancellation or headphones. | Music is lowered, not paused. AirPods stay in music quality. |
| One continuous conversation: Coach hears tone and hesitation, and remembers what was said two minutes ago without re-reading history. | Plan changes still show up as the review card. Nothing changes your plan without the server. |
| No "thinking" pause while it uses tools. With async tools it can keep talking ("pulling up swaps…"). | History, memory facts and the Conversation screen keep working, because every turn is still saved to Firestore. |
| | The same voice family. Chirp 3 HD "Sulafat" is one of the Gemini Live voices (`functions/src/voice/speech.ts`). |

## 2. Architecture options

| | (a) Phone connects straight to Gemini | (b) Relay on Cloud Run | (c) Hybrid (recommended) |
|---|---|---|---|
| Audio path | Phone ↔ Gemini over WebSocket, using a short-lived token | Phone ↔ relay ↔ Gemini | Phone ↔ Gemini directly |
| Tools, transcripts, safety | Run on the phone | Run in the relay | Firebase callables. The phone forwards tool calls and transcripts to them |
| Secrets on the device | None. Single-use token, about 15 min | None | None |
| Latency | Lowest | One extra hop, plus cold starts | Lowest |
| Metering | Only what the server minted | Exact, because the relay sees `usageMetadata` | Bounded by what the server minted, plus usage the phone reports (untrusted) |
| Ops cost | Small | A new always-on WebSocket service, heartbeats, scaling. This is the AgentBOB relay (`voice-pwa/server/live-relay.cjs`) MYO chose not to port in `docs/audits/agentbob-voice-reuse-audit.md` | Small. Nothing new runs all the time |
| Can it stop the model hearing a blocked phrase? | No | Only by holding audio back, which adds latency | No. See §4 |

**Recommendation: (c).** Audio goes direct. Everything that writes, decides or
screens runs on the server, through the existing callable surface.

- **Mint.** A new callable, `startLiveCoachSession`, uses `CALLABLE_OPTS`, so
  App Check applies once `IRONBOI_ENFORCE_APP_CHECK` is on. Like
  `synthesizeSpeechCallable`, it refuses anonymous sign-ins. It builds the
  system prompt server-side and mints a Gemini ephemeral token with
  `liveConnectConstraints` that lock the model, system instruction, tools,
  voice, transcription, VAD, compression and resumption. The token has
  `uses: 1`, `newSessionExpireTime` of 60 s and `expireTime` of about 15 min.
  This is the same pattern as `~/AgentBOB/orb-lab/server/mint.ts`. Marin
  (`~/marin/relay.mjs` `geminiToken`) mints unconstrained tokens and sends the
  config from the client. MYO must not do that, or a modified client could
  rewrite the coach's prompt.
- **Secrets.** The Gemini key stays in Secret Manager (the existing
  `geminiApiKey` secret). The phone only ever holds a single-use token.
- **Cost control.** The mint checks a new daily live-minutes cap (next to
  `usage/cap.ts`), so exposure is bounded by tokens minted × connection length.
  A kill-switch env var makes it refuse; the app falls back to today's pipeline.
- **Logging.** Turns go through `recordLiveTurn` (Firestore, `safeLogger`,
  `recordAuditEventBestEffort`). No audio is stored.
- **Endpoint.** The `BidiGenerateContentConstrained` WebSocket with
  `access_token` (as in `~/marin/index.html` `gemConnect`). The docs now show
  `v1beta/auth_tokens`, while orb-lab and Marin still use `v1alpha`; pin one in
  milestone 1.

**Model:** `gemini-3.8-live`. It went stable on 2026-09-15: default live model,
async function calling, 131,072-token input window. Note that proactive audio
is always on for this model and affective dialogue was removed. Fallback is
`gemini-2.5-flash-native-audio-preview-12-2025` (orb-lab and AgentBOB's
default). Google now calls `gemini-3.1-flash-live-preview`, which Marin runs,
"legacy". Firebase AI Logic's Swift `LiveModel` is still preview, doesn't list
3.8, and sets the prompt on the client, so it is not used here.

## 3. How the existing brain maps over

**Prompt.** `startLiveCoachSession` reuses `loadCoachContext`,
`buildCoachContextBundle`, `assembleCoachPrompt`, `VOICE_MODE_RULES`,
`BODY_RULES`, `coachStyleRules` and `liveWorkoutRules`. The bundle goes into the
locked system instruction instead of the user message. Config can't change
while a connection is open, so updates arrive three ways:

1. A phone-local tool, `get_workout_state`, which answers instantly from `AppModel`.
2. Short app notes sent as `sendRealtimeInput` text, such as
   `[app] Logged set 2 of Bench Press: 10 reps.` The prompt says these are
   context; proactive audio lets the model stay quiet.
3. Each reconnect (about every 10 min) mints a token with a rebuilt bundle.

**Tools.** The model never writes Firestore. Every tool call goes from the
phone to one callable, `coachLiveTool`. That callable runs
`buildCoachToolRegistry` + `executeTool` exactly as `orchestrate.ts` does,
with `authenticatedUserId` taken from the auth context.

| Today's tool | In the live session |
|---|---|
| `adapt_plan` | Server. `rawUserText` comes from the server's own transcript of this session (§4), never from the model. |
| `accept_plan_adjustment` / `reject_plan_adjustment` | Server. Keeps the turn-boundary rule: only a proposal published before the user's "yes" was transcribed can be accepted. The review card tap is unchanged. |
| `clear_plan_overrides`, `remember_user_fact`, `forget_user_fact` | Server. The verbatim check runs against the stored transcript. |
| `find_exercise_swaps` | Server, using the same ranking as `getExerciseSwapOptionsCallable`. The phone shows the swap card. |
| `ask_follow_up_question` | Dropped. In voice the model simply asks. |
| new: `get_workout_state`, `show_move` | Phone-local and read-only. They drive the body (`MoveCue`). |

The async function calling in 3.8 means the model can keep talking while a
tool runs. The prompt tells it never to claim a plan change until the result
arrives. The server returns results with `scheduling: WHEN_IDLE`.
`publishDraftProposals` runs when the phone reports `turnComplete`, so the
"one visible card" behaviour stays.

**History.** `recordLiveTurn` writes the user's transcript and Coach's output
transcript into the same `messages` collection with `inputMode: "live_voice"`
and `liveSessionId`. It writes `status: "complete"`, never `"queued"`.
`onUserCoachMessageCreated` returns early unless the status is `queued`, so
the text brain never answers a live turn twice. History, memory and the
`dailyCoachFollowUps` job work as before.

## 4. Safety

**The guarantee changes.** Today `classifyUserMessage` and the severe-marker
screen (`severeMarkerHit` in `workouts/planAdjustments.ts`) run on the user's
words before the model sees them. With audio in, the model hears the words at
the same moment we do. That "before" guarantee cannot be kept. What can be
kept:

1. **A hard stop within about a second, from two transcripts.** On-device
   SFSpeech keeps running, and Gemini returns `inputTranscription`. Both go to
   `recordLiveTurn`, which runs `classifyUserMessage` and `severeMarkerHit` on
   each; a hit in either counts. On `blocked`, the phone stops playback, closes
   the uplink, speaks the canned `refusalForVerdict` line through today's TTS
   path, and stores a `blocked` message. The model never gets to replace it.
2. **A local tripwire.** A small Swift port of the emergency patterns ("chest
   pain", "can't breathe", "faint") cuts playback before the server answers.
   One shared fixture file is run by both the TypeScript and Swift tests. The
   server stays the authority.
3. **Plan changes stay fail-safe.** `adapt_plan` severity is decided
   server-side over the stored transcripts, never over model arguments. This
   is the same contract `toolRegistry.ts` already enforces with `rawUserText`.
4. **The prompt defers.** Pain means the model asks the red-flag questions and
   calls `adapt_plan`. It never coaches through pain, and on emergencies it
   says only "stop and get help" while the app takes over.
5. **Postflight becomes detect-and-correct.** Coach's `outputTranscription` is
   screened on the phone as it streams in, and again on the server. A hit cuts
   playback mid-sentence and the canned line follows.

**What can't be guaranteed:** the model hearing a blocked phrase; a sentence or
so of model speech before a postflight cut; and transcription errors in both
recognisers. Mitigations: two independent recognisers combined with OR; a
spoken red-flag eval set (§8, milestone 3) replayed from recorded audio before
each release; and audit events for every hard stop.

## 5. Audio on iOS with AirPods and music

- **Keep the operator's decision.** The `AudioHub` session category stays
  `.playAndRecord` with `.defaultToSpeaker`, `.duckOthers` and
  `.allowBluetoothA2DP`. Music is ducked for the whole conversation, not
  paused, AirPods stay A2DP, and the **phone mic** listens. Never add
  `.allowBluetooth` (HFP). The AirPods mic would hear better, but music would
  drop to phone-call quality.
- **Formats.** Output is 24 kHz 16-bit PCM, matching `AudioHub.voiceFormat`,
  so the existing player node and orb meter are reused. Input is 16 kHz 16-bit
  PCM: the one mic tap feeds SFSpeech and an `AVAudioConverter`, as
  `~/AgentBOB/ios/AgentBOBVoice/Sources/Services/AudioCaptureEngine.swift`
  already does.
- **Echo, by route:**
  - AirPods: Coach is in your ears and the phone mic barely hears it, so full
    duplex works.
  - Phone speaker, no music: voice processing (echo cancellation) is on, so
    full duplex works.
  - Phone speaker with music playing: echo cancellation is off today
    (`AudioHub.start`). Gemini does no echo cancellation of its own, so the
    model would hear itself and cut itself off. On this route the phone sends
    no mic audio while Coach speaks (half duplex). You can still cut in with a
    tap, a count, or "set done" through the local recogniser and the existing
    echo test.
- **Voice activity detection.** Use automatic detection with
  `startOfSpeechSensitivity: LOW` and `activityHandling:
  START_OF_ACTIVITY_INTERRUPTS` (barge-in). If music lyrics still open false
  turns, switch to manual `activityStart`/`activityEnd`, driven by the phone's
  own endpointing (§8, milestone 5).
- **Session length.** Without compression, an audio-only session is capped at
  15 min and a connection lasts about 10 min. Enable `contextWindowCompression`
  (sliding window) and `sessionResumption`. On `goAway`, mint a fresh token and
  reconnect with the handle (valid for 2 h), as `~/marin/index.html`
  (`gemResume`) already does.

## 6. Rep counting and local commands stay on the phone

The phone keeps `VoiceInputEngine` and `WorkoutVoice` exactly as they are. The
new piece is an **uplink gate**: Gemini only receives mic audio while a
conversation window is open.

- **Opens when:** you tap the orb, say "MYO …" (detected locally; a 2 s
  pre-roll ring buffer is sent so the first words aren't lost), Coach just
  asked a question (the 12 s `askedAt` window), or between sets you say
  something `handleUtterance` doesn't handle locally.
- **Closes when:** a count starts (`repCount > 0`), a local command is handled,
  or there are about 8 s of quiet after `turnComplete`.
- **Not talking over a set.** The first counted number stops model playback
  locally, where `WorkoutVoice.cutsIn` stops `CoachVoice` today. The unsaid
  part is kept as `interruptedSpeech`, so "want the rest?" still works. The
  count never reaches the model; a note after the set tells it what happened.
- **Spoken confirmations** ("Set 2 done. Rest ninety.") stay local. While one
  plays, model audio is held back.

The gate is also the main cost control (§7).

## 7. Cost (estimates)

Prices (paid tier, [pricing](https://ai.google.dev/gemini-api/docs/pricing)):

| Model | Input | Output |
|---|---|---|
| `gemini-3.8-live` | text $0.75/M tokens; audio $3.00/M tokens (listed as "or $0.005/min") | audio $12.00/M tokens ("or $0.018/min") |
| Gemini 2.5 Flash (today) | $0.30/M tokens | $2.50/M tokens |
| Chirp 3 HD speech (today) | about $30 per 1M characters (per `voice/speech.ts`) | |

Audio is 25 tokens per second. A Google staff answer (2026-07-07) confirmed
that a Live session **re-bills the whole accumulated context, audio included,
on every turn**
([forum](https://discuss.ai.google.dev/t/does-gemini-live-native-audio-bill-cumulative-prompt-tokens-on-every-turn-cost-seems-to-scale-with-turn-count-not-call-duration/173248)).
So cost grows with the number of turns, not with minutes.

**Assumptions for a 45-minute workout:** 20–30 model turns; you speak about 4 s
per turn and Coach about 7 s; an 8k-token prompt and bundle; uplink gated.

| | Per workout | Per month (30 workouts) |
|---|---|---|
| **Today** (about 15 server turns × ~12k input tokens with the tool loop, plus ~7k TTS characters) | ≈ $0.06 model + $0.21 TTS ≈ **$0.25–0.35** | **$8–10** |
| **Live, gated** (text re-billed: 20–30 × 8k ≈ $0.12–0.18; accumulated audio ≈ $0.17–0.38; output speech ≈ $0.04–0.06; local TTS lines ≈ $0.05) | **$0.40–0.70** | **$12–21** |
| **Live, mic always on** (music lyrics count as speech, context stays near the compression cap, 40–60 turns) | **$2–6** | **$60–180** |

The always-on case is why the gate exists. Compression is set low
(`triggerTokens` around 32k) so every turn has a ceiling. If the per-minute
price applies instead of per-token re-billing, even always-on would cost about
$0.30 per workout. **Measure before deciding** (§8, milestone 6).

## 8. Build plan

Every milestone ships behind the flag. Today's pipeline is not changed until
Live has been the default for two weeks.

| # | Days | What you can test on the phone |
|---|---|---|
| **1** | **1** | Hidden "Live voice (beta)" toggle on staging. The mint callable has a fixed short prompt and no tools; the phone connects, streams and plays audio. **Test:** talk with AirPods and Spotify on; interrupt Coach mid-sentence; music dips but never pauses; then try the phone speaker. |
| 2 | 2 | The real brain: server-built prompt and bundle, plus `recordLiveTurn`. **Test:** ask "what's today's workout?" and "what did I say about my shoulder?"; both sides appear in Conversation. |
| 3 | 2–3 | Safety: dual-transcript screen, phone tripwire, canned refusals, 20-phrase spoken eval. **Test:** "I've got chest pain" stops Coach within about a second with the emergency line; "my knee's a bit sore" gets triage questions. |
| 4 | 2–3 | Tools through `coachLiveTool`. **Test:** "my shoulder hurts, change today" → review card; "yes" applies it; "swap the bench" → swap card. |
| 5 | 2–3 | Workout mode: uplink gate, local counting cuts Coach off, app notes, reconnect and resumption across 45 min, manual voice detection if needed. **Test:** a full workout with AirPods and music; count over Coach; ask a form question between sets. |
| 6 | 1–2 | Caps and cost: daily live-minutes cap, usage ledger, bill check over three real workouts against §7. **Decision:** make Live the default or not. |

**Kill switch and fallback:**
- A server env flag (`IRONBOI_LIVE_VOICE_ENABLED`) makes the mint refuse. A
  per-user override exists for testing.
- The app falls back to today's SFSpeech → Firestore → TTS loop automatically,
  even mid-conversation, when it can't get a token, can't connect, fails to
  resume, or hits two socket errors in one session.
- Typed messages always use today's path.

## 9. Risks and open questions for the operator

1. **The safety guarantee weakens.** It goes from "screened before the model
   hears it" to "caught and overridden within about a second." Is that
   acceptable? If not, the relay (b) with a short audio hold-back is the only
   stronger option, and it adds latency.
2. **The billing model is unclear.** Per-turn context re-billing and the listed
   per-minute price give answers 10× apart for an always-on mic. Milestone 6
   must measure this before the gate design is final.
3. **Phone mic in a loud gym.** Lyrics and nearby voices may open false turns.
   If they do, the conversation becomes "say MYO or tap first" mid-workout.
   That is close to today, but it is a product-feel trade-off.
4. **Fresh dependencies.** `gemini-3.8-live` is four weeks old. Async tools and
   always-on proactive audio need checking on device. The docs list input
   transcription for 3.8 only in examples, so confirm it in milestone 1.
5. **Launch blockers outside this work.** App Check tokens from build 34 still
   fail validation (`docs/audits/myo-full-audit-2026-10-07.md` §2.3), and the
   mint must be App Check-protected before public use. `ironboi-prod` is
   waiting on Blaze billing.

---

**Sources.**
Models: <https://ai.google.dev/gemini-api/docs/models>, <https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live>.
Changelog: <https://ai.google.dev/gemini-api/docs/changelog>.
Ephemeral tokens: <https://ai.google.dev/gemini-api/docs/ephemeral-tokens>.
Session management: <https://ai.google.dev/gemini-api/docs/live-api/session-management>.
Capabilities (audio formats, voice detection, transcription): <https://ai.google.dev/gemini-api/docs/live-api/capabilities>.
Tools: <https://ai.google.dev/gemini-api/docs/live-api/tools>.
API reference: <https://ai.google.dev/api/live>.
Pricing: <https://ai.google.dev/gemini-api/docs/pricing>.
Firebase AI Logic Live: <https://firebase.google.com/docs/ai-logic/live-api>.
Local reference code: `~/AgentBOB/orb-lab/server/mint.ts`, `~/AgentBOB/orb-lab/src/engine/gemini-agent.ts`, `~/marin/relay.mjs` (`geminiToken`), `~/marin/index.html` (`gemSetup`, `gemResume`, `geminiEvent`), `~/marin/docs/LOG.md` (2026-09-23 resumption test, 2026-09-26 thinking-level fix), `~/AgentBOB/ios/AgentBOBVoice/Sources/Services/`.
