# IronBoi PWA Mechanics Porting Audit

**Date:** 2026-05-11  
**Scope:** Original single-file IronBoi/Iron Lab React PWA in `/Users/joshualong/IronBoi/src/App.jsx`, current Firebase backend, current MYO iOS app direction.  
**Purpose:** Identify what from the initial web app is worth porting into the MYO coach-led product, what should be rebuilt, and what should be left behind.

---

## Executive Summary

The original PWA is useful, but not as an app shell to copy. Its value is in the workout mechanics and domain seed data:

- exercise and muscle taxonomy
- curated exercise swap lists
- same-muscle fallback swap logic
- default plan structure
- workout start / set tally / finish-log flow
- daily habit checklist pattern
- exercise form cues and muscle metadata
- "missed day, shift the week forward" mechanic
- lightweight progress/history summary

MYO should not become a pure chat app. Chat is too slow for in-workout execution. The product should split responsibilities:

- **MYO Coach:** plans, explains, adapts, summarizes, remembers, asks follow-up questions.
- **Workout UI:** lets the user start, swap, tally sets, mark exercises done, add notes, and finish quickly.
- **Backend tools:** turn those taps into validated logs, memory candidates, plan proposals, and coach context.

The PWA's old UI, localStorage model, inline images, hardcoded personal defaults, and direct client plan editing should not be ported as-is.

---

## Source Inventory

Primary file:

- `/Users/joshualong/IronBoi/src/App.jsx`

Relevant existing backend seed:

- `/Users/joshualong/IronBoi/functions/src/domain/ironlab-seed.json`

Current user-scoped Firestore paths:

- `users/{uid}/workoutPlans/{planId}`
- `users/{uid}/workoutLogs/{sessionId}`
- `users/{uid}/dailyChecks/{date}`
- `users/{uid}/memoryFacts/{factId}`
- `users/{uid}/metricSnapshots/{snapshotId}`
- `users/{uid}/coachSessions/{sessionId}/messages/{messageId}`

---

## Porting Matrix

| PWA Mechanic | Where It Lives | Port Decision | MYO Interpretation |
|---|---|---:|---|
| Exercise library by muscle group | `EXERCISE_LIBRARY` | **Port** | Seed structured exercise catalog for plan generation, adding exercises, filtering, and swaps. |
| Exercise DB with primary/secondary muscles + cues | `EXERCISE_DB` | **Port** | Core domain data. Should become typed seed data and eventually reviewed corpus entries. |
| Curated swap options | `SWAP_OPTIONS` | **Port** | Use as deterministic first-pass substitution graph. Coach can explain why a swap fits. |
| Same-muscle swap fallback | `getSwapOptions` | **Port logic** | Backend/tool logic: propose substitutions from same primary muscle while avoiding duplicates. |
| Default weekly plan | `DEFAULT_PLAN` | **Port as template** | Starter template only, not a universal program. Coach adapts it after onboarding. |
| Start workout | `startWorkout(day)` | **Rebuild UI** | "Start today's session" creates/resumes an active workout session. Coach can adjust before start. |
| Set tally buttons | `completedSets`, `toggleSet` | **Port UX pattern** | Keep fast tap controls. Do not make users log every set through chat. |
| Mark exercise done | `completedExercises`, `toggleExDone` | **Port UX pattern** | Keep a completion control separate from per-set completion. |
| Finish workout | `finishWorkout`, `toFirestoreWorkoutLog` | **Port, server-mediated** | Finish writes validated log, generates summary, and creates memory/adaptation candidates. |
| Add exercise | `addEx`, muscle filter UI | **Rebuild** | Coach-led proposal plus manual override. User can add quickly; backend validates exercise shape. |
| Edit sets/reps/weight | `updateEx` | **Rebuild** | Plan edits become proposals/approvals, not silent mutation of the canonical plan. |
| Remove exercise | `removeEx` | **Rebuild** | User can remove during workout; coach records reason when useful. |
| Shift week forward | `shiftForwardFrom` | **Port concept** | Strong product mechanic: "I missed Monday, adapt my week." Should become a coach tool. |
| Daily habits | `DAILY_HABITS`, `recordDailyCheck` | **Port pattern** | User-configurable habits/check-ins, not hardcoded personal items. |
| History totals | `totalWorkouts`, `totalSetsLogged` | **Port** | Progress surface v1: sessions, sets, adherence, streak, recent PRs later. |
| Exercise modal | `ExerciseModal` | **Rebuild content** | Keep form cues, muscles worked, demo media. Replace generic web modal with native iOS sheet/card. |
| Muscle diagram | `MuscleDiagram` | **Maybe later** | Good education feature, not required for first functional workout loop. |
| YouTube video IDs | `YT_VIDEOS` | **Review before port** | Useful, but production needs curated source metadata and avoid random search as authority. |
| Philosophy/science cards | `PHILOSOPHY` | **Quarantine/review** | Useful brand/content seed, but should enter corpus with citations before coach cites claims. |
| localStorage persistence | `ironlab_logs`, `ironlab_plan`, `ironlab_daily` | **Do not port** | Firebase/Firestore is source of truth. Local cache only for offline/resume behavior. |
| Inline base64 exercise images | `EXERCISE_IMGS` | **Do not port** | Replace with reviewed asset pipeline or remote media metadata. |
| Old Iron Lab branding/UI | `C`, `T`, inline styles | **Do not port** | MYO needs its own brand system and native iOS interaction language. |

