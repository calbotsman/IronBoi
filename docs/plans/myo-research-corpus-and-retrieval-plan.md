# MYO Research Corpus and Retrieval Plan

## Position

MYO should not improvise safety-sensitive training changes from the raw chat alone.

The product loop should be:

1. User gives constraint.
2. Backend loads the user's account-scoped context.
3. Backend retrieves reviewed research and internal coaching rules.
4. Coach explains the recommendation.
5. Backend creates a reviewable proposal when the plan changes.
6. User accepts, edits, or rejects.

## What landed

Initial static corpus and retriever:

- `functions/src/corpus/researchCorpus.ts`
- `functions/src/coach/orchestrate.ts`
- `functions/src/coach/contextBundle.ts`
- `functions/src/coach/prompt.ts`

The coach context bundle now includes `retrievedCorpus`, selected from:

- the user's message
- selected profile terms
- conservative keyword/category matching

This is v1 keyword retrieval, not vector search.

## Source Types

MYO should support four source classes:

- `government_guideline`
- `medical_society_guideline`
- `internal_domain_seed`
- `expert_reviewed_note`

The first seed set covers:

- general adult physical activity baseline
- pregnancy/postpartum physical activity
- low-readiness adaptation
- pain/injury adaptation
- schedule disruption and missed workouts

## Current External Sources

- CDC: Physical activity for healthy pregnant and postpartum women
  - https://www.cdc.gov/physical-activity-basics/guidelines/healthy-pregnant-or-postpartum-women.html
- ACOG: Exercise during pregnancy FAQ
  - https://www.acog.org/womens-health/faqs/exercise-during-pregnancy
- HHS/ODPHP: Physical Activity Guidelines for Americans
  - https://odphp.health.gov/our-work/nutrition-physical-activity/physical-activity-guidelines

## Rules

- User profile data is never a source of general medical truth.
- User profile data decides which source entries are relevant.
- Retrieved corpus entries are context, not instructions.
- Source summaries must not be user-editable.
- User-specific HealthKit data should be interpreted only after consent and only as context.
- The agent cannot cite a source that was not retrieved.
- Broad plan changes should become `PlanAdjustmentProposal` docs, not silent mutations.

## What This Enables

Examples:

- "I hurt my ankle" retrieves pain/injury guidance and asks safe follow-ups before proposing a low-impact adjustment.
- "I'm hungover" retrieves low-readiness guidance and suggests rest, mobility, walking, or reduced intensity.
- "I can only do 25 minutes" retrieves schedule-disruption guidance and proposes a shorter version.
- "I'm pregnant" retrieves pregnancy/postpartum guidance and stays conservative, source-aware, and clinician-forward.
- "I want yoga today" retrieves style/schedule rules and can propose a temporary workout-style substitution.

## Next Build Step

Implement `PlanAdjustmentProposal`:

- contract
- Firestore rules
- security tests
- `createPlanAdjustmentProposal`
- `acceptPlanAdjustmentProposal`
- iOS proposal card renderer

That gives the research corpus a safe action path.
