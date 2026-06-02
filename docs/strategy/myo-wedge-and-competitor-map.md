---
title: MYO — Wedge, Competitor Map, and Positioning
date: 2026-06-02
author: Tosh (with Claude)
status: draft for review
---

# MYO: Where We Win

## The one-sentence wedge

**MYO is the AI coach for the person the gym-bro apps lose in week two** — the anxious-to-returning lifter who needs a coach that explains the *why*, remembers *them*, and never makes them feel stupid. We reach feature parity with the workout generators, then beat them on the one thing they've all ignored: the experience of being coached by something that feels human, safe, and trustworthy.

The category is full of *workout vending machines*. MYO is a *coach*. That gap is the wedge.

---

## Why this wedge is real (not wishful)

Three facts from the market do the arguing for us:

**1. The category loses people fast, and it's not a motivation problem.** ~70% of fitness-app users churn within 90 days, and the consistent diagnosis is UX, not willpower. Fitbod specifically "struggles to retain users beyond the first seven workouts." The incumbents are tuned for the already-confident lifter who needs a barbell calculator — not for the person who's nervous, returning after a layoff, or unsure whether their knee pain is normal. **That person is the largest, least-served, highest-churn segment in the category.** They're also exactly who you described: anxious-to-returning.

**2. The apps feel generic, and users say so.** Fitbod's own reviews complain the algorithm "feels generic before it learns" and that workouts "feel random rather than personalized." These are pre-generated plans, not conversations. They can't answer "why am I doing this?" or "I'm sore here, is that okay?" MYO can — and can cite a real source when it does.

**3. They all look and sound the same.** You're right about the branding. The whole category defaults to dark-mode-plus-neon-accent, "channel energy through bright contrast," macho-aesthetic sameness (Fitbod, FitnessAI, Freeletics all live here). It's designed to look hardcore. For an anxious beginner, hardcore reads as *intimidating*. Nobody in the AI-coach tier is building for calm, clarity, and warmth. That's an open lane.

So the wedge isn't one bet — it's three reinforcing gaps the incumbents have left wide open: **the early-journey user, the explanatory conversation, and the welcoming aesthetic.** MYO's existing architecture (conversational LLM coach, persistent memory, evidence corpus with cite-or-refuse, safety-first voice) maps onto all three almost perfectly. We're not pivoting to chase this — we're already built for it.

---

## The competitor map

I focused on the AI-coach-first tier, since that's MYO's actual fight. I've sorted them by *what kind of thing they are*, because that's what reveals the gaps.

| App | What it really is | Coaching model | Price (2026) | Strength | The gap MYO exploits |
|---|---|---|---|---|---|
| **Fitbod** | Workout generator | Algorithm pre-builds each session; learns from edits, not conversation | $15.99/mo, $95.99/yr | Recovery-aware muscle targeting, big exercise library | Not conversational; "feels generic"; loses users by workout #7; no *why* |
| **FitnessAI** | Strength optimizer | Algorithm sets weights/reps from large workout dataset | ~$15/mo (varies) | Data-driven progressive overload | Strength-only, no mobility/cardio; no dialogue; no explanation |
| **Freeletics** | Bodyweight AI coach | Generates plan, you rate difficulty, it adapts; strong community | $34.99/mo, $99.99/yr | HIIT/calisthenics, 4K demos, social feed | Rate-a-number adaptation, not conversation; HIIT-leaning; pricey monthly |
| **Caliber** | Human coaching marketplace | Real certified coaches via chat | ~$50–300+/mo (Pro from $19) | Genuine human accountability | Expensive; not instant; doesn't scale; not for the budget/anxious entrant |
| **SensAI** | Recovery-data LLM coach | LLM layer over Whoop/Oura/Garmin/Watch signals | subscription | Multi-signal recovery decisions | Data-nerd framing; assumes wearables; not beginner-warm |
| **Welling / MacroFactor** | Nutrition-first AI | Conversational/weekly AI for food & macros | subscription | Nutrition logging & reviews | Nutrition lane, not strength coaching |
| **Stanford Bloom (Beebo)** | Research LLM coach | Chat-based plan proposal + calendaring | research | Validates the conversational-coach thesis (CHI 2026 best paper) | Not a shipping product — proof the direction is right |

**Read the table top to bottom and the gap jumps out:** the cheap, scalable tier (Fitbod, FitnessAI, Freeletics) is *algorithmic and impersonal*. The personal tier (Caliber) is *human and expensive*. The new LLM-conversational coaches (SensAI, Welling, Bloom) are either nutrition-focused, wearable-dependent, or not yet products. **Nobody owns "scalable + personal + warm + trustworthy + strength-focused" for the anxious-to-returning user.** That's the box MYO sits in alone.

---

## Parity first: what we must match to be taken seriously

Before we can dunk, we can't look amateur. These are table stakes — the things every serious app in this tier has, and whose absence would disqualify us regardless of how good the coaching is. Treat this as a checklist, not a roadmap; most of it is UI surface over the backend you've already hardened.