---

## What To Keep

### 1. Domain Data

The strongest reusable artifact is the exercise knowledge layer:

- exercise names
- muscle groups
- primary muscles
- secondary muscles
- form cues
- swap alternatives
- default set/rep/weight examples

This should move toward typed domain seed files, not stay embedded in UI code. The repo already has `/Users/joshualong/IronBoi/functions/src/domain/ironlab-seed.json`, so the next step is to treat it as the canonical seed and add types/tests around it.

Recommended v1 shape:

```ts
type ExerciseCatalogEntry = {
  id: string;
  displayName: string;
  category: "strength" | "cardio" | "mobility" | "rehab" | "core";
  equipment: string[];
  primaryMuscles: string[];
  secondaryMuscles: string[];
  cues: string[];
  contraindicationNotes?: string[];
  demoMedia?: {
    provider: "youtube" | "internal";
    id: string;
    reviewed: boolean;
  }[];
};
```

### 2. Workout Execution Mechanics

The PWA correctly discovered that workouts need tactile state:

- start a workout
- see the plan
- tap sets complete
- mark an exercise done
- swap when blocked
- finish and log

These should become native iOS flows. The coach should be present, but not required for every tap.

### 3. Adaptation Mechanics

The "shift week forward" feature is exactly the kind of thing MYO should own:

- missed workout
- short on time
- equipment unavailable
- soreness / low readiness
- travel day
- user wants to change goal

The PWA version mutates the weekly plan directly. MYO should instead generate an explicit adaptation proposal:

```json
{
  "proposalType": "shift_week_forward",
  "reason": "missed_session",
  "sourceSessionId": "2026-05-11_monday",
  "changes": [
    { "day": "Mon", "action": "set_rest" },
    { "day": "Tue", "action": "move_from", "from": "Mon" }
  ],
  "requiresUserApproval": true
}
```

### 4. Daily Habit Pattern

The daily checklist is useful, but the old hardcoded habits are personal to the original app. In MYO, daily checks should be user-configurable and coach-aware:

- supplements, if user chooses to track them
- mobility / rehab reminders, with safe wording
- sleep routine
- protein target check
- step goal
- hydration
- planned recovery work

The coach should use these as context, not as medical compliance claims.

---

## What To Rebuild

### Plan Editing

The PWA lets the user directly mutate the plan. That was fine for a local app. In MYO, direct mutation should be replaced with:

1. user asks or taps a change
2. backend validates the requested change
3. coach/tool creates a plan proposal
4. user approves
5. canonical plan updates
6. agent context sees the approved plan

This matters because the plan is not just UI state anymore. It feeds memory, coach decisions, HealthKit interpretation, and future progress analysis.

### Swap Flow

The current swap is:

1. open list
2. pick alternative
3. replace exercise name

MYO swap should be:

1. user taps swap
2. UI asks why: equipment, pain/discomfort, boredom, too hard, too easy, time
3. backend generates 2-4 safe options
4. user picks one
5. system logs the substitution and reason
6. coach can learn a memory candidate if repeated

Example:

```json
{
  "event": "exercise_swapped",
  "from": "Barbell Back Squat",
  "to": "Goblet Squat",
  "reason": "equipment_unavailable",
  "source": "user_selected",
  "coachVisibleSummary": "User substituted goblet squats when barbell was unavailable."
}
```

### Workout Logging

The PWA logs only completed sets/exercises and totals. MYO should keep that, then add optional fields over time:

- perceived difficulty / RPE
- pain or discomfort flag
- notes
- skipped reason
- weight used per set
- reps achieved per set
- duration
- HealthKit workout identifier

Do not require all of this in v1. Keep the first workout logging loop fast.

### Coach Chat

The PWA coach chat is a tab. MYO should make chat a layer over the product, not the whole product. The coach should be able to answer:

- "what should I do today?"
- "swap this"
- "I missed yesterday"
- "make this shorter"
- "my knee hurts during this"
- "what did I do last week?"

But the answer should often include actions/proposals the UI can render, not only text.

---

## What To Leave Behind

Do not port these:

- single-file app architecture
- inline style system
- inline base64 images
- localStorage as source of truth
- direct client writes as the canonical plan mutation layer
- generic YouTube search as a production education source
- hardcoded personal habits
- hardcoded "get ripped" goal banner
- old Iron Lab visual identity
- fixed weekly plan as the default for every user

---

## Recommended Product Architecture

### Principle

