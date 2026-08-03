# MYO Exercise Swaps and Weight Baselines

Extends [myo-flexible-workout-adaptation-plan.md](myo-flexible-workout-adaptation-plan.md)
with two changes the user can make directly, without a coach turn.

## Why these two are not proposals

The adaptation plan's product principle is "the coach explains, the backend
proposes, the user approves." It carves out an exception:

> Narrow deterministic edits, like changing a target dumbbell weight from
> 45 lb to 35 lb, can auto-apply when the request is unambiguous and scoped
> to one exercise.

Both features here sit squarely in that carve-out. Each is scoped to one
exercise, each is triggered by an explicit user tap, and neither involves the
model. Routing them through a proposal card would mean asking the user to
approve a change they just made.

Because there is no proposal doc to look back at, both write an audit event
(`exercise_swapped`, `exercise_baseline_rebaselined`).

## 1. Exercise swaps

**The ask:** "if we're doing push + HIIT and I don't have equipment or I don't
feel like doing a move, I should have a button that gives me options for
workouts that hit the same muscle groups — before a workout starts or during
one."

### Catalog

`functions/src/workouts/exerciseCatalog.ts` — muscle groups, equipment, and
movement pattern for ~75 exercises. The first 43 mirror iOS
`ExerciseKnowledge` exactly; the rest are added alternates so that every
movement in the catalog has at least one substitute (a test enforces this).

It lives on the server because a swap mutates the plan, and every plan
mutation here is server-authoritative. If the client decided what a valid swap
was, the server would be rubber-stamping arbitrary exercise names into the
program. iOS keeps `ExerciseKnowledge` for cues and demo videos; that's
presentation, this is the decision surface.

### Ranking

A candidate must share a canonical **primary** muscle to be offered at all.
Secondary overlap alone would surface Plank as a substitute for Bench Press
(both list chest somewhere), and an option list the user can't trust is worse
than none.

Score = muscle overlap (primary weighted 0.8, secondary 0.2) + 0.35 for the
same movement pattern + 0.05 for the same load class. Name breaks ties so the
list is deterministic.

### Equipment

`availableEquipment` distinguishes three states:

- omitted / `null` — no constraint
- `[]` — "I have nothing today", filters to bodyweight
- `["dumbbell", "bench"]` — filters to what those allow

An empty array is a real answer, not a missing one.

### Scopes

| Scope | Writes | Expires |
|---|---|---|
| `session` | `activeWorkout` + `workoutSessions/{id}` | with the session |
| `today` | `workoutPlans.dailyOverrides[date]` | on its own, by date |
| `going_forward` | `workoutPlans.days[dayKey]` + program weeks ≥ active | never |

A mid-workout swap defaults to `session` — most are about today's equipment or
energy, not a standing change.

**Completed sets are preserved.** If two sets of bench were logged before the
swap, those sets happened: the original stays (truncated to what was
completed, marked done) and the replacement is inserted after it. Dropping it
would erase real work from the workout log and every progress metric built on
it. `exerciseIndex` is reassigned across the whole array afterwards — it is
the client's row identity, and duplicates render as a missing row in SwiftUI.

