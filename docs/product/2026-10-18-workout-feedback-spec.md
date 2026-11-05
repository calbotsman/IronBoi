# Workout feedback — decisions (2026-10-18)

Josh's feedback after a live session, with his answers to follow-up questions.

1. **Voice speed** — make live (streaming) voice mode the default.
2. **Transcription** — "set done" came through as "parents come, said done". Make command matching tolerant of mishears; bias the recogniser toward workout vocabulary.
3. **Warm-up + cooldown** — both, built from the day's moves, voice-guided with timers.
4. **Rush** — coach leads with "If you only do one, do X", then offers the rest.
5. **Preview** — write it as "3 sets of 10" (and "3 sets of 30 s" for holds).
6. **Background** — keep coach + timers running when locked or in another app; lock-screen rest countdown (Live Activity).
7. **Post-set advice** — only when useful, never repeated; sometimes ask a question ("how'd that feel?") and let the answer adjust the next set.
8. **Rest UI** — switch to a rest mode: countdown, next up, one tip. Minimal look and feel.
9. **Exercise transitions** — close out the prior move: encouragement, "that's done", stretch X/Y/Z for soreness, then next up.
10. **Can't do a set** — coach asks what's wrong (too heavy / something hurts), then adapts: drop weight, swap, or skip.
11. **Timed holds** — start the timer automatically.
12. **Rest timing** — per exercise + effort; "give me 2 minutes" adjusts it.
13. **Behaviour tuning** — "stop telling me that" / "that's helpful" remembered forever, visible and removable in the memory screen.
14. **60 s vs 60 lb** — fix parsing so durations are never read as weights.
15. **Personal intelligence persists** — injuries, adjustments, tone dislikes, "say it this way" are stored server-side as memory facts and fed to every coach (regular + live) every session. Never start fresh.
16. **Gemini vs OpenAI voice** — a way to A/B the two voice stacks (live mode on each) on device.
17. **Change the coach's voice by asking** — "can you change your voice to a woman's", "deeper", "British"; remembered.
18. **Human feel** — breaths/inhales before lines, natural pauses, small fillers; the moves that make it feel uncannily human.

## What shipped (branch claude/feedback-review-questions-b9872f)

| # | Where |
|---|---|
| 1 | `LiveVoiceSession.enabled` defaults on; Preferences toggle reads "Live voice". Server live is only on in staging (`IRONBOI_LIVE_VOICE_ENABLED`); elsewhere it falls back to the regular coach. |
| 2 | `WorkoutVoice.heardAsSetDone` ("parents come, said done" → set done); more workout words for the recogniser. |
| 3, 4 | `WorkoutCoaching.warmup/cooldown` (muscle-ranked, priority ordered); `GuidedRoutine` in `CoachStageView` times each move, each side. Cooldown leads with "If you're in a rush, the one thing to do is…", then offers the rest. |
| 5 | "3 sets of 10" on the Today and live cards. |
| 6 | Rest timed against the clock; `RestWidget` Live Activity (lock screen + Dynamic Island); a time-sensitive "Rest's over" notification as a backstop; mic resumes after calls/Siri/returning. |
| 7 | `SetAdvisor`: never repeats, shortfall always said, a "how did that feel?" once per lift whose answer moves the weight or the rest. |
| 8 | `TimerPanel`: countdown, next up, one tip, Skip / +30s. |
| 9 | `WorkoutCoaching.closeOut` before "Next up". |
| 10 | "I can't do this" → asks too heavy / hurts / done → lighter (or fewer reps), stop + swap + safety memory, or drop remaining sets. |
| 11 | Holds count down 3-2-1 and start by themselves after the intro or the rest. |
| 12 | Rest by lift type and effort (2:00 heavy compound, 1:30 compound, 1:00 small); "give me two minutes", "add a minute". |
| 13, 15 | "Stop telling me that" / "that's helpful" → confirmed memory facts (`coach-tune-*`), read back into the advisor each workout and by every coach; voice-mode prompt rules make memory standing orders. |
| 14 | Seconds/minutes never parse as pounds; on a hold a bare number is time. |
| 16 | Preferences → Voice engine: Gemini / OpenAI (`gpt-realtime`, `liveOpenAI.ts`). Staging only (`IRONBOI_LIVE_OPENAI_ENABLED`). |
| 17 | "Change your voice to a woman's", "sound calmer", "deeper" → switches on the spot, remembered. Accents: not available yet, says so. |
| 18 | Procedural inhale before real sentences, varied gaps; prompt asks for natural beats and no repeated sentences. |

Not verified on a device: everything audio (breathing level, background behaviour, Live Activity, OpenAI session). Needs a phone run.
