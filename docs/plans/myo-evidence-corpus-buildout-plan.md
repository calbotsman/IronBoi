# MYO Evidence Corpus Buildout Plan

## Purpose

MYO should personalize plans from reviewed evidence, not generic model memory.

The corpus has to support two jobs:

1. **Plan creation**: choose training structure, weekly dose, progression, recovery, and nutrition estimates based on the user's profile.
2. **Plan adaptation**: safely adjust for constraints like pain, pregnancy, low readiness, travel, less time, chronic conditions, or changed goals.

## Product Rule

Demographics should guide relevance and safety, not stereotypes.

MYO can use age, sex/gender, pregnancy/postpartum status, training age, disability/chronic-condition context, equipment, schedule, and goals to retrieve better evidence. It should not assume ability, motivation, hormone status, injury risk, diet, or identity from demographics alone.

## Source Tiers

### Tier 1: Public-health baselines

Use for universal minimums and broad safety framing.

- HHS / Physical Activity Guidelines for Americans
- CDC physical activity pages
- WHO physical activity and sedentary behaviour guidelines

### Tier 2: Medical society / sport science position stands

Use for population overlays and training prescription.

- ACSM resistance training guidance
- ACOG pregnancy/postpartum exercise guidance
- ADA exercise and diabetes guidance
- ISSN protein/exercise and female athlete nutrition position stands
- NSCA youth / long-term athletic development guidance

### Tier 3: Expert-reviewed MYO notes

Use for product-specific decision rules where public sources are broad.

- low-readiness adaptation
- missed-workout adaptation
- pain/injury escalation rule
- equipment substitution logic
- plan-proposal creation rules

These must be reviewed and versioned. The model should know they are internal notes, not public citations.

## Current Seed Sources

- WHO Guidelines on physical activity and sedentary behaviour  
  https://www.who.int/publications/i/item/9789240015128
- CDC Guidelines and Recommended Strategies  
  https://www.cdc.gov/physical-activity/php/guidelines-recommendations/index.html
- Physical Activity Guidelines for Americans, 2nd edition  
  https://odphp.health.gov/healthypeople/tools-action/browse-evidence-based-resources/physical-activity-guidelines-americans-2nd-edition
- CDC older adults activity guidance  
  https://www.cdc.gov/physical-activity-basics/adding-older-adults/what-counts.html
- CDC chronic conditions and disabilities activity guidance  
  https://www.cdc.gov/physical-activity-basics/guidelines/chronic-health-conditions-and-disabilities.html
- CDC pregnancy/postpartum activity guidance  
  https://www.cdc.gov/physical-activity-basics/guidelines/healthy-pregnant-or-postpartum-women.html
- ACOG exercise during pregnancy FAQ  
  https://www.acog.org/womens-health/faqs/exercise-during-pregnancy
- ACOG physical activity and exercise during pregnancy/postpartum committee opinion  
  https://www.acog.org/clinical/clinical-guidance/committee-opinion/articles/2020/04/physical-activity-and-exercise-during-pregnancy-and-the-postpartum-period
- ADA physical activity/exercise and diabetes position statement  
  https://pubmed.ncbi.nlm.nih.gov/27926890/
- ACSM resistance training guidance  
  https://acsm.org/effective-resistance-training-program-infographic/
- ISSN protein and exercise position stand  
  https://jissn.biomedcentral.com/articles/10.1186/s12970-017-0177-8
- ISSN nutritional concerns of the female athlete  
  https://www.tandfonline.com/doi/abs/10.1080/15502783.2023.2204066

## Corpus Taxonomy

Every entry should have:

- `entryId`
- `title`
- `sourceName`
- `sourceUrl`
- `sourceType`
- `reviewedAt`
- `staleAfter`
- `evidenceGrade`
- `tags`
- `appliesTo`
- `contraindications`
- `claims`
- `safetyBoundaries`
- `planImplications`
- `proposalImplications`
- `citationPolicy`

The current code has the first version of this shape in `ResearchCorpusEntry`. It should evolve toward this larger schema before the corpus gets large.

## Personalization Axes

MYO should retrieve by:

- age band: adolescent, adult, older adult
- training age: new, beginner, intermediate, advanced
- goal: strength, hypertrophy, fat loss, endurance, mobility, habit-building, return-to-training
- sex/gender context: user-stated only; use for estimates and population-specific safety checks
- pregnancy/postpartum: user-stated only; clinician-forward
- chronic condition/disability: user-stated only; clinician-forward when needed
- nutrition context: preferences, constraints, eating-disorder risk, minor status, pregnancy, kidney disease
- recovery/readiness: sleep, soreness, hangover, illness, stress, HRV/resting HR when HealthKit arrives
- equipment and schedule

## Retrieval Modes

### V1: keyword/category retrieval

Already started in `functions/src/corpus/researchCorpus.ts`.

Good enough for:

- pregnancy/postpartum
- older adults
- pain/injury
- low readiness
- time limits
- diabetes/chronic condition mentions
- protein/nutrition mentions

### V2: structured retrieval

Firestore collection:

`corpus/{entryId}`

Queries by:

- `tags`
- `appliesTo`
- `sourceType`
- `reviewedAt`
- `evidenceGrade`

### V3: hybrid retrieval

Use embeddings only after entries are curated and reviewed.

Keep metadata filters mandatory:

- never retrieve pregnancy guidance unless pregnancy/postpartum is relevant
- never retrieve disease-specific guidance unless user states it or profile contains it
- never retrieve another user's profile/memory/logs

## Plan Generation Rule

For onboarding and plan changes:

1. derive user context from authenticated `uid`
2. classify population/safety context
3. retrieve corpus entries
4. generate plan proposal with citations/source ids
5. show review card
6. apply only after user accepts

No broad plan change should be silently applied from chat.

## Safety Boundary

MYO is a wellness and fitness coach. It should not:

- diagnose
- prescribe rehab protocols
- prescribe medical diets
- manage diabetes medication/glucose events
- create pregnancy programming without clinician-forward constraints
- create aggressive weight-loss plans
- use demographic traits as stereotypes

## Build Order

1. Expand `ResearchCorpusEntry` contract to full metadata schema.
2. Move static seed entries into a typed JSON file.
3. Add `npm run validate:corpus`.
4. Add Firestore seeding script for `corpus/{entryId}`.
5. Add corpus retrieval tests.
6. Add citations/source ids to program proposals.
7. Add `PlanAdjustmentProposal` with source ids.
8. Add iOS source summary section in proposal cards.
9. Add corpus freshness checks.
10. Add human review workflow for new/updated entries.

## Acceptance Criteria

- The coach can explain why it chose a plan focus.
- Every safety-sensitive plan claim has a source id.
- Demographic/pregnancy/chronic-condition context affects retrieval, not identity assumptions.
- User data stays under `users/{uid}`.
- Shared corpus is read-only to clients.
- Production corpus updates require review.