**Load does not carry across load classes.** 225 lb is a plausible back squat
and an impossible goblet squat, so a cross-class swap suggests 0 ("set your
weight") rather than a fake prescription. A user's own baseline for the
replacement always wins over anything carried over.

## 2. Weight baselines and progression

**The ask:** "if I drop it to 30 lbs and it suggested 60, we should rebaseline
so next time I start at 30 — or if there's an incremental weight load per
workout, we at least start at 30."

Clarified in conversation: *"It depends on the coach's recommendation. If we're
in a protocol that says we should be increasing by x% each week or every 2
weeks we should follow that."*

### Why a flat rewrite was wrong

The obvious implementation — rewrite the plan's 60 to 30 — silently discards
the protocol. The ask is for **both**: the drop sticks, and progression keeps
running from the new number.

So the prescribed weight became a derived value:

```
prescribed = anchor + progression(weeks since the anchor was set)
```

Re-anchoring to 30 restarts that clock at 30. Under "+5 lb/week": week one
prescribes 30, week two 35, week three 40. Not 65.

### Progression is new data

Before this, progressive overload existed in this repo only as *coaching
language* — corpus entries and prompt text. Every materialized program week
held a byte-identical copy of the same days, so no prescribed weight ever
moved on its own. `ExerciseProgression` (`none` | `linear_lb` | `percent`,
with `everyWeeks` and a `capMultiple` ceiling) is the first executable form of
it, and is optional on `PlannedExercise`.

Percent mode is linear on the anchor, not compounding: 5%/week compounded is
+63% over ten weeks, which is not what anyone means.

### Where it takes effect

- `startWorkoutSession` resolves each weight through the anchor. **No anchor
  means the plan's own number stands** — so every existing user sees no change
  until they rebaseline something.
- `applyExerciseBaselines` writes the anchor *and* rewrites
  `workoutPlans/current` and future program weeks. The Train tab reads those
  docs from a snapshot listener; a stale 60 there is a number the user sees
  and stops trusting.
- `rolloverTrainingPrograms` recomputes weights when a program crosses a week
  boundary. It's the right home because the result is derived purely from
  (anchor, progression, today), so a retried or crashed run converges instead
  of stacking increases.
- `startWorkoutSession` seeds an anchor for exercises that carry a progression
  rule but have none yet — otherwise a coach-authored protocol would never
  move. The seed equals what the plan already said, so nothing visibly changes
  the day it is written.

### Ask, don't assume

Per the decision in conversation, finishing a workout **proposes** and writes
nothing. `finishWorkoutSession` returns `baselineSuggestions`; the finish card
lists them pre-checked; `applyExerciseBaselines` commits.

The suggestion uses the **mode** of completed set weights, not the last or the
max — three sets at 30 and one mistaken tap at 60 means the user worked at 30.
Direction-agnostic: going heavier is as much a new working weight as going
lighter, and anchoring only drops would leave someone who moved up being
prescribed the old number forever.

### Evidence gating

`applyExerciseBaselines` requires a `sessionId` and verifies each exercise was
in that session with at least one completed set. A weight staged on a stepper
but never lifted is not evidence and cannot become an anchor. The collection
is server-write-only in `firestore.rules`.

## Surfaces

- `users/{uid}/exerciseBaselines/{exerciseKey}` — new, server-only
- Callables: `getExerciseSwapOptionsCallable`, `swapExerciseCallable`,
  `applyExerciseBaselinesCallable` (plus `*Http` twins, since iOS can be
  flipped back to the bearer-token transport by one line in `AppModel`)
- iOS: `ExerciseSwapSheet`, `BaselineUpdateSheet`; swap entry points on the
  planned-exercise sheet, the active-workout card, and the active-exercise
  sheet

## Name resolution

Exercise names are not a controlled vocabulary — `adapt_plan` lets the model
author one freely, and older plans carry shorthand. An exact-match lookup
meant "Back Squat" resolved to nothing and the swap button opened an empty
list, which is the exact failure this feature exists to prevent.

`lookupExercise` therefore tries, in order: exact key → curated alias table →
token-subset match with stemming ("Push-up" ⊂ "Push-ups"). A query matching
several entries resolves to **nothing** — "Squat" alone is ambiguous, and an
empty list is honest where a wrong substitute is not. The alias table is the
escape hatch for shorthand that is ambiguous by tokens but obvious in a gym
("Bench Press" → the barbell one); each line is a decision, not an inference.

## Coach integration

`find_exercise_swaps` is a **read-only** tool. It returns the same ranked
options the UI shows, so the coach can name movements MYO actually has cues
and demos for.

It deliberately has no write path. Applying a swap from chat still goes
through `adapt_plan` → review card → accept, because the model *choosing* a
replacement is a judgment call and the product principle is that the user
approves those. What the tool removes is the model guessing: before it,
`adapt_plan` accepted any model-authored exercise name with nothing checking
that the movement trained what it replaced.

The prompt also tells the coach that working weight is already handled at
finish, so "I dropped to 30" gets acknowledged rather than turned into a
redundant plan-change card.

## Not done

- `swap_exercise` is not a coach tool — chat swaps go through the proposal
  card, one extra tap, rather than mutating directly.
- `adapt_plan`'s model-authored `dayPatches` are still not validated against
  the catalog. `find_exercise_swaps` makes the right answer easy to reach but
  nothing yet *enforces* that a proposed substitute trains the same pattern.
- `exerciseBaselines` is not in the coach context bundle (`contextRole:
  "internal"`). The coach sees the derived weights via the plan instead.
- No UI to view or edit anchors directly — the only way to move one is to
  finish a workout at a different weight.
- Swap options are not personalized by the user's profile `equipment` list;
  the filter is explicit chips the user taps.
