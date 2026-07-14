# MYO Progress Tracking Plan

**Status:** design, ready for review
**Author:** Claude · **Date:** 2026-07-14
**Depends on:** the multi-week program model + plan-change memory shipped in the plan-cascade PR (trainingPrograms/current, plan_change memory facts)

## Purpose

MYO's promise is adaptability to the human with super-intelligent guidance framed by expert human wisdom. Adaptation is only credible if the app can *show* whether the plan is working. Today the app records everything (workouts, body weight, HRV, sleep) but derives nothing — there is no trend, no direction, no "you're getting somewhere." This plan adds the derived progress layer.

## Product Principle

Progress is not one number. The same body-weight chart is success going down for a fat-loss goal and success going up for a muscle-gain goal. The metric follows the activity; the direction follows the goal; the framing follows the protocol lens; the interpretation may follow physiology. The coach never invents progress — every claim it makes must trace to a computed metric the user can see.

## Metric Taxonomy

### 1. Standard (every user, every goal)

The universal metrics are about showing up, because adherence predicts everything else:

- **Adherence** — planned sessions vs. completed sessions per week (planned comes from trainingPrograms/current; completed from workoutLogs).
- **Consistency streak** — consecutive weeks meeting the plan's training-day count.
- **Total training volume trend** — sets × reps × load summed weekly, smoothed.
- **Session effort trend** — perceivedEffort (already logged per session) over time; a rising effort at flat volume is a readiness signal, not a progress signal.

### 2. Activity-specific (metric follows the movement)

- **Lifting** — estimated 1RM per exercise via the Epley formula (weight × (1 + reps/30)) computed from the best set per session, trended per exercise. All inputs (name, sets, reps, loadKg) already exist in workoutLogs.
- **Conditioning / cardio** — pace, distance, duration from HealthKit workout samples; heart rate at a reference pace when both streams exist (cardiac drift down = fitness up).
- **Bodyweight movement progression** — reps-at-bodyweight trend (push-ups, pull-ups) where load is 0.
- **Mobility / recovery styles** — session completion + subjective effort only; no false precision.

### 3. Goal-specific (direction follows the goal)

The profile's `goals` field decides which way "good" points and which metrics headline:

| Goal | Headline metrics | Good direction |
|---|---|---|
| lose fat | body-weight trend (7-day rolling avg), waist if logged | down, slowly (0.25–1%/wk band) |
| build muscle | body-weight trend + e1RM trend | weight up slowly, lifts up |
| get stronger | e1RM on the big lifts | up |
| general fitness / habits | adherence + streak | up |
| endurance | pace at reference HR, weekly duration | pace down / duration up |
| recomposition | weight flat + e1RM up | both together |

Rate bands matter as much as direction: losing weight *too fast* is a safety flag (existing safety policy already blocks rapid-weight-loss coaching), so the progress layer must classify "ahead of a safe band" as a caution, not a win.

### 4. Physiology / lens-specific (framing follows the protocol)

The coachingLens the user chose during onboarding decides which story the same numbers tell:

- **huberman** — recovery gates progress: HRV trend and sleep consistency are first-class; a strength PR on declining HRV is reported with a recovery caveat.
- **schoenfeld** — hypertrophy mechanics headline: weekly hard-set volume per muscle group and progressive-overload trend are the lead metrics.
- **sims** — cycle-aware interpretation for female users: a down week inside an expected cycle phase is not a plateau and must not be reported as one. Requires opt-in cycle data (HealthKit menstrual data is a new, sensitive consent category — see Consent below); degrade gracefully to standard framing without it.
- **blueprint** — consistency and longevity markers over peak numbers: resting-HR trend, sleep regularity, zero-missed-weeks streak headline; PR chasing is de-emphasized.
- **none** — standard framing.

The lens guardrail from the coach prompt carries over verbatim: a lens shapes emphasis and explanation, never what is safe.

## Architecture

Follows the derivedSummaries pattern already stubbed for HealthKit rollups (paths.ts `healthContextSummaryPath`, contract `DerivedHealthContext`).

### New derived doc: `users/{uid}/derivedSummaries/progress_current`

Zod contract `ProgressSummary` (contracts/coach-agent.ts), server-only write, owner read:

