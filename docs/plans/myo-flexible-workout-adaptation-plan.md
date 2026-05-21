# MYO Flexible Workout Adaptation Plan

## Purpose

MYO needs to handle real-life training interruptions without turning the coach into an unsafe medical advisor or letting the model mutate plans directly.

Users should be able to say:

- "I hurt my ankle the other day. Can you adjust my workout?"
- "I'm hungover."
- "I only have 20 minutes."
- "I have to skip today."
- "I want to try yoga instead."
- "I'm pregnant."
- "I only have dumbbells today."

The product answer is not just chat. MYO should classify the constraint, ask safety follow-ups when needed, create a reviewable proposal when the plan changes, and apply the change only after user approval.

## Product Principle

The coach explains. The backend proposes. The user approves. The workout UI executes.

No broad plan mutation should happen silently. Narrow deterministic edits, like changing a target dumbbell weight from 45 lb to 35 lb, can auto-apply when the request is unambiguous and scoped to one exercise.

## Constraint Taxonomy

### Low-Risk Convenience

Examples:

- less time today
- different equipment
- gym is crowded
- wants a bodyweight version
- wants a better demo
- wants a different style for variety

Behavior:

- Coach can suggest options directly.
- Backend can create a proposal if the weekly plan changes.
- One-off workout changes can be applied to the active session after user confirmation.

### Recovery / Readiness

Examples:

- hungover
- poor sleep
- sore
- low energy
- stressed
- coming back after travel

Behavior:

- Coach should reduce intensity, complexity, and injury risk.
- Propose one of:
  - deload today
  - mobility / walk / light technique day
  - shorten workout
  - move workout to tomorrow
- No shame language.

### Schedule Disruption

Examples:

- skip workout
- missed yesterday
- traveling
- only has two days this week

Behavior:

- Coach creates a weekly reshuffle proposal.
- Avoid cramming missed volume into one day.
- Preserve rest spacing where possible.

### Pain / Injury

Examples:

- ankle pain
- knee hurts during squats
- shoulder discomfort pressing
- back pain after deadlifts

Behavior:

- Ask severity and red-flag follow-ups before proposing changes when needed.
- Stop or replace aggravating movement.
- Suggest lower-risk alternatives without diagnosing.
- Include clinician escalation language for sharp, persistent, worsening, swelling, inability to bear weight, neurological symptoms, chest symptoms, dizziness, fainting, or acute trauma.
- Always create a review card for plan edits; never auto-apply broad injury adaptations.

### Pregnancy / Postpartum

Examples:

- pregnant
- postpartum
- trying to conceive and wants safer programming

Behavior:

- Treat as a population-specific safety context.
- Ask whether they have clinician clearance and whether there are any restrictions.
- Keep guidance general and conservative.
- Do not prescribe intense new modalities, aggressive calorie targets, or risky movements.
- Create a review card with safety notes.

Current reference points:

- CDC says moderate-intensity physical activity is generally safe for healthy pregnant and postpartum women and references the Physical Activity Guidelines for Americans.
- ACOG says pregnant users should watch for warning signs during exercise and stop/escalate when those signs appear.

Sources:

- CDC: https://www.cdc.gov/physical-activity-basics/guidelines/healthy-pregnant-or-postpartum-women.html
- ACOG FAQ: https://www.acog.org/womens-health/faqs/exercise-during-pregnancy
- ACOG Committee Opinion: https://www.acog.org/clinical/clinical-guidance/committee-opinion/articles/2020/04/physical-activity-and-exercise-during-pregnancy-and-the-postpartum-period

## Firestore Shape

Use a new adaptation proposal collection instead of overloading onboarding proposals:

```text
users/{uid}/planAdjustmentProposals/{proposalId}
```

Candidate schema:

```json
{
  "userId": "uid",
  "proposalId": "adj_2026_05_11_abc",
  "source": "coach",
  "category": "injury_pain",
  "status": "pending",
  "createdAt": "2026-05-11T22:00:00.000Z",
  "expiresAt": "2026-05-18T22:00:00.000Z",
  "riskLevel": "high",
  "requiredUserAction": "answer_follow_up",
  "userRequestSummary": "User reported ankle pain and asked to adjust today's workout.",
  "coachRationale": "Avoid ankle-loaded and impact work until symptoms are clearer.",
  "safetyNotes": [
    "MYO cannot diagnose ankle pain.",
    "Seek clinician guidance for inability to bear weight, swelling, sharp pain, worsening symptoms, or acute trauma."
  ],
  "followUpQuestions": [
    "Can you bear weight on the ankle?",
    "Is there swelling or sharp pain?"
  ],
  "proposedPlanPatch": {
    "type": "modify_day",
    "planId": "current",
    "dayKey": "Thu",
    "removeExercises": ["HIIT Sprints (20s on/10s off)", "Walking Lunges"],
    "addExercises": [
      { "name": "Seated Dumbbell Shoulder Press", "sets": 3, "reps": 10, "weight": 35 },
      { "name": "Dead Bug", "sets": 3, "reps": 10, "weight": 0 }
    ]
  },
  "decision": "pending",
  "decidedAt": null
}
```

## Proposal Categories

```text
time_limit
equipment_limit
skip_or_reschedule
readiness_low
style_preference
injury_pain
pregnancy_postpartum
travel
other
```

## UX

### Workout Detail

Add contextual asks:

- Change weight
- Less time
- Skip today
- Pain or injury
- Different style
- Better demo

### Coach Chat

When the coach creates a proposal, render a card:

- what changed
- why
- safety notes
- affected day(s)
- Accept
- Edit
- Reject

### Plan Tab

Show pending proposals above the week.

## Backend Rules

- All proposal creation is server-only.
- Client can read own proposals.
- Client can only update decision fields.
- Accepting a proposal must run in a transaction:
  - confirm proposal belongs to `auth.uid`
  - confirm status/decision is pending
  - apply bounded patch to `workoutPlans/current`
  - write audit fields
  - mark proposal accepted

## Implementation Order

1. Add `PlanAdjustmentProposal` contract.
2. Add Firestore rules and security tests.
3. Add callable/HTTP accept-reject endpoint.
4. Add deterministic proposal builders for:
   - less time
   - skip/reschedule
   - equipment limitation
   - injury-safe modification shell
5. Add iOS proposal card model/listener.
6. Render proposal cards in Coach and Workout/Plan surfaces.
7. Teach coach prompt to create proposals instead of claiming changes happened.
8. Add eval cases for injury, pregnancy, hungover, skipped workout, yoga preference, and time limits.

## Non-Goals For First Version

- No diagnosis.
- No full rehabilitation protocols.
- No aggressive pregnancy programming.
- No automatic broad plan rewrites.
- No HealthKit-driven readiness automation until HealthKit consent and metric quality are built.
