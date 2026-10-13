# MYO for any kind of training

## Context

Josh asked on 2026-10-13: what happens when someone opens MYO and says "I want to do yoga" or "I'm a runner"? Is the system smart, flexible and generative enough? It isn't today. This plan covers how MYO grows past lifting without losing what makes it good: a coach that talks, remembers you and keeps you safe.

Everything under "today" was checked in the code on 2026-10-13.

**Revision 2 (same day), after an adversarial review.** Four independent critics attacked the first draft: engineering, safety and liability, product strategy, and licensing. Their main findings were verified in the code and at the sources. The biggest changes:
1. **Sequencing.** Fix voice first and prove lifting retention, behind two gates, before any big rebuild.
2. **Data.** The "public domain" exercise database turned out to contain scraped text and images, so we take facts only and write our own words.
3. **Safety.** Today's doctor screen is a keyword match, not a real screen; it gets fixed now.
4. **Generated content.** Nothing the AI writes is shared or shown on the body until a qualified person reviews it.

Section 11 lists every change.

## The short version

1. **Not yet: fix the floor first.** Voice reliability, counting and reply speed are still open. No retention data on lifting exists. Expansion waits behind two gates (§8).
2. **Now, small and safe:**
   - a real **hold** (timed) block, so a plank stops being "4 sets of 60";
   - session time actually logged;
   - a proper **safety screen** (today's is one question and a keyword match);
   - the coach saying honestly what it doesn't coach yet;
   - a **"what do you like to do?"** question that measures demand before we build.
3. **Next, if lifting retains: mobility inside lifting plans.** Warm-ups, cool-downs, "my back is tight today". It's the same wedge user, needs no new onboarding branch, and we can measure whether it lifts lifting retention.
4. **Then the AI planner,** for lifting and mobility only. It's checked by code-level rules and judged against a fixed test set before it replaces templates.
5. **Then running or yoga, whichever real users ask for.** If running: strength for runners first (read their runs from Apple Health, plan strength around them), then Couch to 5K on the phone's timer (no GPS needed).
6. **The model underneath:** a workout becomes a list of **blocks**: reps, hold, intervals, distance, flow, free. It's introduced gradually, with old app builds still working.
7. **The library:** facts from open sources (names, muscles, equipment, levels); every word of instruction written by us; no third-party images. The body, our own renders, is the visual.
8. **No model training.** The coach looks things up as it goes. Adding knowledge means adding data.

## Today (verified)

**One shape for everything.** Every exercise is `{name, sets, reps, weight}`.
- Timed work is squeezed in by putting seconds in `reps`: Plank 4×60, "HIIT Sprints (20s on/10s off)" 8×1 with the interval in the name, and Sandbag Carry 4×40 with no unit. The schema says so: "Timed holds live in `reps` as seconds" (`functions/src/contracts/tool-calls.ts:132-146`).
- Per-set `durationSec`/`distanceM` exist on workout logs (`contracts/coach-agent.ts:329-330`) but are never written.
- Session `durationSec` is written by the server (`workouts/activeWorkout.ts:248`) but is always empty, because iOS doesn't send it (`AppModel.swift:1115-1120`). The recap works the time out from `startedAt` instead.

**Plans come from templates, not the coach.**
- `buildWorkoutPlanFromProfile` (`onboarding/flow.ts:616`) builds a full-body or split week from a fixed push/pull/legs seed (`domain/ironlab-seed.json`), filters by equipment, and scales loads. It's deterministic and takes milliseconds.
- `mobility_recovery` and `endurance_conditioning` both become a lifting week (`flow.ts:650-665`).
- Ask for yoga and you get squats, push-ups, lunges, a 30-second plank and jumping jacks (`workouts/planAdjustments.ts:1886, 2201-2207`).
- The AI only touches plans through `adapt_plan`, in sets, reps and pounds.

**The library is small and lifting-only.**
- 74 catalog entries (`workouts/exerciseCatalog.ts`), with cues and videos kept separately on the phone (`Models/ExerciseKnowledge.swift`).
- 18 hand-written knowledge entries, retrieved by keyword and tag scoring (`corpus/researchCorpus.ts:497-560`).

**Identity is the name.** Baselines, history and swaps are keyed by `normalizeExerciseKey(name)` (`workouts/exerciseBaselines.ts:90, 201`). Renaming or merging exercises breaks a user's starting weights and progression state.

**Progress only understands weight.**
- Progression, baselines, the rep gate (`workouts/rollover.ts`), e1RM and volume (`progress/build.ts`), and the recap's "new best" are weight-and-reps only.
- A plank's 60 seconds is logged as 60 reps, which already pollutes volume history.

**The phone can only do reps.**
- The card shows "sets × reps" with a ±5 lb stepper. A plank is announced as "4 sets of 60".
- Rest is 60 or 90 seconds. There's no hold timer, interval timer, GPS or pace.
- Old app builds drop any exercise without `sets` and `reps`: `makePlannedExercise` returns nil (`AppModel.swift:2129-2141`). Server schemas are `.strict()`, so unknown fields are rejected.
- Background audio is the only background mode (`Info.plist`). There's no HealthKit code or entitlement, though the backend can take in Health data (`health/ingest.ts`).

**The safety screen is thin.**
- Onboarding asks one free-text question ("does anything hurt, or has a doctor told you to limit exercise?") and flags clearance with a keyword match: `doctor|physician|cardiolog|chest pain|dizz|faint|pass out|heart` (`onboarding/flow.ts:74, 1099`).
- "Type 2 diabetes" or "kidney disease" don't trigger it, while "my heart isn't in it" does.
- It never asks how active someone is now, about known heart, metabolic or kidney disease, or how hard they want to train: the three things the ACSM screening model uses.

**So:** a runner gets a lifting plan with a jog in it, a yogi gets bodyweight squats, and the safety screen can miss real conditions. The foundation (a talking coach, memory, a body that demonstrates) is strong. The training model and the screen under it are narrow.

## Who this is for (and the wedge)

MYO's wedge is the anxious or returning lifter the gym-bro apps lose in week two (`docs/strategy/myo-wedge-and-competitor-map.md`). The positioning stays **"strength without the gym-bro"**. Mobility and runs come in as *supporting* work, not as a pivot to "a coach for everything". Competing head-on with Down Dog, Fitness+, Peloton (whose AI is moving into flexibility) or Strava with Runna is the losing game. Where a conversational coach wins is fitting other training *around* the person's strength work, and explaining why.

| They say | What MYO does (eventually) |
|---|---|
| "My back is tight, I want to move better" | Mobility blocks in their lifting days; pain means stop and refer, never diagnose |
| "I run, and I know I should lift" | Reads their runs from Apple Health, counts them in the week, plans two short strength days around them |
| "I want to get back into running" | A Couch to 5K walk/run start on the phone's timer, at the pace the plan sets |
| "I play tennis twice a week" | The sport counted as training, with strength and mobility around it |
| "I'm 62 and want to stay strong" | Strength, walking, and **balance work 3+ days a week** (supported by a chair or wall, then progressed), as WHO recommends to prevent falls |
| "I'm pregnant" | Clearance and contraindications screened; modified everything; stop signs wired into the session |
| "I want to do yoga" | Until yoga is built: an honest answer and mobility now. After Gate 2: guided flows |

## 1. The workout model: blocks

A session is **sections** (warm-up, main, cool-down) of **blocks**. Each block is one of:

| Kind | Example | Target | Logged as |
|---|---|---|---|
| **reps** | Goblet squat 3×10 @ 35 lb | sets, reps, load or reps in reserve | reps and load per set |
| **hold** | Side plank 3×30 s each side | seconds or breaths, sets, each side | seconds held per set |
| **intervals** | 6 × (1 min run / 90 s walk) | work and rest steps, repeats, effort per step | each step done or skipped, effort |
| **distance** | Easy run 3 km or 30 min | distance or time, effort (pace only for experienced runners) | distance, time, pace, effort |
| **flow** | 12-minute mobility flow | a sequence of poses with breaths or seconds | completed, how it felt |
| **free** | Tennis 60 min | time and effort | time, effort |

- **Intensity in the user's language:** pounds or kg, reps in reserve ("leave 2 in the tank"), effort 1–10, pace in min/km or min/mile. Units follow the user's setting (today it's pounds everywhere, `contextBundle.ts:250`).
- **Each side** becomes a property (it replaces today's name regex, `WorkoutVoice.isEachSide`).
- **Matches Apple's structure.** WorkoutKit custom workouts are warm-up, interval blocks of work and recovery steps (time, distance or open goals), then cool-down ([docs](https://developer.apple.com/documentation/workoutkit)). Intervals and distance blocks map onto it later.

### Migration, done safely

This is the critical path, and the biggest single job.
- **Dual-write.** For as long as old builds are in use, plans keep the legacy `sets/reps/weight` fields *alongside* blocks. An old build still shows a plank (as "4×60"); a new build shows a hold.
- **`schemaVersion`** on every plan, a **minimum app build** check, and a **feature flag per user and per kind**. Today's flags are environment-wide, like `IRONBOI_LIVE_VOICE_ENABLED`. Rollback means "drop the blocks, keep the legacy fields".
- **Stable exercise IDs.** Add `exerciseId` to catalog entries, plans, logs and baselines. A backfill maps today's names to IDs; name lookup stays as a fallback. Without this, a library with aliases resets people's starting weights.
- **Converting timed lifts** uses the catalog's own fields (each entry gets `kind: hold`), not name guessing.
- **The full scope:**
  - `PlannedExercise`/`ActiveWorkoutExercise`/`WorkoutLog` (`contracts/coach-agent.ts`) and the Swift mirrors (`Models/WorkoutModels.swift`, `WorkoutLogModels.swift`);
  - `trainingPrograms` weeks and the rollover that rewrites them;
  - `exerciseSwap.ts`, `program.ts`, `adapt_plan` and its validator (`tool-calls.ts:122-151`);
  - `finishWorkoutSession`;
  - Firestore rules (`onlyKeys` and the schema drift test, `firestore.rules:75-95`), noting that clients write `workoutLogs` directly, so old-shape logs keep arriving;
  - the context bundle and the prompt lines that say "sets, reps and pounds" (`coach/prompt.ts:116, 142, 146`);
  - `progress/build.ts` (exclude hold seconds from volume and e1RM, and clean the polluted history);
  - the recap;
  - the 618 security tests.

## 2. The library

### What an entry holds

- **Identity:** an `exerciseId`, a canonical name, aliases (English and Sanskrit), and its kind (lift, pose, drill, run session, sport).
- **What it trains:** muscles, pattern, energy system.
- **What it needs:** equipment and space.
- **How hard it is:** level, plus easier and harder versions linked by ID.
- **How to do it:** setup, cues, common mistakes, breathing. **Every word written by us.**
- **Safety properties, as checkable fields, not prose:** loaded, inverted, head below heart, impact, end-range spinal flexion or twist, breath-hold strain, fall risk. Plus written "who should avoid it".
- **How it's shown:** a `MoveSpec` for the body, or text only. No third-party images.
- **Provenance:** source of each fact, license, author, review status, version.

### Where the content comes from (verified at the source)

| Source | What we may take | Notes |
|---|---|---|
| [free-exercise-db](https://github.com/yuhonas/free-exercise-db) | **Facts only:** exercise names, muscles, equipment, level, mechanic | The repo is Unlicense, but its images and instructions were scraped. The upstream project says they were "scrapped off the internet" and advises against commercial use ([wrkout CONTRIBUTING](https://github.com/wrkout/exercises.json/blob/master/CONTRIBUTING.md)). Users have matched the images to ExRx and Bodybuilding.com ([#13](https://github.com/yuhonas/free-exercise-db/issues/13), [wrkout#305](https://github.com/wrkout/exercises.json/issues/305)), and the sample instruction is word-for-word Bodybuilding.com. **No images, no text, and the text never goes into a prompt.** |
| [Compendium of Physical Activities](https://pacompendium.com/) | MET values (adult, older adult, wheelchair), from the website | Free for commercial use. Cite it; don't change or merge values. Not from the paper (CC BY-NC-ND), and not the Youth compendium. MET values are for internal effort accounting only, never shown as "calories burned" (see the habit plan's rules). |
| [Zoned](https://github.com/alarboulletmarin/zoned) | Endurance workout and plan **structures** (about 250 templates) | MIT for its own content; keep the notice. **Not** its exercise images (copied from free-exercise-db). |
| [yoga-api](https://github.com/alexcumplido/yoga-api) | **Pose names only** (English and Sanskrit) | The MIT license covers code. The data is credited to unlicensed repos and partly matches Yoga Journal's copy. Images are Flaticon or Noun Project (attribution) or unknown origin. Write everything else ourselves. |
| [NHS website](https://www.nhs.uk/our-policies/terms-and-conditions/) | Couch to 5K structure; exercise guidance | Open Government Licence; commercial use OK. Adaptations need an "as at" date or refreshing. No logos or third-party images. |
| [CDC / HHS](https://www.cdc.gov/other/agencymaterials.html), [NIA](https://newsinhealth.nih.gov/2014/12/go4life) | Physical activity guidelines, older-adult exercise material | US government works (public domain); NIA asks for credit. Never imply endorsement; check images one by one. |
| **Written by us**, reviewed by a qualified person | All instructions, cues, alignment, who-should-avoid, flows, run coaching | This is MYO's moat. The AI drafts **without any copyrighted source text in front of it**; a CSCS, physio or registered yoga teacher reviews safety-relevant entries. |
| [wger](https://wger.de/api/v2/exerciseinfo/) | Optional: its 21 CC0 exercises; otherwise skip | Most records are CC-BY-SA 3.0/4.0 with per-record authors, so adapted text must stay share-alike. The code is AGPL. Not worth the obligations. |

**Off-limits:**
- [ExerciseDB](https://exercisedb.notion.site/ExerciseDB-API-Terms-of-Use-226983b728ca8090bf7be79564e4b356) (storing is prohibited).
- [API Ninjas](https://api-ninjas.com/terms) (no permanent library from it on any tier).
- wrkout/exercises.json images, and anything compiled from it or from wger under a looser label (e.g. exercemus).
- Yoga Journal-derived text.
- Repos with no license.
- The **PAR-Q+** wording (© PAR-Q+ Collaboration, all rights reserved; ask before using it).
- **YouTube:** links out are fine. Embeds only via the official player, unmodified, never cached, and never inside a paid gate.

### Search

- **No vector database at this size.** For 1–2k entries, use hard filters (kind, equipment, level, safety properties against the person's notes), then an alias table, then either in-memory similarity (embeddings loaded at cold start, about 3 MB) or the model choosing from the filtered shortlist.
- Firestore vector search (`findNearest`) works on this project, but it adds an embedding pipeline, separate indexes and emulator questions. Revisit past about 10k entries.
- The knowledge corpus (18 entries today) gets the same approach.

### Programming knowledge (our paraphrases, with citations)

**Strength**
- **[ACSM 2026 position stand](https://acsm.org/science-spotlight-acsm-releases-new-position-stand-on-resistance-training/)** (healthy adults; an overview of 137 systematic reviews):
  - Train all major muscle groups twice a week or more.
  - About 10+ sets per muscle per week *optimizes* growth, but **any** resistance training is the headline benefit, so the checker never requires 10 sets of a beginner.
  - Stopping 1–2 reps short of failure works as well as going to failure.
- **[ACSM 2009](https://pubmed.ncbi.nlm.nih.gov/19204579/)** for progression: raise load 2–10% once the person beats the target by 1–2 reps. (The "two sessions in a row" version is NSCA's 2-for-2 rule; we use that as our own conservative choice.)

**Aerobic** ([WHO 2020](https://www.who.int/publications/i/item/9789240015128))
- 150–300 min/week moderate, or 75–150 vigorous, plus strength on two or more days.
- For older adults: balance and strength on 3+ days a week, to prevent falls.

**Flexibility** ([Garber 2011](https://pubmed.ncbi.nlm.nih.gov/21694556/))
- Two or three days a week, ideally daily.
- Static holds of 10–30 s (30–60 s for older adults), about 60 s total per muscle group.

**Running**
- **Beginners (under 8 weeks of running): a Couch to 5K progression** ([NHS](https://www.nhs.uk/better-health/get-active/get-running-with-couch-to-5k/)). Three sessions a week with rest days between, from 1-minute run / 90-second walk up to 30 minutes.
- **Once there's 30 days of history:** cap any single run below 10% longer than the longest in the last 30 days. Evidence: [Frandsen et al. 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC12421110) (5,205 runners, median 9.5 years' running, observational, self-reported injuries; the authors suggest a cutoff below 10%).
- **No acute:chronic workload warnings.** The link to injury may be a statistical artifact ([Impellizzeri et al.](https://pmc.ncbi.nlm.nih.gov/articles/PMC7534938/)).
- **Intensity:** beginners run nearly everything easy. For experienced runners only, the option of a polarized mix (about 75–80% easy, under 10% threshold, the rest hard). Its benefit over other mixes is small and mostly on VO2peak ([Oliveira 2024](https://pmc.ncbi.nlm.nih.gov/articles/PMC11329428/)).

**HIIT**
- Work bouts of 15 s to 4 min at 80–95% of max heart rate.
- Two or three sessions a week, never on back-to-back days.
- **Not for** inactive people, anyone flagged for clearance, pregnant users, or anyone 60+ until they've done 4+ weeks of moderate training. (HIIT is vigorous exercise, which triggers clearance under ACSM.)

**Yoga and mobility safety, as filters on the safety properties**
- **Glaucoma:** no *head-below-heart* poses (downward dog raised eye pressure most in [Jasien 2015](https://doaj.org/article/5a338a993f6c45419a6b1cf1359c3f54); also standing folds, plough, legs-up-the-wall).
- **Osteoporosis:** no end-range or loaded spinal flexion, and no flexion-plus-twist (spinal flexion poses were linked to vertebral fractures in [Sinaki 2013](https://newsnetwork.mayoclinic.org/discussion/people-with-osteoporosis-should-avoid-certain-spinal-poses-in-yoga-mayo-clinic-study-says)).
- **High blood pressure:** ask whether it's controlled. If unknown or uncontrolled: no head-below-heart, no breath-hold strain.
- **Pregnancy** ([ACOG 804](https://www.acog.org/clinical/clinical-guidance/committee-opinion/articles/2020/04/physical-activity-and-exercise-during-pregnancy-and-the-postpartum-period)):
  - Screen ACOG's absolute contraindications (for example placenta previa after 26 weeks, preeclampsia, cerclage). Any yes means no plan until cleared.
  - Avoid prolonged lying flat after the first trimester, positions that drop blood pressure, fall risk, and hot yoga.
  - **In-session stop signs:** bleeding, dizziness, calf pain or swelling, fluid leakage, regular contractions. Saying any of these stops the session and refers them on.
  - Ask the trimester again over time.

### The safety screen (replaces today's keyword match)

Built on the [ACSM 2015](https://pubmed.ncbi.nlm.nih.gov/26473759/) model, in our own words, with the wording reviewed by a clinician (or PAR-Q+ licensed):
- **Asked:** current activity; known heart, metabolic or kidney disease; symptoms (chest pain, unusual breathlessness, dizziness or fainting, and others); the intensity they want.
- **Symptoms:** no plan until cleared.
- **Known disease and inactive:** clearance first.
- **Known disease and active:** moderate only until cleared.
- **Also screened:**
  - **Age:** under 18 is blocked or gets a separate youth path; under 13 is never allowed (COPPA).
  - **Pregnancy or postpartum:** trimester, contraindications, pelvic floor and abdominal separation.
  - **Recent surgery or joint replacement:** for example, hip precautions rule out pigeon pose.
  - **Falls (STEADI-style):** fallen in the past year, feeling unsteady, worried about falling.
  - **Medications that change the rules:** beta-blockers (heart-rate zones are wrong), blood thinners (fall stakes), insulin (low blood sugar).
  - **Disordered eating or compulsive exercise:** volume capped, no streak pressure.
- **Asked again** when anything changes and periodically. Pain means stop and refer, never diagnose.

## 3. The planner: the AI drafts, the rules check

1. **Instant first.** The template plan appears right away, as today. That keeps the speed and gives a fallback that always exists.
2. **The AI drafts in the background,** using structured output (a response schema, not freeform tool JSON). Tools: `search_library` and `get_guidance`. The output limit is raised for plans: today's 2,048 tokens (`coach/modelProvider.ts:145`) is already tight for seven days of sets and reps.
3. **The rules check it:**
   - **Safety:** the person's screen against entry safety properties.
   - **Volume:** ranges by level.
   - **Recovery:** no HIIT on back-to-back days; no heavy legs before a long run.
   - **Progression:** the rules above.
   - **Balance:** the mix of training kinds matches the goal.
   - **Practicality:** fits their time and equipment.
4. **The checker fixes mechanical problems itself:** trims volume, moves a day, swaps in an easier version. Only problems of meaning go back to the AI, for one repair. If it still fails, the template stays.
5. **Swap in only if it passes,** with the coach explaining the plan in one breath. No unsubstantiated claims: "runners who lift get hurt less" is out unless we can cite it.
6. **A kind is only drafted once its template and history source exist.** For example, running waits until run templates exist and run history is read from Apple Health.

**How we know it's good: an evaluation set.** 30–50 fixed person descriptions (the table above and harder ones) × several runs, scored by the rule checker plus an AI judge, with spot checks by a qualified person. Recorded replays run in CI. The AI planner replaces templates only when:
- zero rule violations remain after repair;
- the repair rate is under 20%;
- fallback happens under 5% of the time;
- 95% of plans finish drafting in under about 8 seconds (in the background).

Plan changes (`adapt_plan`) go through the same loop. The `style_preference` path that turns "yoga" into squats is replaced by an honest answer until a kind is built.

**Progression by kind:**

| Kind | Progresses by | Steps back when |
|---|---|---|
| reps | load once reps are beaten (exists) | reps missed twice (exists) |
| hold | seconds, then a harder version | the hold is cut short twice |
| intervals | more repeats, then longer work, then shorter rest | steps skipped, or effort reads "too much" |
| distance | beginners: the next Couch to 5K step; experienced: the single-run rule | a missed week, pain, high effort |
| flow | more rounds, longer holds, the next flow | "too much", or a pose always skipped |

## 4. Generated entries: private until reviewed

When something the library doesn't have is requested ("crow pose", "a fartlek"):

1. **Find before writing.** Check aliases and similarity against existing entries, so "crow", "bakasana" and "crow pose" don't become three entries.
2. **Draft.** Facts, our own wording, safety properties, linked easier and harder versions, and a `MoveSpec` draft. No copyrighted text in the prompt.
3. **Classify by checked properties.**
   - **Low risk:** no load, no inversion or head below heart, no impact, no end-range spinal flexion or twist.
   - **High risk:** arm balances, inversions, jumping and other plyometrics, Olympic lifts.
4. **Gate:**
   - Low-risk unreviewed entries can be used **only by the person who asked**, as **text only, with no body demo**, and never for anyone pregnant, 60+, under 18, flagged for clearance, or with a related safety note.
   - High-risk entries are blocked until reviewed.
5. **Never shared before review.** Unreviewed text never enters another user's coach prompt. (Otherwise one user's words, "crow pose, ignore prior rules…", would reach everyone: stored prompt injection.)
6. **Reviewed by a qualified person** (CSCS, physio, or registered yoga teacher), not by a second AI pass. Then shared, with a body demo if its `MoveSpec` passes.
7. **Versioned and recallable.** A rejected entry is removed from every plan, and affected users are told.
8. **Rate-limited per user;** anonymous users can't trigger it.

## 5. The phone

| Block | The coach | The body | The screen |
|---|---|---|---|
| hold | "30 seconds, breathe… 10 left… rest"; "done" or "more time" by voice | holds the pose (reviewed entries only) | a draining ring |
| intervals | "Run… walk… last one!" with tones; music ducked | jogs or walks | step name, timer, repeat count |
| distance | split cues; effort check-ins | idle or jogging | distance, time, effort |
| flow | names each pose, counts breaths, cues the next | flows between poses | pose, next pose, progress |
| free | starts and stops a timer, asks how hard | idle | elapsed time |

- **Timer engine.** Runs on the phone and owns all cue audio: tones and short phrases. **Live voice is ducked during block changes**, so timer cues and the live coach never talk over each other. No library searches during live voice: its tools are fixed when the session token is minted (`coach/liveSession.ts`).
- **Locked screen.** Timers keep working only while the audio session is active (the background-audio mode exists). No silent-audio tricks, which risk App Review. Testing on device with the screen locked is part of done.
- **Running:**
  - **First:** Couch to 5K as intervals on the phone timer. No GPS, no Watch.
  - **Then:** read runs and workouts from Apple Health (needs the HealthKit entitlement, usage text, consent and the App Store disclosures).
  - **Then:** WorkoutKit to the Watch, as an extra for people with a Watch (watchOS 10+).
  - **Phone GPS last:** background location mode, review justification, battery testing.
- **In-session stop words:** "chest pain", "dizzy", "stop" end any interval or run block and refer the person on. Pregnancy stop signs too.
- **Accessibility:** VoiceOver announcements and haptics at every timer change.
- **Offline:** the library is cached on the phone, and the timer engine works with no signal.
- **The workout card** gets a layout per block kind.

## 6. Onboarding and the coach

- **One added question:** "What do you like to do?" with tap chips: Lift, Run, Yoga, Mobility, A sport, Not sure. No per-kind follow-up questions up front; the rest is learned in conversation, keeping the 6-question onboarding the habit plan just shipped. Until a kind is built, a tap is logged (demand data), and the coach says what it can do now: "I'll build your strength plan with mobility in it. Running plans are coming."
- **The coach:**
  - learns the block vocabulary;
  - renders holds as "Side plank 3 × 30 s each side";
  - gets `search_library` and `get_guidance` (regular voice only, not live);
  - keeps cite-or-refuse;
  - **never diagnoses** pain: stop and refer.

## 7. Measurement

**Guardrails that must not get worse while any of this ships:**
- **Voice:** miscounted sets per 100, the delay before a tick is heard, transcription accuracy on counts (from the voice log).
- **Safety:** pain reports per 100 sessions.

**Demand:** "What do you like to do?" taps, and non-lifting requests in chat, per 100 users.

**Retention, per kind:** activation, workout #2, still training at week 4. Plus whether mobility blocks raise lifting completion. The habit number (weeks with 2+ workouts) is reported **per kind**, so easy 10-minute sessions can't inflate it or hide whether lifting retains.

**Plan quality:**
- first-week swaps and abandons, per kind (not "accepted without edits": anxious users don't edit, they leave);
- the AI planner's repair and fallback rates against the evaluation set.

**Safety:**
- a check-in after sessions about pain lasting more than 48 hours, with a follow-up two days later;
- "why did you stop?" for people who drop off;
- every safety number **reported separately** for pregnant, 60+, clearance-flagged, and generated-entry exposures;
- every pain report linked to the plan that produced it (AI draft, repaired draft, or template).

**Instrumentation:** an event pipeline (today the metrics exist in `journey/metrics.ts` but there's no general event stream) and a per-user cost cap on AI planning calls.

## 8. Build order, with gates

| Step | What | Done when |
|---|---|---|
| **Now (about 4 weeks)** | Voice reliability, counting and reply speed (in progress: the new recogniser, the voice log). **The safety screen (§2).** A minimal `hold` block with dual-write and `durationSec` logged. Honest coach answers for non-lifting asks. The "What do you like to do?" question and demand logging. Recruit 5–10 testers who fit the wedge. | Miscounts and cue delay measured and improving; the screen catches the listed conditions in tests; a plank is a hold on new builds and still shows on old ones |
| **Gate 1** | Lifting retention: at least 10 testers, week-4 retention at the habit plan's 25% target | Pass, or fix lifting first |
| **Mobility inside lifting** | Stable exercise IDs and backfill; the block model (0a); about 30 reviewed mobility movements and holds; warm-up and cool-down blocks; "my back is tight today" | Mobility blocks completed, and lifting completion doesn't drop |
| **The library (0b)** | Facts imported from free-exercise-db behind a filter (no text, no images); our own instructions; safety properties; filter-and-alias search | Swaps for current lifters no worse; searches that find nothing tracked |
| **The AI planner** | Background drafting for lifting and mobility; checker and repair; the evaluation set in CI | Meets the evaluation bar above |
| **Gate 2** | Demand: at least 25–30% of testers asking for running or yoga | Pick one, or neither |
| **If running** | Strength for runners via Apple Health; then Couch to 5K on the timer; then WorkoutKit for Watch owners; GPS last | A new runner finishes week 1 of Couch to 5K; their runs show in the week |
| **If yoga** | 40–60 reviewed poses with checked safety properties; 10 flows; new standing and balance body keys | A beginner completes three flows in a week |
| **Later** | Generated entries (private until reviewed); sports with MET accounting; race-date plans | As defined then |

## 9. Risks

- **Safety and liability.** The screen, the safety properties, private-until-reviewed generated content, qualified review, and the stratified safety metrics. Plus a **claims register:** every health claim the coach or the store page makes has a citation, or it isn't made.
- **Regulation:**
  - **FDA general wellness:** stay in "training guidance". Pain, osteoporosis or back-pain programming must not read as treating a condition. Stop and refer.
  - **FTC:** health claims must be substantiated.
  - **App Store:** explicit consent before sending health details (pregnancy, conditions) to third-party AI (5.1.2(i)); HealthKit disclosures (5.1.3); remind users to check with a doctor (1.4.1).
  - **Breach and privacy:** the FTC Health Breach Notification Rule covers fitness apps; Washington's My Health My Data Act.
- **Licensing.**
  - Facts only from open datasets; our own words; no third-party images; provenance on every entry.
  - The rule that copyrighted text never goes into a prompt or the corpus.
- **Wedge dilution.** Positioning stays strength-first; new kinds only past Gate 2.
- **Voice.** Every timer and cue feature inherits today's voice problems, which is why voice comes first.
- **Scope.** The migration (0a) is the biggest single phase; the gates stop the rest from starting before it's earned.
- **Cost.** A per-user cap; templates first; one AI draft plus at most one repair.
- **Pricing.** Not decided. A generalist at Fitbod's price ($95.99/yr) competes with Strava+Runna and Fitness+ bundles. Strength-first with supporting kinds keeps the comparison favourable.

## 10. Decisions for Josh

1. **Approve the sequencing:** voice and the safety screen now, expansion behind the two gates. *Recommended.*
2. **A qualified reviewer:** budget a CSCS, physio or registered yoga teacher (a few hundred dollars for the first 30–60 entries). *Recommended: yes, before any mobility content ships.*
3. **The PAR-Q+:** write to the PAR-Q+ Collaboration for commercial permission, or have a clinician review our own screen wording.
4. **Testers:** recruit 5–10 people who fit the wedge (returning, anxious, 30–60), so Gate 1 can be measured.
5. **Videos:** links out only, or none. *Recommended: the body plus our own words, no third-party video.*

## 11. What the adversarial review changed

| Finding | Change |
|---|---|
| Expanding before voice works and lifting retains risks the wedge (product) | Gated sequencing (§8); voice and the screen first; mobility inside lifting before any new kind |
| Yoga-first is the most crowded, content-heavy choice (product) | Mobility inside lifting first; running or yoga chosen by measured demand; runners via strength-for-runners first |
| free-exercise-db's text and images are scraped (licensing, verified in wrkout's CONTRIBUTING and issues) | Facts only; our own words; no images; copyrighted text never in a prompt |
| yoga-api data is unlicensed and partly Yoga Journal; Zoned images come from free-exercise-db (licensing) | Names only from yoga-api; Zoned structures only; NHS, CDC and NIA added as clean sources |
| The doctor screen is a keyword match, not ACSM logic (safety, verified at `flow.ts:1099`) | A real screen in §2, shipped now |
| Unreviewed shared AI entries can't be defended, and are a stored prompt-injection path (safety, engineering) | Private until a qualified review; low-risk only; text only; never in others' prompts; recall |
| The running rules don't fit beginners; the polarized split was overstated (safety) | Couch to 5K under 8 weeks; the single-run rule only with history and below 10%; beginners run easy |
| Contraindications too narrow (glaucoma, osteoporosis, blood pressure, pregnancy); missing screens (youth, surgery, falls, medications, eating disorders) (safety) | Safety properties as filters; the expanded screen; in-session stop words |
| Old app builds drop blocks; IDs are names; migration scope under-listed (engineering, verified at `AppModel.swift:2129-2141`, `exerciseBaselines.ts:90`) | Dual-write, `schemaVersion`, minimum build, stable IDs with backfill, full scope list |
| AI planning is slower and token-limited compared with today's instant templates (engineering, verified at `modelProvider.ts:145`) | Template first, AI in the background, structured output, the checker auto-fixes, an evaluation set with a bar |
| Vector search is over-built at this size (engineering) | Filters plus aliases plus in-memory similarity |
| iOS background limits, Watch dependency, live voice colliding with timer cues (engineering) | Phone timer first, Watch optional, the timer owns cues, live voice ducked |
| Metrics flatter the expansion and hide harm (product, safety) | Per-kind retention, voice guardrails, stratified safety, pain linked to the plan's source |
| Citation details wrong (safety) | ACSM 2009, ACSM 2026, Impellizzeri, Oliveira and Frandsen corrected; the corpus count is 18 |
| Missing: units, offline, accessibility, flags, events, cost caps, regulation, pricing (all) | Added to §1, §5, §7 and §9 |