```
{
  userId, computedAt, windowDays: 42,
  adherence: { plannedSessions, completedSessions, weeklyRate: [..], streakWeeks },
  volume: { weeklyTotals: [..], trend: "up" | "flat" | "down" },
  lifts: [{ exerciseName, e1rmSeries: [{date, value}], trendPct }],   // top N by frequency
  body: { weightSeries: [{date, kg}], rollingAvgKg, trendPctPerWeek,
          goalDirection: "down" | "up" | "flat", withinSafeBand: boolean },
  conditioning: { paceSeries?, weeklyDurationMin? },
  recovery: { hrvTrend?, sleepConsistency?, restingHrTrend? },        // healthSamples-derived
  lensHighlights: [{ metric, framing, note }],                        // computed per coachingLens
}
```

### Builder: `functions/src/progress/build.ts`

Pure function `buildProgressSummary(logs, samples, program, profile)` + a thin writer. Recompute triggers:

1. `onDocumentCreated` on workoutLogs (a finished session is the natural heartbeat), debounced to at most once per hour via a `lastComputedAt` check.
2. After `ingestHealthSamples` batches (body weight changed).
3. On demand from the coach turn if the doc is missing or stale > 24h (lazy heal, same as ensureTrainingProgram).

Pure-function core means the math is unit-testable with fixture logs — no emulator needed for the numbers.

### Coach integration

- `loadCoachContext` reads progress_current; `buildCoachContextBundle` maps it to a compact `<progress_summary>` tag (respect the token budget: series capped to ~8 points, top 5 lifts).
- Prompt rule additions: "Ground any claim about the user's progress in <progress_summary>. Never invent trends. When the lens implies a caveat (recovery down, cycle phase), state it."
- This is also what makes plan adaptation smarter: the adapt_plan flow can now see "3 missed Mondays in a row" and propose moving the day — closing the loop between progress and the plan-cascade feature.

### iOS surface

- New Progress section (You tab or its own tab — defer to design): headline card per goal (the goal-specific table above decides the headline), adherence ring, per-lift trend sparklines, body-weight trend with the safe band drawn.
- Reads the single progress_current doc via one listener — same pattern as workoutPlans/current, no client-side math.
- Lens tint: the lensHighlights array drives one "through your protocol's eyes" callout card, which is the visible face of "expert human wisdom."

## Consent & Sensitivity

- Body-weight and recovery metrics come from already-consented HealthKit categories; no change.
- **Cycle data (sims lens) is new and the most sensitive category in the app.** Separate explicit consent record (existing ConsentRecord machinery), off by default, never in logs, never in the prompt unless consented, delete-on-revoke. Ship the sims lens framing WITHOUT cycle data first (it still reframes recovery/readiness); add cycle awareness as its own reviewed slice.
- Progress content in the coach prompt is evidence-not-instruction like every other tag (data-boundary block).

## Safety

- Rate-band classification (weight loss too fast → caution + existing clinician-escalation language) reuses the safety policy; the progress layer must never celebrate an unsafe rate.
- No diagnosis: recovery trends are "context only, never deterministic truth" (existing wearable rule) — HRV down means "consider an easier week," never "you are overtrained."

## Implementation Order

1. **Contract + builder core** — ProgressSummary schema, pure `buildProgressSummary` with fixture tests (adherence, e1RM, weight trend + safe band, volume). No triggers yet.
2. **Triggers + storage** — workoutLog trigger with debounce, healthSample hook, lazy heal. Emulator tests.
3. **Coach context** — `<progress_summary>` tag + prompt rules; verify token budget.
4. **iOS Progress surface** — headline card + adherence + lift sparklines reading progress_current.
5. **Lens highlights** — per-lens framing computation + the protocol callout card.
6. **Sims cycle-awareness slice** — separate PR: consent category, HealthKit menstrual read, cycle-phase classifier, prompt integration. Highest sensitivity, reviewed on its own.

Each step lands independently; the coach gets smarter at step 3 even if the iOS surface (step 4) trails.

## Open Questions

1. Which lift set headlines? (Top-N by frequency vs. a fixed big-lift list vs. user-pinned.) Suggest top-5 by frequency, user-pinnable later.
2. Where does Progress live in the iOS IA — You tab section or a fourth tab? Design call, not backend-blocking.
3. Waist/measurement logging doesn't exist yet — worth adding a manual metricSnapshot type for tape measurements in the fat-loss headline? Suggest yes, later slice.
4. Should progress_current be per-window (progress_42d) to allow multiple horizons? Suggest single doc with a fixed 6-week window until a real need appears.
