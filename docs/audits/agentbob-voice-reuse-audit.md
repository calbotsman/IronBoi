# AgentBOB Voice Reuse Audit for MYO

**Date:** 2026-05-11  
**Source reviewed:** `/Users/joshualong/AgentBOB/ios/AgentBOBVoice` and `/Users/joshualong/AgentBOB/voice-pwa/server/live-relay.cjs`  
**Target:** MYO iOS coach onboarding/chat voice input.

---

## What AgentBOB Built

AgentBOB has a real voice-first stack:

- iOS microphone capture via `AVAudioEngine`
- local speech transcription via `SFSpeechRecognizer`
- WebSocket client with reconnect/heartbeat handling
- Node relay on port `3001`
- Gemini Live native-audio session
- streamed PCM audio playback
- input and output transcription
- app-level events such as `relay_ready`, `turn_complete`, `usage`, and cards

Important files:

- `/Users/joshualong/AgentBOB/ios/AgentBOBVoice/Sources/Services/AudioCaptureEngine.swift`
- `/Users/joshualong/AgentBOB/ios/AgentBOBVoice/Sources/Services/AudioPlaybackEngine.swift`
- `/Users/joshualong/AgentBOB/ios/AgentBOBVoice/Sources/Services/RelayLiveClient.swift`
- `/Users/joshualong/AgentBOB/ios/AgentBOBVoice/Sources/ViewModels/VoiceConsoleModel.swift`
- `/Users/joshualong/AgentBOB/voice-pwa/server/live-relay.cjs`

---

## What We Should Reuse Now

### Reuse: local speech-to-text pattern

The best immediate reuse is the local iOS transcription pattern:

- request microphone permission
- request speech recognition permission
- capture microphone buffers
- feed buffers into `SFSpeechAudioBufferRecognitionRequest`
- stream partial transcript into the UI
- send final text through the existing secure coach message path

This is now implemented in MYO as:

- `/Users/joshualong/IronBoi/ios/IronBoi/IronBoi/Services/VoiceInputEngine.swift`
- `/Users/joshualong/IronBoi/ios/IronBoi/IronBoi/Features/Coach/CoachView.swift`

This gives MYO a voice-vs-chat path without changing backend security. The backend still receives normal authenticated coach messages.

---

## What We Should Not Reuse Yet

### Do not bring over Gemini Live relay yet

AgentBOB's full relay is strong, but it is the wrong first move for MYO onboarding.

Reasons:

- MYO already has Firebase Auth, Firestore isolation, and HTTP coach message flow.
- Onboarding needs structured extraction into profile/plan/calorie goals first.
- Live audio introduces WebSocket auth, reconnect, heartbeat, audio playback, model routing, and cost-control complexity.
- The Gemini Live stack is tuned around AgentBOB/Lynn and vintage-audio cards, not fitness onboarding.

Bring it over later only after:

1. onboarding profile extraction works
2. weekly plan proposals work
3. calorie target proposals work
4. safety evals cover nutrition and exercise-plan generation
5. voice messages store `inputMode: "voice"`
6. user can review/edit extracted facts

---

## Future Voice Architecture

Recommended staging:

### Voice v1: Dictation Into Chat

Current implementation:

```text
Mic button → local iOS speech recognition → transcript in composer → send as normal coach message
```

Benefits:

- low backend risk
- no new model provider
- no voice token/audio cost
- uses existing Firebase Auth and per-user isolation
- works for onboarding immediately

### Voice v2: Voice Metadata

Add `inputMode: "voice" | "text"` to coach messages so onboarding extraction can understand the input surface.

### Voice v3: Spoken Replies

Add optional text-to-speech for coach replies. This can use native iOS TTS first, before streaming model audio.

### Voice v4: Live Coach

Only after the product loop is stable, adapt AgentBOB's relay pattern:

```text
iOS audio capture → MYO voice relay → Gemini Live/OpenAI Realtime → transcribed coach turn → structured profile/plan tools
```

At that point we need:

- Firebase ID token on WebSocket handshake
- per-user session path scoping
- App Check / App Attest
- daily audio/token caps
- PHI-safe relay logs
- turn-level transcript persistence
- fallback to text if live audio fails

---

## Key AgentBOB Lessons To Keep

- Keep audio session setup conservative. Simulator audio can crash if input route is missing.
- Never let the UI depend only on audio playback; always display transcript/text.
- Use a clear `phase` state: idle, listening, processing, speaking, error.
- For live relay later, send an explicit `turn_complete` event instead of letting upstream close semantics freeze the client.
- Add heartbeats only after the WebSocket handshake is delivered.
- Keep local speech transcription even in live mode; it is useful for UI feedback and recovery.

