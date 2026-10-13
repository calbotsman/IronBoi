# MYO habit journey plan

## Context

Josh asked: what makes MYO a habit instead of an app people try twice? This plan covers the first 10 minutes, the first workout, week 1, month 1, months 2–6 and later, plus the habit mechanics, comebacks, safety and measurement. Everything listed as "today" below was checked in the code on 2026-10-12.

## Numbers first

| Number | What it means |
|---|---|
| **3–8%** | Share of people a typical fitness app still has at day 30 ([AppsFlyer/BusinessOfApps](https://businessofapps.com/data/health-fitness-app-benchmarks), [Adjust](https://www.adjust.com/blog/what-makes-a-good-retention-rate/)). |
| **7 workouts** | Roughly where Fitbod loses people (our own `docs/strategy/myo-wedge-and-competitor-map.md`). MYO's target user, the nervous or returning lifter, is exactly who leaves here. |
| **66 days** | Median time for a new habit to feel automatic (range 18–254). **Missing one day did not hurt** (Lally 2010). |
| **4×/week for 6 weeks** | What new gym members needed before exercise became a habit (Kaushal & Rhodes 2015). For MYO's beginners we aim lower at first: 2–3 a week. |
| **+27%** | The best of 54 programs in a study of 61,000 gym members was a small reward for **coming back after a missed workout** (Milkman 2021). Comebacks are the biggest single lever. |
| **13 / 3 / 0 / 0 / 0** | MYO today: 13 required onboarding questions (3 need typing), 0 reminders, 0 words from the coach when a workout ends, 0 welcome message, 0 retention metrics. |

**One number to steer by:** *weeks with 2 or more workouts*, per person. It is simple, it forgives a missed day, and it tracks the habit rather than app opens.

---

## 1. The first ten minutes

**Today** (verified):
- Sign in with Apple, then a 13-step chat. All 13 steps are required. Age, height and weight must be typed. Each answer is one server round trip with only an hourglass for feedback (`Features/Onboarding/OnboardingView.swift`, `functions/src/onboarding/flow.ts:44-78`).
- The coach never speaks during onboarding.
- The plan review has a permanently disabled "Edit Details" button (`OnboardingView.swift:541-550`) and developer copy: "first deterministic starter plan", "clears your staging profile".
- **Bug:** the training focus the user picks is ignored. The plan builder reads `profile.trainingFocus`, but the answer is saved under `profile.preferences.trainingFocus` (`flow.ts:430` vs `:515`).
- After accepting the plan: no welcome. The first screen's copy ("I missed a few workouts", "how training's going") assumes an existing user (`CoachStageView.swift:643, 668-677`).
- A 3-day plan lands on a rest day 4 days out of 7, so the first button a new user sees is often "Rest day · train anyway?".
- Mic and speech permission prompts pop up mid-workout, after "Start my workout" (`CoachStageView.swift:1660-1667`).

**Where it should feel magical:** the coach *speaks*, uses your name, already knows your plan, and gets you moving in under 4 minutes.

**Recommendation: ask 6 things up front, learn the rest by talking.**

| Ask up front (tap only, coach reads each question aloud) | Learn later, in conversation or memory |
|---|---|
| 1. Goal | Height, weight (only if the goal involves body weight) |
| 2. Experience | Sex or gender for estimates |
| 3. Where you train / equipment | Diet constraints (nutrition isn't the wedge) |
| 4. Age band (13–17, 18–39, 40–59, 60+) | Coaching lens (Huberman, Schoenfeld…) |
| 5. **Which days and what time** (new) | Session length (default 45 min, "change any time") |
| 6. Anything that hurts, or a doctor's limit (safety screen, see §6) | Exact age, training focus (coach recommends) |

- **Why "which days and what time":** naming *when and where* you'll act roughly doubles follow-through. In a meta-analysis of 94 studies the effect size was d≈0.65 (Gollwitzer & Sheeran 2006). Today `preferredDays` is always empty (`flow.ts:423`). This one answer gives us the plan days, the reminder time and the cue.
- **Voice vs typed:** the coach speaks, the user taps. New users are often in public and nervous, and they haven't granted mic access yet. Voice *input* becomes the default from the first workout on.
- **Mic permission:** ask with a one-line explanation at the end of onboarding ("I count your reps by listening"), never mid-set.

**Target timeline**

| Time | What happens |
|---|---|
| 0:00 | Open app, Sign in with Apple |
| 0:30 | Coach greets out loud, 6 tap questions |
| 2:30 | Plan appears: "Here's your week. Tap a day to change it." Accept |
| 3:00 | Coach, by name: "Your first session is today: 20 minutes, 4 moves, light on purpose. Start now, or at 6pm?" |
| 3:30 | First workout starts (mic permission asked just before) |

## 2. The first workout (the moment that has to land)

**Today:** the workout itself is strong: spoken intros, rep counting, rest timer, demos, swaps (`CoachStageView.swift:1627-1873`). But when it ends, `workoutEnded()` (`:1716-1733`) either asks "keep these changes?" or **just turns the mic off without a word**. There's no recap, no "how did that feel", no "see you Thursday".

**Recommendation:**
- **Day 1 always has a session.** If you haven't done a workout yet, the button says "Start your first session" even on a rest day. It's a *starter* version: 3–4 moves, 2 sets each, easy weights.
- **Light on purpose.** The coach says it: "Today we find your numbers. Leave 2–3 reps in the tank." How good a workout *feels* predicts whether people come back (Rhodes & Kates 2015), and so does enjoying it in the moment (Woolley & Fishbach 2017). Finishing a bit fresh beats being crushed.
- **What "done" feels like** is a spoken recap of 3 lines plus a card:
  1. What you did, with real numbers: "4 moves, 8 sets, 86 reps, 22 minutes."
  2. One specific thing the coach noticed: "Your goblet squat got smoother by set 2."
  3. What's next: "Next one is Thursday at 6. I'll give you a nudge."
  4. Then one question: **How did that feel? Easy / About right / Too much.** It feeds `perceivedEffort`, which already exists on workout logs.
- The recap is built from logged data, not invented by the model, so it can't overclaim progress. This matches the rule in `docs/plans/myo-progress-tracking-plan.md`.
- The existing "keep the new weight?" card (`WeightFollowUpCard`) follows, framed as "Now I know your starting weights."

## 3. The journey over time

| Stage | Job for the person | What the coach notices and says | How progress is felt | How the plan changes |
|---|---|---|---|---|
| **Day 1** | Finish one session, feel good | Welcome by name, starter session, recap | "You did it: 86 reps" | Starting weights set from what you actually lifted (exists: `baselineSuggestions`) |
| **Week 1** (sessions 2–3) | Come back for #2 within 7 days | Next day: "Sore? That's normal for 1–3 days. Here's why." Reminder at your chosen time. One "missed it?" note the morning after a miss | Recap after every session. "2 of 3 this week" | None. Keep it steady and easy |
| **Month 1** (sessions 4–12) | Get past workout 7 | First "you're lifting X more than week 1" (from logged weights). Week-start message: "New week. Here's what's changed and why" (rollover is silent today). Week-4 check-in: "Is Tue/Thu/Sat still working?" | Weekly count ("weeks with 2+": 4 of 4). First personal bests called out in the recap | Weight goes up only when earned (exists: `gateProgression`, `rollover.ts:270-368`). Days and times adjusted from the check-in |
| **Months 2–3** (habit forms around day 66) | Training becomes automatic | Fewer nudges. Ties the session to your routine ("after work"). Month-3 letter: totals, best lifts, "what I've learned about you" | Month recap. Strength trend on the main screen, not buried in History | New variations every 4–6 weeks so it doesn't go stale. Existing deload after 2 missed weeks |
| **Months 4–6** | Keep it, own it | Asks for the next goal: "You've hit 3×/week for 3 months. Want to chase a number?" | 6-month story: first session vs now | Goal refresh leads to a new plan block |
| **6+ months** | It's part of who they are | The relationship *is* the product: memory, history, a coach that knows your knee | Yearly highlights | Seasonal blocks, travel and holiday versions |

## 4. Habit mechanics (what we use and why)

| Piece | What MYO does | Evidence |
|---|---|---|
| **Cue** | The reminder fires at the day and time *you* picked, on training days only. Max 1 per day, none on rest days, quiet hours respected, one-tap off | Implementation intentions (Gollwitzer & Sheeran 2006) |
| **Fade the reminders** | As your "weeks with 2+" builds, reminders shift from "time to train" to "you've got this one". Turn them down after about 8 weeks of consistency, and the coach suggests anchoring to a routine instead | Reminders help repetition but can become a crutch; cues tied to an existing routine build automaticity (Stawarz, Cox & Blandford 2015) |
| **Easy start** | Tapping the reminder opens straight to "Start". Always offer a short version: "Only 20 minutes? Here's the short one." | Lower friction means more starts |
| **Reward now** | Spoken recap, specific praise, effort question, personal bests | Immediate rewards predict persistence (Woolley & Fishbach 2017) |
| **Progress you can see** | One line under the orb ("Week 3 · 2 of 3 done") and monthly recaps | Tracking progress helps people reach goals, more so when it's recorded or reported (Harkin 2016, meta-analysis of 138 studies) |
| **Investment** | The coach remembers. The You tab shows "what I know about you", which you can edit | The relationship and memory are the moat in the wedge doc |
| **Consistency, not streaks** | Count **weeks with 2+ workouts**, not days in a row. Injury, illness and travel weeks are *paused*, not broken. Never threaten a loss | Broken streaks reduce future effort unless they can be repaired (Silverman & Barasch 2023). One miss doesn't hurt the habit (Lally 2010) |
| **Fresh starts** | Comebacks are offered on Mondays, the 1st of the month, after holidays | Fresh-start effect (Dai, Milkman & Riis 2014) |
| **Feeling capable and choosing** | The coach explains why, offers choices, and never makes you feel stupid | Self-determination theory review: autonomy and competence predict long-term exercise (Teixeira 2012) |

**What to avoid:**
- Daily streak counters with fire emojis
- "Don't lose your streak!"
- Guilt copy ("You're letting yourself down")
- Fake urgency
- More than 1 nudge a day
- "Your coach misses you 😢"
- Confirm-shaming on the reminders-off switch ("No, I don't care about my health")
- Leaderboards (they scare our target user)
- Weight-loss praise that rewards unsafe pace
- Health details on the lock screen

## 5. Lapses and comebacks

**Today:** a graded return ramp exists (`adapt_plan` with `returning_from_layoff`, `planAdjustments.ts:285-356`). But the coach is **told never to bring up a gap** (`prompt.ts:127`) and never calculates days since your last workout. So a comeback feels exactly like any other day.

**Recommendation:** the server calculates the gap and hands the coach a small `<journey>` note (workouts done, days since last, week number, weeks with 2+, next planned session). The coach can then *offer a ramp once*. It never pushes one.

| Situation | What the person gets |
|---|---|
| **Missed 1 session** | Next morning, once: "Yesterday slipped by. Want the 20-minute version today, or pick up Thursday?" (Milkman 2021: the return after a miss is where the biggest gain is) |
| **Lost week (7–13 days)** | On next open: "Welcome back. A week off is nothing. Today's a bit lighter." Ramp offered once ([70,100]). No guilt |
| **2–4 weeks** | One reminder at day 14, one at day 30, on a Monday or the 1st. Then **silence** until they return (we say so in onboarding) |
| **3+ months** | "Good to see you, {name}. Last time we were working on your squat and that left knee." Ramp [50,65,80,100]. Re-ask days and time. Memory is the magic here |
| **Injury** | Existing triage. The weekly count is *paused*. The existing injury re-check follow-up becomes a reminder (today it only appears if they happen to open the app) |
| **Travel** | "On the road?" switches to a hotel or bodyweight version via the existing swap tool. The week is paused |
| **Still sick, or postpartum** | No ramp. Clinician-first message (exists: `prompt.ts:131`) |

## 6. Safety and trust

- **The coach is not a doctor.** Add a short readiness screen inside onboarding question 6, based on PAR-Q+: "Has a doctor told you to limit exercise? Do you get chest pain, dizziness or fainting when active?" If yes: a conservative plan, a "check with your doctor first" message, and a remembered safety fact. Today there's no readiness check or disclaimer in onboarding.
- **Existing guards to keep:** emergency words blocked (`safety.ts:20`), severe-symptom screen on plan changes, pain over 2 weeks means see a clinician, under-18 kept conservative (`flow.ts:707`), age 13+ checked.
- **Overtraining:** weight only goes up when earned (exists). Add two checks: two "too much" ratings in a row holds progression, and a third day in a row trains the short version.
- **No health claims:** no "burn X calories", "fixes back pain" or "medical-grade". Progress claims must trace to logged numbers.
- **Fix before inviting outside users** (from `docs/audits/myo-full-audit-2026-10-07.md`, uncommitted in the main checkout):
  - The P0 injury-path eval fails intermittently (6 of 9 nights).
  - The privacy policy doesn't yet mention Gemini Live sending audio to Google.

## 7. Measurement (private by design)

There's no analytics SDK, and the policy says "no cross-app tracking". Keep it that way. **Compute everything on the server from data we already store.**

| Metric | Definition | Launch target |
|---|---|---|
| **Activation** | Finished workout #1 within 48h of sign-up | 60% |
| **Second workout** | Did workout #2 within 7 days of #1 | 50% |
| **Week-4 retention** | Did a workout in week 4 | 25% (category ~3–8% at day 30) |
| **Week-12 retention** | Did a workout in week 12 | 15% |
| **Weeks with 2+** | Average per active user | ≥ 70% of weeks |
| **Comeback rate** | Lapsed 14+ days, then trained again within 30 days | 20% |
| Guardrails | Reminder opt-out rate, account deletion rate, injury-adjustment rate | Watch, don't optimize |

**How:**
- Store two server timestamps: `onboardingCompletedAt` and `firstWorkoutAt`.
- A daily scheduled function reads `workoutLogs` (`serverRecordedAt`) and `profile/current` (`createdAt`).
- It writes **counts only, no user IDs**, to `ops_metrics/{date}`, and logs them through `safeLogger` using allowlisted keys.
- Add one line to the privacy policy under "How we use your data": "We count, in aggregate, how many people complete workouts so we can tell if MYO works."
- Local reminders send nothing off the phone. Real push notifications (later) would add a device token, which is a policy update.

Today n≈1. Get 5–10 TestFlight testers who match the nervous or returning persona before trusting any rate.

## 8. Gap list (ranked by impact on habit)

| # | Gap | Exists today | Effort |
|---|---|---|---|
| 1 | **No reminders at all** | Nothing (no notification code anywhere) | S: local notifications on iOS only |
| 2 | **Workout ends in silence** | Only "keep changes?" or mic off (`CoachStageView.swift:1716`) | S: recap built on the server plus effort chips |
| 3 | **No welcome; day 1 may be a rest day** | No first message; "train anyway?" | S |
| 4 | **Onboarding: 13 steps, 3 typed, dev copy, dead Edit button, focus bug** | `flow.ts`, `OnboardingView.swift` | M (the focus bug alone is S) |
| 5 | **Coach blind to gaps; comebacks feel like any day** | Ramp only when asked; prompt forbids inferring a layoff | S–M: `<journey>` context note plus a prompt rule |
| 6 | **No metrics** | Data exists; nothing counts it | S |
| 7 | **Progress hidden in Profile → History; no personal-best callouts** | `RecordView.swift`, `progress/build.ts` | M |
| 8 | **Week rollover is silent; no weekly recap** | `weeklyProgramRollover` | S–M |
| 9 | **Weekly count can't pause** | `streakWeeks` exists | S |
| 10 | **Mic prompt pops mid-workout** | Lazy request in `VoiceInputEngine.swift:187` | S |
| 11 | **Injury re-check only seen if the app is opened** | `dailyCoachFollowUps` writes chat only | S once #1 exists |
| 12 | **Safety: no readiness screen; flaky P0 eval; policy drift** | See §6 | M |
| 13 | **Memory invisible to the user** | You-tab concept docs exist | M–L |

## 9. Build phases

### Phase 1: "First day lands" (≈3–4 days, feel it on device)

1. **Welcome.** When the plan is accepted, the server writes a first coach message to the `general` session. It uses your name, says "first session today, light on purpose", and the phone speaks it. Change `acceptProgramProposal` in `functions/src/onboarding/flow.ts` and reuse the existing message-writing pattern from `followups/sweep.ts`.
2. **Starter session on day 1.** If no workout has been completed yet, show "Start your first session" even on a rest day, trimmed to 3–4 moves × 2 sets. Add an option to `startWorkoutSession` (`functions/src/workouts/activeWorkout.ts:53`); the button state lives in `CoachStageView.swift:720-724, 872-885`.
3. **End-of-workout recap.**
   - `finishWorkoutSession` (`activeWorkout.ts:176`) builds a 3-line recap from the logged sets, comparing against the last time each lift was done, and writes it as a coach message.
   - `workoutEnded()` speaks it, then shows Easy / About right / Too much chips, which save to `perceivedEffort`.
   - The existing changes card and weight card follow.
4. **Local reminders.**
   - After the first recap, ask "When do you usually want to train?" (days plus time), and ask for notification permission at that moment.
   - Schedule `UNUserNotificationCenter` reminders on training days, plus one "missed it?" note the next morning.
   - Add a toggle and a time picker in `PreferencesView.swift`. The lock-screen text is generic.
   - Store the choice in `profile.schedule.preferredDays` and add a preferred time.
5. **Small fixes:**
   - Training-focus bug (`flow.ts:515`, and the same read in `index.ts:263`)
   - Remove the dev copy
   - Mic permission pre-prompt before the first workout
   - Rewrite the first-screen quick taps for brand-new users
6. **Metrics v0:** the `onboardingCompletedAt` and `firstWorkoutAt` timestamps, plus the daily counts function.

### Phase 2: "Short start, smart comebacks" (≈1–2 weeks)
- Onboarding cut to 6 tap questions, read aloud by the coach. Days and time asked up front. Readiness screen. An Edit button that works.
- `<journey>` context note in `contextBundle.ts` (workouts done, days since last, week number, weeks with 2+). The prompt rule changes from "never infer a layoff" to "offer a ramp once when the gap is 10+ days".
- The comeback ladder from §5, including the 14- and 30-day reminders, then silence.
- A weekly start message when the week rolls over. Personal bests in the recap.
- Weekly consistency count with "paused" weeks.

### Phase 3: "Progress you can feel" (≈2–3 weeks)
- Weekly progress line on the main screen. Month-1, month-3 and month-6 recap "letters".
- Reminders fade as consistency builds. Injury re-check delivered as a reminder.
- You tab: "what I know about you", editable.
- Overtraining checks from §6.

### Before outside users (in parallel, not habit work)
- Fix the P0 injury eval.
- Update the privacy policy for Gemini Live audio and the metrics line.

## Verification (per phase)

- **Phase 1 on device or simulator:**
  1. Fresh dev account: onboarding, welcome spoken, starter session on any day, finish, spoken recap, effort chips.
  2. Reminder permission asked after the recap. A debug "fire reminder in 10s" proves delivery.
  3. Confirm the pending reminders match the chosen days.
  4. *(Per your rule, I'll ask before any simulator run that talks or takes over the screen.)*
- **Server:** unit tests for the recap builder, the starter trim, the focus fix, and the metrics counts (no user IDs in output). Run with `npm test` in `functions/`. Deploy to `ironboi-staging` only.
- **Done means:** Josh does the day-1 flow on his phone and the end of the first workout *feels* like something happened.

## Sources

- Lally et al. (2010), *European Journal of Social Psychology*: habit formation, median 66 days. [UCL summary](https://www.ucl.ac.uk/news/2009/aug/how-long-does-it-take-form-habit)
- Kaushal & Rhodes (2015), *Journal of Behavioral Medicine*: exercise habit formation in new gym members. [UVic](https://dspace.library.uvic.ca/items/113699e5-2131-4f46-8ec6-2180cffed8c3)
- Milkman et al. (2021), *Nature*: "Megastudies improve the impact of applied behavioural science". [Wharton](https://bcfg.wharton.upenn.edu/?p=2660)
- Silverman & Barasch (2023), *Journal of Consumer Research*: "On or Off Track: How (Broken) Streaks Affect Consumer Decisions". [CU Boulder](https://www.colorado.edu/business/faculty-research/2023/04/19/or-track-how-broken-streaks-affect-consumer-decisions)
- Rhodes & Kates (2015), *Annals of Behavioral Medicine* 49:715–731: affective response to exercise predicts future activity
- Gollwitzer & Sheeran (2006), *Advances in Experimental Social Psychology* 38: implementation intentions meta-analysis
- Harkin et al. (2016), *Psychological Bulletin* 142(2): monitoring goal progress
- Woolley & Fishbach (2017), *Personality and Social Psychology Bulletin*: immediate rewards predict adherence
- Stawarz, Cox & Blandford (2015), CHI: smartphone apps, reminders and habit formation
- Dai, Milkman & Riis (2014), *Management Science*: the fresh start effect
- Teixeira et al. (2012), *IJBNPA*: exercise and self-determination theory review
- Warburton et al. (2011): PAR-Q+ readiness questionnaire
- Retention benchmarks: [BusinessOfApps](https://businessofapps.com/data/health-fitness-app-benchmarks), [Adjust](https://www.adjust.com/blog/what-makes-a-good-retention-rate/)
