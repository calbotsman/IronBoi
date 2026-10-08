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
> TALK TO IT
> • One screen: tap the coach and talk. It listens, answers out loud, and you can talk over it. Type when you can't talk.
> • Ask for today's workout and run it by voice: count your reps and the set is logged; say a new weight and it sticks.
> • Plan: this week, day by day; swap exercises and adjust weights
> • History: your sessions, strength trends and body-weight trend
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

Not collected: location, contacts, photos, HealthKit (none yet), audio. Speech recognition is Apple's (on-device when the phone supports it, otherwise Apple's servers); audio never reaches our backend and we never store it. The text of spoken replies goes to Google Cloud Text-to-Speech — declare Google as a processor alongside OpenRouter, same as the policy §11.

## Screenshots (6.9" required — 1320×2868 or 1290×2796)

The Coach screen was rebuilt around the voice orb on 2026-10-05, so every shot is retaken from the current build:
1. **Coach** — the orb mid-reply with a sentence subtitle. Caption: "Just talk to it."
2. **Coach, live workout** — the expanded set list with counted reps. Caption: "Count your reps. It logs the set."
3. **Coach** — a session reworked for a short day (proposal card). Caption: "Short on time? It adapts."
4. **You → What Coach remembers.** Caption: "It remembers what you tell it."
5. **History** — strength trend. Caption: "See the work add up."

Capture from the simulator (iPhone 17 Pro Max) with a seeded account, not the debug preview session (it shows a "Preview" sign-in path).
