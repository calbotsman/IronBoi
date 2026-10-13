# MYO for any kind of training

## Context

Josh asked on 2026-10-13: what happens when someone opens MYO and says "I want to do yoga" or "I'm a runner"? Is the system smart, flexible and generative enough? It isn't today. This plan covers how to make MYO coach any training (lifting, yoga and mobility, running and cardio, sports, or a mix) without losing what makes it good: a coach that talks, remembers you and keeps you safe.

Everything under "today" was checked in the code on 2026-10-13. Sources for the science and data are linked inline.

## The short version

1. **A workout stops being "sets × reps × weight".** It becomes a list of blocks, and each block is one of six kinds: reps, hold, timed intervals, distance, flow, or free activity.
2. **A real library replaces the 74-lift list.** Exercises, poses, drills and run workouts, each with cues, muscles worked, who should avoid it, easier and harder versions, and a move for the body. It is searchable by meaning, not just by keyword.
3. **The AI designs the plan; the rules check it.** The coach writes each plan from your goals using the library, and code-level rules for safety, volume and progression accept or fix it. Today the coach never builds plans: two fixed templates do.
4. **Anything missing gets written once and kept.** A pose or drill the library doesn't have is drafted by the AI, checked, and saved for everyone.
5. **The app coaches each block its own way.** It counts reps, times holds, calls intervals, tracks a run, and walks you through a flow. The body shows the pose or the move.
6. **No model training.** It all runs on retrieval: the coach looks things up as it goes, so adding knowledge means adding data, never retraining a model.

## Today (verified)

**One shape for everything.** Every exercise in the system is `{name, sets, reps, weight}`.
- Timed work is squeezed in by putting seconds in `reps`: Plank 4×60, "HIIT Sprints (20s on/10s off)" 8×1 with the interval in the name, and Sandbag Carry 4×40 with no unit at all.
- The schema says so in a comment: "Timed holds live in `reps` as seconds" (`functions/src/contracts/tool-calls.ts:132-146`).
- Workout logs already have `durationSec` and `distanceM` fields per set, but nothing ever writes them (`workouts/activeWorkout.ts:236-245`). iOS doesn't even send session length.

**Plans come from templates, not from the coach.**
- `buildWorkoutPlanFromProfile` (`onboarding/flow.ts:616`) picks training days, builds a full-body or split week from a fixed 5-day push/pull/legs seed (`domain/ironlab-seed.json`), filters by equipment and scales loads.
- The focuses `mobility_recovery` and `endurance_conditioning` exist, but both turn into a full-body *lifting* week (`flow.ts:650-665`).
- Ask the coach for yoga and you get squats, push-ups, lunges, a 30-second plank and jumping jacks (`workouts/planAdjustments.ts:1886, 2201-2207`).
- The only place the AI touches a plan is `adapt_plan`, and its patches are sets, reps and pounds.

**The library is small and lifting-only.**
- 74 catalog entries with muscles, equipment, pattern and a load class (`workouts/exerciseCatalog.ts`). Cues and demo videos live separately, on the phone (`Models/ExerciseKnowledge.swift`).
- 19 hand-written knowledge entries, retrieved by keyword and tag scoring, not by meaning (`corpus/researchCorpus.ts:497-560`).

**Progress only understands weight.**
- Progression, baselines, the rep gate, e1RM, volume and the recap's "new best" are all about weight and reps (`workouts/exerciseBaselines.ts`, `rollover.ts`, `progress/build.ts`, `journey/recap.ts`).
- A held plank's seconds are compared as reps. Bodyweight and timed work count for nothing.

**The phone can only do reps.**
- The workout card shows "sets × reps" with a ±5 lb stepper. The coach announces a plank as "4 sets of 60". Voice counting needs three counted reps to log a set.
- Rest is 60 or 90 seconds. There's no hold timer, interval timer, GPS or pace anywhere.
- "Is this timed?" is guessed from the name (plank, jog, sprint) just to relabel a column (`WorkoutView.swift:562`).
- The backend can take in Apple Health workouts (`health/ingest.ts`), but the app has no HealthKit code.

**So:** a runner gets a lifting plan with a jog in it, and a yogi gets bodyweight squats. The foundation (a talking coach, memory, a safety screen, a body that can demonstrate) is strong. The training model under it is narrow.