- **Exercise library with clean video demos** (multi-angle is the bar Freeletics/Fitbod set). Non-negotiable for an anxious user who doesn't know the movement.
- **Fast, frictionless workout logging** — sets, reps, weight, with the "start your first workout in <60s" onboarding standard.
- **Plan generation** — a real program, not just chat. The coach has to *produce structure*, then talk about it.
- **Progressive overload / smart weight suggestions** — the core promise of the category.
- **Equipment + location awareness** (home/gym, what's available).
- **Apple Health + Apple Watch sync** — expected on iOS, and feeds your health-context bundle.
- **Recovery awareness** — even lightweight (last session, soreness, sleep if available).

None of this is where we win. It's the price of admission. Ship it competently, then stop polishing it.

---

## The dunk: where the experience beats them

This is the half that matters, and it's where MYO's architecture is already a weapon. Each of these is something the incumbents *structurally cannot* easily copy, because their products aren't built as conversations.

**1. A coach that explains the why — and is right.** The evidence corpus with cite-or-refuse is the single most defensible thing you have. Every other AI app either stays silent on the "why" or risks confident bro-science. MYO can answer "should I train through this soreness?" with a grounded, cited answer — or honestly refuse when it doesn't know. For an anxious user, *trustworthy* beats *confident* every time. **Lead with this.**

**2. A coach that remembers you.** Persistent memory + the proposal queue means MYO accumulates a real relationship: your history, your bad knee, your goal, your preferences — surfaced appropriately, never creepily. Fitbod "learns your edits." MYO *knows you*. That's a categorically different feeling, and it compounds over time into a switching moat.

**3. Calm around pain, shame, and confusion.** Your coach-voice doc already nails this: "direct, not macho… calm around risk, pain, shame, or confusion… personal, not fake-intimate." This *is* the anxious-user wedge encoded as a personality. No competitor has a documented stance on not making people feel bad. Make this visible in the product, not just the system prompt.

**4. Conversational, in real time.** Not "generate a plan and rate it 1–5." A back-and-forth. "I only have 30 minutes and the squat rack is taken" → MYO adapts on the spot and tells you why. That's the human-coach feeling at algorithmic price — the exact middle Caliber and Fitbod leave empty.

**5. A brand that welcomes instead of intimidates.** This is your branding wedge, and it's wide open. Reject the dark-neon-hardcore default. Go warm, clear, human, confident-but-calm — an aesthetic that signals *this is a safe place to be a beginner.* Strava channels energy; Headspace channels calm. **MYO should channel calm competence.** That single design decision is differentiation a competitor can't ship without abandoning their entire macho identity.

---

## How to say it (positioning lines to test)

- *"The coach that explains why."*
- *"Strength training without the gym-bro."*
- *"It remembers you. It explains everything. It never makes you feel stupid."*
- *"A real coach in your pocket — calm, smart, and honest about what it doesn't know."*

The throughline: **competence without intimidation, intelligence without bullshit.**

---

## What this means for the next phase

You came in wanting to step back and plan. Here's the strategic read:

**Don't out-feature Fitbod. Out-*experience* them.** The phase plan you've already executed (trust boundaries, evidence corpus, memory queue, safety) is — whether you framed it this way or not — *the wedge being built in code*. The risk isn't that the backend is wrong. The risk is shipping that backend behind a generic UI and a hardcore brand, which would bury your one real advantage.

Three concrete priorities, in order:

1. **Make the wedge visible.** The cite-or-refuse, the memory, the calm voice — these are invisible if the UI is just another workout logger. Design the surface *around* the conversation and the trust, not around the exercise grid.
2. **Hit parity fast and cheaply.** Library, logging, plan gen, Watch sync, overload. Competent, not beloved. Don't sink months here.
3. **Commit to the welcoming brand.** This is a one-time identity decision that pays off forever and that no incumbent can follow you into. Get it right before you have a logo and color system to unwind.

The anxious-to-returning user is real, large, badly served, and a perfect fit for what you've already built. The competitors handed you the lane. Take it.

---

## Open questions to resolve

1. **Nutrition: in or out of v1?** Welling/MacroFactor own the nutrition-AI lane. Coaching the lift is the wedge; food is a distraction unless it's a deliberate later expansion.
2. **Wearables: required or optional?** SensAI bets on Whoop/Oura. Requiring wearables shrinks the anxious-beginner market. Recommend: enhance with Watch data, never depend on it.
3. **Free tier shape?** Fitbod/Freeletics paywall everything and get dinged for it. A genuinely useful free experience could be an acquisition wedge for the price-sensitive entrant.
4. **What's the one screen that sells the wedge?** Pick the single moment (probably a coach conversation answering a real anxious-user question, with a citation) that becomes the App Store hero shot and the demo.

---

*Sources: competitor research is footnoted in the chat thread that produced this doc (Fitbod, FitnessAI, Freeletics, Caliber, SensAI, Welling/MacroFactor, Stanford Bloom). Pricing and feature claims reflect 2026 public reviews and may shift; re-verify before any external use.*