MYO should be a **coach-led workout operating system**, not a chat-only coach and not a static planner.

### Surface Split

| Surface | Job |
|---|---|
| Coach | Planning, reasoning, adaptation, explanation, follow-up questions, summaries. |
| Today | Shows current recommendation, readiness, next workout, and quick actions. |
| Active Workout | Fast set tally, exercise cards, swap, notes, finish. |
| Plan | Approved plan, upcoming sessions, pending coach proposals. |
| Progress | Logs, adherence, trends, milestones. |
| Profile/Memory | Editable user facts, goals, constraints, preferences. |

### Agent Tool Split

Recommended near-term tools:

| Tool | Purpose |
|---|---|
| `start_workout_session` | Creates/resumes an active workout from current plan or coach proposal. |
| `swap_exercise` | Returns safe substitutions and records selected swap reason. |
| `complete_set` | Optional server-side set event if we want live sync; client batching may be enough for v1. |
| `finish_workout` | Validates completed workout, writes log, triggers summary/adaptation candidates. |
| `propose_plan_adaptation` | Creates user-reviewable plan changes after missed sessions, constraints, soreness, time limits. |
| `record_daily_check` | Tracks user-configured daily habits. |
| `summarize_progress` | Reads logs and returns bounded, source-grounded summaries. |

---

## Recommended Firestore Shape

Current paths are good enough for the next step. Add active workout state before making the iOS Plan tab real.

Recommended v1 additions:

```text
users/{uid}/activeWorkout/current
users/{uid}/workoutSessions/{sessionId}
users/{uid}/workoutSessions/{sessionId}/events/{eventId}
users/{uid}/programProposals/{proposalId}
```

Candidate `activeWorkout/current`:

```json
{
  "sessionId": "2026-05-11_upper_a",
  "planId": "current",
  "dayKey": "Mon",
  "status": "active",
  "startedAt": "serverTimestamp",
  "updatedAt": "serverTimestamp",
  "exercises": [
    {
      "exerciseId": "push_up",
      "displayName": "Push-Up",
      "targetSets": 3,
      "targetReps": 12,
      "completedSets": [
        { "setIndex": 0, "completed": true, "reps": 12, "weight": 0 }
      ],
      "exerciseDone": false,
      "notes": ""
    }
  ]
}
```

Security rule posture:

- owner can read active workout/session state
- client may write narrow active-workout progress fields if rules can validate shape
- canonical workout log should be written by a callable/tool after validation
- coach messages stay server-only for assistant role
- plan proposals are server-created and user can only accept/reject allowed fields

---

## Suggested Build Order

### Step 1: Extract and type the PWA domain seed

Use `/Users/joshualong/IronBoi/functions/src/domain/ironlab-seed.json` as the source and add:

- typed loader
- validation test
- normalized exercise IDs
- explicit equipment metadata where obvious
- duplicate/missing-reference checks for swaps

### Step 2: Add deterministic workout tools

Build tools before fancy UI:

- `startWorkoutSession`
- `swapExercise`
- `finishWorkout`

These should be callable/testable without the model, then exposed to the coach.

### Step 3: Build native Active Workout screen

The iOS app needs a real execution surface:

- today's session card
- start/resume
- exercise cards
- set buttons
- done toggle
- swap button
- finish button

This is the first place to port the PWA's actual UX learnings.

### Step 4: Connect coach to actions

When the user asks "I want to get ripped" or "I missed yesterday," the coach should not only reply. It should create a proposal:

- starter profile goal candidate
- starter workout recommendation
- plan adaptation proposal
- memory candidate

### Step 5: Add Profile + Memory editing

The user needs inspectable/editable context before HealthKit expansion:

- goal
- equipment
- injuries/limitations
- schedule
- preferences
- stored memories
- delete/edit controls

### Step 6: Add HealthKit ingestion later

HealthKit should not be first. Manual workout execution proves the loop. Then HealthKit can add:

- workout duration
- heart rate summary
- sleep
- steps
- resting HR / HRV as soft signals only

---

## Open Product Questions

These are worth deciding before building the full Plan tab:

1. Is the first workout experience generated from onboarding, selected from a template, or manually chosen?
2. Should users be able to directly edit the canonical plan, or should all material edits go through proposals?
3. Which workout fields are required in v1: set completed only, or reps/weight/RPE too?
4. Should active workout state sync live to Firestore, or batch locally and submit on finish?
5. What is the first MYO-specific visual identity for workout execution, separate from the old Iron Lab style?
6. Which old exercise videos/images are acceptable to use, and who reviews them?
7. Should daily habits be created by the user, suggested by the coach, or both?

---

## Concrete Recommendation

Build toward this product rule:

> The coach decides and explains; the workout UI executes; the backend validates and remembers.

That means we should not port the old PWA wholesale. We should port the mechanics that made it usable:

- start
- swap
- tally
- finish
- shift missed workouts
- daily checks
- log/progress summary

Then rebuild them as typed, server-backed, coach-aware iOS flows.