## Who this is for (and the wedge)

MYO's wedge is the anxious or returning lifter the gym-bro apps lose in week two (`docs/strategy/myo-wedge-and-competitor-map.md`). Flexibility *widens the front door* for that same person; it doesn't change who they are:

| They say | What they need from MYO |
|---|---|
| "I want to do yoga" | Short guided flows they can do at home, poses shown by the body, alignment cues, and a path to more |
| "I'm a runner" | Easy and hard runs in the right mix, paced progression, intervals called out loud, the plan on their Apple Watch, plus 2 short strength days runners skip and need |
| "I want to get back into running" | A walk/run start (Couch to 5K shape), nothing that hurts, comebacks after missed weeks |
| "I play tennis twice a week" | The sport counted as training, with lifting and mobility built around it, not on top of it |
| "My back hurts, I want to move better" | Mobility first, strength slowly, and the pain screen kept front and centre |
| "I'm 62 and want to stay strong" | Balance, strength and walking, with longer holds (30–60 s), and nothing that risks a fall |
| "I'm pregnant" | Modified everything: no lying flat for long, no hot yoga, no inversions or contact; doctor clearance respected |
| "Just make me fit, I don't care how" | A mix the coach picks, and explains |

**The promise:** tell MYO what you do and what you want, in your own words, and it builds a week that fits, coaches each part properly, and gets smarter as it learns you.

## 1. The workout model: blocks, not sets

A session is a list of **sections** (warm-up, main, cool-down), and each section holds **blocks**. A block is one of:

| Kind | Example | Target | What the phone does | Logged as |
|---|---|---|---|---|
| **reps** | Goblet squat 3×10 @ 35 lb | sets, reps, load or "leave 2 in the tank" | counts reps out loud (what exists today) | reps and load per set |
| **hold** | Side plank 3×30 s each side; Warrior II 5 breaths | seconds or breaths, sets, each side | a countdown you can hear, the body holding the pose, breath cues | seconds held per set |
| **intervals** | 6 × (1 min run / 90 s walk); 8 × 20 s on / 10 s off | work and rest times or distances, repeats, intensity per step | calls "go", "walk", "last one", with a ring timer | each step done or skipped, time, effort |
| **distance** | Easy run 3 km; Long run 45 min | distance or time, pace or effort zone | GPS distance and pace, split cues, or the Watch | distance, time, pace, effort |
| **flow** | Sun salutation A × 3; 12-min mobility flow | a sequence of poses, each with breaths or seconds | steps through the poses, the body flowing between them | completed, plus how it felt |
| **free** | Tennis 60 min; climbing class | time and how hard | a timer, or it's logged after | time and effort (and METs) |

