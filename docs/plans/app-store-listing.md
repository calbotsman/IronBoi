---
title: MYO — App Store listing (draft)
date: 2026-10-05
status: draft — needs Josh's pass (and a studio copy pass if wanted) before it goes into App Store Connect
---

# App Store listing — draft

Voice follows the copy kit in `myo-high-fidelity-build-plan.md` Part 3: calm, direct, no gym-bro. The app is `MYO`, the entity is `Coach`. No streaks, no badges, no medical claims (App Review 1.4.1).

## Name (30 max)

`MYO Coach` (9)

## Subtitle (30 max)

`Lifting plans that explain why` (30)

Alternates: `Calm, honest strength coaching` (30) · `A coach that remembers you` (26)

## Promotional text (170 max — editable without review)

> A strength coach you can talk to. MYO writes your program, explains the why behind it, remembers what you tell it, and adjusts when life gets in the way.

(153)

## Description (4000 max)

> MYO is a strength coach you talk to.
>
> Tell it your goals, the equipment you have, how many days you can train and anything that hurts. It writes a multi-week program, walks you through each session, and changes the plan when your week does.
>
> **It explains the why.** Ask why you're doing an exercise, or whether some soreness is normal, and Coach answers in plain language, citing the research it's drawing on. When it doesn't know, it says so.
>
> **It remembers you.** Mention a sore shoulder, a hotel gym or a physio's advice, and Coach keeps it in mind for next week. You can see everything it remembers, and remove anything, under You.
>
> **It adapts with you.** Only 25 minutes on Friday? Squat rack taken? Tell Coach and it reworks the session, with real numbers.
>
> **It gets stronger with you.** Weights step up week to week when you hit your reps, hold when you don't, and back off when you need it.
>
> **It's calm about pain.** If something hurts, Coach asks the questions a good coach would ask first. If anything sounds serious, it stops and tells you to see a clinician.
>
> FOUR TABS
> • Coach: chat, with voice input
> • Train: this week's plan, day by day; swap exercises and adjust weights
> • Record: your sessions, strength trends and body-weight trend
> • You: your goals, equipment, limits, and what Coach remembers
>
> MYO is for anyone who lifts, and especially for people who are new, coming back after a break, or tired of apps that feel like they were built for someone else.
>
> MYO gives general fitness coaching and is not medical advice. Talk to a doctor before starting a new program, especially if you have an injury or health condition.

## Keywords (100 max, comma-separated, no spaces after commas)

`strength,lifting,workout planner,gym,weightlifting,personal trainer,AI coach,program,beginner`

(93) — don't repeat words already in the name/subtitle (Apple indexes those separately).

## What's New (first public version)

> The first public release of MYO.

## Category

Primary: **Health & Fitness**. Secondary: none.

## Age rating

Answer the questionnaire honestly. Expected result: **12+** or **17+** depending on the "Medical/Treatment Information" answer (the coach discusses pain and injury but doesn't diagnose). Pick "Infrequent/Mild".

## App Privacy answers (must match `legal/privacy-policy.md`)

Data linked to the user, used for App Functionality only, not used for tracking:
- **Contact Info → Name, Email** (Sign in with Apple, if shared)
- **Identifiers → User ID**
- **Health & Fitness → Fitness** (workouts, body weight entered by hand)
- **User Content → Other User Content** (coach chat, remembered facts)
- **Usage Data → Product Interaction** (message counts for daily caps)

Not collected: location, contacts, photos, HealthKit (none yet), audio (speech-to-text is on-device).

## Screenshots (6.9" required — 1320×2868 or 1290×2796)

A full set from the 2026-10-09 build is in `docs/app-store/screenshots/2026-10-09/` (iPhone 17 Pro Max simulator, 1320×2868, preview session with seeded data): 01 coach reply, 02 live workout with the rest timer (02b expanded set list), 03 plan-change card, 04 memory, 05 history. Retake after the icon lands and after any Coach-screen change. The original plan:
1. **Coach** — a reply with the citation line visible. Caption: "Ask why. Get a real answer."
2. **Train** — this week's plan. Caption: "A program built around your week."
3. **Coach** — a session reworked for a short day. Caption: "Short on time? It adapts."
4. **You → What Coach remembers.** Caption: "It remembers what you tell it."
5. **Record** — strength trend. Caption: "See the work add up."

Capture from the simulator (iPhone 17 Pro Max) with a seeded account, not the debug preview session (it shows a "Preview" sign-in path).