Rules of the model:
- **Every block carries an intensity in the user's language.** Load in pounds, reps in reserve ("leave 2 in the tank"), an effort scale (1–10 RPE), a pace, or a heart-rate zone if they have a Watch. One coach, one vocabulary.
- **Each side** is a property, not a name trick (this replaces the regex added today, `WorkoutVoice.isEachSide`).
- **Old plans keep working.** A sets × reps exercise is just a `reps` block. Plans are read in both shapes during migration, and a timed lift in the old shape (Plank 4×60) is converted to a `hold`.
- **It matches Apple's structure.** Apple's WorkoutKit models custom workouts as warm-up, interval blocks of work and recovery steps (each with a time, distance or open goal), then cool-down ([WWDC23](https://developer.apple.com/videos/play/wwdc2023-10016), [docs](https://developer.apple.com/documentation/workoutkit)). Our `intervals` and `distance` blocks map onto it one-to-one, so a run plan can go straight to the Watch.

Where it changes code: `PlannedExercise`/`ActiveWorkoutExercise`/`WorkoutLog` in `contracts/coach-agent.ts` and their Swift mirrors in `Models/WorkoutModels.swift`; the `adapt_plan` patch schema; `finishWorkoutSession`; the context bundle's plan rendering (`coach/contextBundle.ts:251-270`); the prompt lines that say "sets, reps and pounds" (`coach/prompt.ts:116, 142, 146`).

## 2. The library

### What an entry holds

One shared, searchable library of **movements** (exercises, poses, drills) and **sessions** (a run workout, a flow, a circuit):

- **Identity:** a canonical name, aliases ("downward dog", "down dog", "adho mukha svanasana"), and its kind (lift, pose, drill, run, sport).
- **What it trains:** muscles, movement pattern, energy system (strength, aerobic, anaerobic, mobility, balance).
- **What it needs:** equipment and space ("needs a wall", "outdoors").
- **How hard it is:** level, plus **easier and harder versions** linked to other entries. This ladder is what lets the coach meet you where you are.
- **How to do it:** setup, 2–4 cues, common mistakes, breathing.
- **Who should avoid it:** with reasons. For example, inversions with glaucoma or uncontrolled high blood pressure; long lying-flat positions in later pregnancy.
- **How it's shown:** a `MoveSpec` for the body (the format built for build 51), a pose for holds, and links to videos where licensed.
- **Where it came from:** source, license, and whether a person reviewed it.

The cues and videos now on the phone (`ExerciseKnowledge.swift`) move into the library, so the coach and the app read the same entry.

### Where the content comes from

| Source | What we take | License and what it obliges |
|---|---|---|
| [free-exercise-db](https://github.com/yuhonas/free-exercise-db) | 800+ exercises: instructions, muscles, equipment, level, about 2,600 images | **Unlicense (public domain).** No obligations. **Ingest first.** Check where the images came from before shipping them. |
| [Compendium of Physical Activities 2024](https://pacompendium.com/) | MET values for 1,000+ activities, plus older-adult and wheelchair compendia | Free for commercial use. Values must be cited and not changed or merged. Use for "free" blocks and energy estimates. |
| [Zoned](https://github.com/alarboulletmarin/zoned) | 256 structured workouts (run, bike, swim, strength), 9 plans from 5K to marathon | MIT (check the repo's license file). Keep the notice. Seed for run and interval sessions. |
| [yoga-api (alexcumplido)](https://github.com/alexcumplido/yoga-api) | Pose names (English and Sanskrit), descriptions, benefits, levels, images | MIT. Use only the CC0 images; the Flaticon sets need attribution. Thin: no alignment cues or contraindications. |
| **Written by us** (with the AI, reviewed) | Yoga alignment and who-should-avoid, flows, mobility sequences, run coaching cues, sport guidance | Ours. This is where MYO gets better than the open data, and it becomes an asset. |
| [wger](https://wger.de/api/v2/exerciseinfo/) | About 930 exercises, multilingual | **Data is CC-BY-SA:** attribution, and anything adapted from it must stay share-alike. Code is AGPL. **Only as a separate, attributed layer, or skip it.** |

**Off-limits:**
- [ExerciseDB](https://exercisedb.notion.site/ExerciseDB-API-Terms-of-Use-226983b728ca8090bf7be79564e4b356): its terms forbid storing the data.
- API Ninjas: no redistribution on the paid tier, non-commercial on the free tier.
- Any repo with no license (e.g. LunaticPrakash/yoga-api).
- The PAR-Q+ questions word for word, which are © the PAR-Q+ Collaboration and need permission.

### How it's searched

- **By meaning.** "Something for tight hips I can do at my desk" should find pigeon, figure-four and hip-flexor stretches without those words being typed. Each entry gets an embedding stored next to it; Firestore's built-in vector search keeps everything on the stack MYO already uses.
- **Filtered by hard facts first:** equipment, space, level, who-should-avoid against the user's safety notes.
- **The knowledge corpus moves to meaning-based search too.** It's the guidance the coach cites (today 19 entries, keyword-scored).

### Programming knowledge (what the rules and the coach rely on)

Written as our own paraphrases with citations, not copied text.

**Strength**
- **ACSM's 2026 position stand** ([Phillips et al., MSSE, April 2026](https://acsm.org/science-spotlight-acsm-releases-new-position-stand-on-resistance-training/)), an overview of 137 systematic reviews:
  - Train every major muscle group twice a week or more.
  - About 10+ sets per muscle per week for growth.
  - Stopping 1–2 reps short of failure works as well as going to failure.
  - Once volume and effort are equal, tempo and periodization style matter little.
  - Adherence comes first.
- **ACSM 2009** ([Ratamess et al.](https://pubmed.ncbi.nlm.nih.gov/19204579/)) for progression detail: raise load 2–10% once the target reps are beaten by 1–2 on two sessions running.

**Aerobic** ([WHO 2020](https://www.who.int/publications/i/item/9789240015128))
- 150–300 minutes a week moderate, or 75–150 vigorous, plus strength on two or more days.
- Any activity beats none.

**Flexibility** ([ACSM, Garber 2011](https://pubmed.ncbi.nlm.nih.gov/21694556/))
- Two or three days a week, daily is best.
- Static holds of 10–30 s, or 30–60 s for older adults, about 60 s total per muscle group.

**Running**
- **Start like Couch to 5K** ([NHS](https://www.nhs.uk/better-health/get-active/get-running-with-couch-to-5k/)): three runs a week, rest days between, from 1-minute run / 90-second walk up to 30 minutes continuous over 9+ weeks.
- **Limit single-run jumps, not weekly mileage.** In 5,205 runners, injury risk rose when one run was more than 10% longer than their longest run in the previous 30 days. The week-to-week ratio didn't predict injury ([Frandsen et al., BJSM 2025](https://blogs.bmj.com/bjsm/?p=11751)). So the rule MYO encodes is "no run more than ~10% longer than your longest in 30 days", not the classic 10%-a-week.
- **No "acute:chronic workload" injury warnings.** That ratio has been shown to be a statistical artifact ([Impellizzeri et al.](https://pmc.ncbi.nlm.nih.gov/articles/PMC7534938/)).
- **Mostly easy:** about 75–80% easy, 5% threshold, 15–20% hard, as a default rather than dogma ([Oliveira 2024](https://pmc.ncbi.nlm.nih.gov/articles/PMC11329428/)).

**HIIT**
- Work bouts of 15 s to 4 min, work:rest from 2:1 to 1:2, 6–10 repeats.
- Two or three sessions a week, never on back-to-back days ([ACSM guidance, summarized](https://uq.pressbooks.pub/exercisedelivery/chapter/hiit/)).

**Yoga safety**
- No inversions with glaucoma or uncontrolled high blood pressure.
- Modify deep forward folds and strong twists for osteoporosis or disc problems.
- Pregnancy ([ACOG 804](https://www.acog.org/clinical/clinical-guidance/committee-opinion/articles/2020/04/physical-activity-and-exercise-during-pregnancy-and-the-postpartum-period)): modified yoga is fine. No hot yoga, no long lying-flat or face-down positions, no inversions.
- Sequencing (warm-up, standing poses, peak, cool-down, rest) is teaching practice, not a guideline. We write it as our own rules.

**Who needs a doctor first** ([ACSM 2015 pre-participation screening](https://pubmed.ncbi.nlm.nih.gov/26473759/)): decided by three things: are they active now, do they have known heart, metabolic or kidney disease or symptoms, and how hard do they want to go. MYO's existing doctor/chest-pain screen is built on this logic, in our own words.

## 3. The planner: the AI designs, the rules check

### How a plan gets made

1. **Understand the person.** From onboarding and memory: what they do, what they want, days and time, equipment, experience per kind of training ("lifted for years, never run"), safety notes, and any event ("a 10K in March").
2. **Draft.** The coach model (the same brain as the conversation) writes a week of sessions in the block format. It uses tools: `search_library` (movements and sessions by meaning and filters), `get_guidance` (the programming knowledge above), and the person's history.
3. **Check.** Code-level rules review the draft before anyone sees it:
   - **Safety:** nothing on the person's avoid list; a doctor's limit means low intensity until cleared.
   - **Volume:** weekly sets per muscle in range; total minutes in range for their level.
   - **Recovery:** no HIIT on back-to-back days; no heavy legs the day before a long run.
   - **Progression:** no single run more than ~10% longer than their longest in 30 days; load jumps within 2–10%.
   - **Balance:** the strength/aerobic/mobility mix matches the goal; the running intensity split.
   - **Practicality:** fits the time they gave, uses their equipment.
4. **Fix or fall back.** If a rule fails, the reason goes back to the model for one repair pass. If it still fails, a safe template for that kind of training is used. Nobody is ever stuck without a plan.
5. **Explain.** The coach says why in one breath: "Three runs, mostly easy, one short faster one, and two 20-minute strength days. Runners who lift get hurt less."

**Why not let the AI decide alone, or keep templates?** Templates can't cover "tennis twice a week plus a 10K". The AI alone can overreach: too much volume, an unsafe pose, a big jump in a long run. The model drafting and code checking gets both flexibility and safety, and every rule has a citation.

### Changing the plan

The same loop handles the coach's existing plan changes (`adapt_plan`): "make Thursday a yoga day", "I've got a race in 8 weeks", "my knee hurts when I run". Today's `style_preference` path that turns "yoga" into squats goes away.

### Progression by kind

| Kind | Progresses by | Steps back when |
|---|---|---|
| reps (lifting) | load once reps are beaten (exists), or reps then load for bodyweight | reps are missed twice (exists: the rep gate) |
| hold | seconds (+5–10 s), then a harder version on the ladder | the hold is cut short twice |
| intervals | more repeats, longer work, shorter rest, in that order | steps get skipped, or effort reads "too much" |
| distance | longest run +≤10% against the last 30 days; time before pace | a missed week, pain reported, effort high |
| flow | more rounds, longer holds, then the next flow on the ladder | "too much", or a pose skipped every time |
| free | the person's own goal | n/a |

The rep-gate and rollover code (`workouts/rollover.ts`) becomes one rule set per kind instead of one weight-only path.

## 4. Filling gaps: generated entries

When a plan, a swap, or a person names something the library doesn't have ("Bulgarian bag spins", "crow pose", "a fartlek"):

1. **Draft.** The AI writes a full entry: names, kind, muscles, equipment, level, cues, who should avoid it, easier and harder versions linked to existing entries, and a `MoveSpec` so the body can show it.
2. **Check.**
   - The schema must pass.
   - The `MoveSpec` must pass its validator (`MoveSpec.isValid`: bones hold, feet on the floor).
   - "Who should avoid it" must not be empty for anything inverted, loaded overhead, or high-impact.
   - A second model pass reviews safety.
3. **Use and mark.** It's usable at once but marked *unreviewed*. The coach is a little more careful with it (it says so if asked, and it isn't used for anyone with a related safety note).
4. **Review queue.** A simple list for Josh (or a trainer later) to approve, edit or reject. The most-used unreviewed entries come first.
5. **Shared.** Once written, everyone gets it. The library grows where real people actually go.

This is the generative-moves idea from earlier (step 3 of the build-51 plan), widened from body moves to full entries.

## 5. The phone: coaching each kind of block

| Block | The coach | The body | The screen |
|---|---|---|---|
| reps | counts out loud, catches each side (done today) | does the lift with you | set, reps, load |
| hold | "30 seconds, breathe… 10 left… and rest", breath cues; you can say "done" early or "more time" | holds the pose, breathing | a draining ring |
| intervals | "Run… one minute… walk… last one!" with a tone at each change, music ducked | jogs, walks, sprints | big step name and timer, repeat count |
| distance | split cues ("1 km, 6:10 pace, nice and easy"), "halfway", "turn for home" | idle or jogging | distance, time, pace, effort zone |
| flow | names each pose, counts breaths, cues the next one ("step back to plank") | flows between poses | the pose name, what's next, a progress strip |
| free | starts and stops a timer, asks how hard it was | idle | elapsed time |

**What it takes:**
- **A timer engine** for holds, intervals and flows, driven by the same voice and cue system as counting. "Go", "rest", "pause", "skip", "more time" are handled on the phone, instantly.
- **Running:**
  - **Phase A:** push run and interval workouts to the Apple Watch with WorkoutKit (the Watch does GPS and heart rate), then read the finished run back through HealthKit.
  - **Phase B:** phone-only runs with GPS (Core Location) and the coach in your ears.
  - **HealthKit needs adding.** The backend can take in Health data already (`health/ingest.ts`), but the app has no HealthKit code or entitlement.
- **Poses for the body:** a `hold` uses a `MoveSpec` held at one key; a flow chains `MoveSpec`s. Floor poses already work (bridges, crunches, leg raises in build 51). Standing balance and inversions need new keys and a check that each still reads clearly as a soft body.
- **The workout card** grows a layout per block kind instead of "sets × reps ± 5 lb".

## 6. Onboarding and the coach

**Onboarding**
- The first question becomes "What do you like to do, or want to do?" Tap any (Lift, Run, Yoga, Mobility, A sport, Not sure yet), or say it.
- Only the follow-ups that matter are asked:
  - **runners:** how much you run now, your longest recent run, any race and its date;
  - **yoga:** how familiar you are, at home or in a class;
  - **sport:** which one, and how often.
- Everything else is learned in conversation, the same principle as the habit-journey plan.

**The coach**
- The prompt stops saying "sets, reps and pounds" and learns the block vocabulary.
- It gets `search_library` and `get_guidance` as tools in both regular and live voice.
- Its context renders a hold as "Side plank 3 × 30 s each side", not "3×30 @ 0 lb".
- It explains plans with the guidance it relied on, keeping MYO's cite-or-refuse habit.

## 7. Measurement

- **Steer by:** weeks with 2+ workouts per person (the habit-journey number), now counting any kind of training.
- **Plan quality:**
  - share of first plans accepted without edits, per kind;
  - how often the validator has to repair or fall back;
  - which rules fire most.
- **Library:**
  - searches that found nothing;
  - generated entries per week;
  - review backlog;
  - how often a generated entry gets swapped out (a sign it's bad).
- **Safety:** pain reports per 100 sessions per kind; any run progression that broke the 30-day rule (should be zero).

## 8. Build order

Each phase ships something people can use.

| Phase | What ships | Done when |
|---|---|---|
| **0. Foundations** | The block model (server and app, old plans still read); `durationSec` actually logged; the library schema with free-exercise-db and the current 74 entries migrated in; meaning-based search; the rule checker with the strength rules | Existing lifting users notice nothing. A plank is a 30-second hold, not "4 sets of 60". |
| **1. Holds, mobility and yoga** | The hold and flow blocks; the timer engine; 40–60 poses with cues and who-should-avoid (seeded from yoga-api, written by us); 10 flows; floor and standing poses on the body; "I want to do yoga" makes a real plan | Someone who says yoga gets three guided flows a week and finishes one |
| **2. The AI planner** | The coach drafts every plan in blocks with library search; rules check and repair; templates become the fallback; plan changes go through the same loop | "Tennis twice a week plus lifting" gets a sensible week without a template for it |
| **3. Running** | Intervals and distance blocks; Couch to 5K and easy/long/interval templates (seeded from Zoned); push to the Watch with WorkoutKit; HealthKit read; the 30-day single-run rule; run progression | A new runner does week 1 of a walk/run plan from their Watch, and it's logged |
| **4. Generated entries** | Draft, check, mark, review queue, shared | "Crow pose" or "fartlek" works the first time someone asks |
| **5. Sports, events, mixed** | Free blocks with METs; race-date plans (taper); phone-only GPS runs | A 10K in 8 weeks gets a plan that peaks on race day |

Phases 1 and 2 can overlap. Phase 0 comes first because everything else stands on blocks and the library.

## 9. Risks

- **Safety of generated plans and poses.** Mitigated by the rule checker, who-should-avoid filtering, unreviewed marking, the review queue, and the existing doctor screen. Pain reports are watched per kind.
- **Licensing.**
  - Ingest only public-domain, MIT or permitted sources, and keep provenance on every entry.
  - wger stays out, or in its own attributed layer.
  - Ask the PAR-Q+ Collaboration before using their wording.
- **Quality looks thin in new areas.** Yoga in the open data has no alignment or contraindications. We write that content, and that's the moat.
- **Scope.** This is months of work if done all at once. The phases keep each step shippable. Lifting stays the default experience until each new kind is good.
- **Cost and speed of AI planning.** Plans are drafted in the background (onboarding already waits a few seconds for the week). Library search and rules are cheap; one draft plus at most one repair per plan.
- **The body can't show everything.** Some poses (a headstand, a full wheel) won't read well as a soft figure. The library marks which ones show a video instead.
- **App Store and health claims.** Coaching language stays "training guidance", not medical advice. The doctor screen gates intensity.

## 10. Decisions for Josh

1. **Order:** yoga and mobility first (simplest new block, broadest appeal, fits the anxious beginner) or running first (big market, Apple Watch pull)? **Recommendation: yoga and mobility, then running.**
2. **Reviewing generated content:** Josh at first, then a trainer or physio? Or ship unreviewed with the safety rules alone?
3. **Videos:** keep YouTube links where licensed, or rely on the body plus stills? Video is the biggest licensing and cost question.
4. **Watch first for running** (WorkoutKit, quick) or phone GPS first?
5. **Scope of "any training":** which sports matter at launch (tennis, climbing, cycling, swimming, team sports)?
