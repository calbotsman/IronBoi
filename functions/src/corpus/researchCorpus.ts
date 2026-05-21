import { ResearchCorpusEntry } from "../contracts/coach-agent.js";

export type RetrievedCorpusEntry = {
  entryId: string;
  title: string;
  sourceName: string;
  sourceUrl?: string;
  sourceType: string;
  reviewedAt: string;
  tags: string[];
  appliesTo: string[];
  summary: string;
  claims: string[];
  safetyBoundaries: string[];
  matchReasons: string[];
};

const RESEARCH_CORPUS = [
  {
    entryId: "pag_adults_strength_aerobic_2018",
    title: "Physical Activity Guidelines for Americans: Adult baseline",
    sourceName: "U.S. Department of Health and Human Services",
    sourceUrl:
      "https://odphp.health.gov/our-work/nutrition-physical-activity/physical-activity-guidelines",
    sourceType: "government_guideline",
    reviewedAt: "2026-05-11T00:00:00.000Z",
    tags: ["general_fitness", "strength", "aerobic", "baseline_guideline"],
    appliesTo: ["adult", "general_population"],
    summary:
      "Adults should combine aerobic activity with muscle-strengthening work. This is a baseline wellness guideline, not a personalized training prescription.",
    claims: [
      "For general adult wellness, include muscle-strengthening activity involving major muscle groups at least two days per week.",
      "Some activity is better than none; progression should be gradual when the user is new, detrained, or returning after a break.",
    ],
    safetyBoundaries: [
      "Do not use the guideline to prescribe through acute symptoms, medical conditions, or injury pain.",
      "Use user profile, training age, recovery, and constraints before recommending volume or intensity.",
    ],
  },
  {
    entryId: "who_physical_activity_guidelines_2020",
    title: "WHO physical activity and sedentary behaviour guidelines",
    sourceName: "World Health Organization",
    sourceUrl: "https://www.who.int/publications/i/item/9789240015128",
    sourceType: "government_guideline",
    reviewedAt: "2026-05-11T00:00:00.000Z",
    tags: [
      "general_fitness",
      "children_adolescents",
      "adults",
      "older_adults",
      "pregnancy",
      "postpartum",
      "chronic_conditions",
      "disability",
      "sedentary_behavior",
    ],
    appliesTo: [
      "child",
      "adolescent",
      "adult",
      "older_adult",
      "pregnant",
      "postpartum",
      "chronic_condition",
      "disability",
    ],
    summary:
      "WHO provides evidence-based recommendations for activity and sedentary behaviour across children, adolescents, adults, older adults, pregnancy/postpartum, chronic conditions, and disability.",
    claims: [
      "Some physical activity is better than none across population groups.",
      "Muscle strengthening benefits everyone, with activity type and dose adapted to ability and context.",
      "Sedentary time should be limited across age groups.",
    ],
    safetyBoundaries: [
      "Use WHO guidance as a public-health baseline, not an individualized medical prescription.",
      "When a user has symptoms, disease-specific restrictions, pregnancy complications, or disability-specific needs, ask for clinician constraints and keep recommendations conservative.",
    ],
  },
  {
    entryId: "cdc_older_adults_activity_2025",
    title: "Older adults physical activity mix",
    sourceName: "CDC",
    sourceUrl: "https://www.cdc.gov/physical-activity-basics/adding-older-adults/what-counts.html",
    sourceType: "government_guideline",
    reviewedAt: "2026-05-11T00:00:00.000Z",
    tags: ["older_adults", "balance", "strength", "aerobic", "fall_prevention"],
    appliesTo: ["older_adult"],
    summary:
      "Older adults benefit from a weekly mix of aerobic activity, muscle strengthening, and balance work, scaled to ability.",
    claims: [
      "Older adults should include aerobic, muscle-strengthening, and balance activities when able.",
      "Balance work is an important addition for older adults because of fall-risk and function concerns.",
    ],
    safetyBoundaries: [
      "Avoid aggressive progression for users with fall risk, dizziness, frailty, or unresolved pain.",
      "Escalate to clinician guidance when symptoms or conditions make activity selection uncertain.",
    ],
  },
  {
    entryId: "cdc_pregnant_postpartum_activity_2026",
    title: "Physical activity for healthy pregnant and postpartum women",
    sourceName: "CDC",
    sourceUrl:
      "https://www.cdc.gov/physical-activity-basics/guidelines/healthy-pregnant-or-postpartum-women.html",
    sourceType: "government_guideline",
    reviewedAt: "2026-05-11T00:00:00.000Z",
    tags: ["pregnancy", "postpartum", "moderate_intensity", "population_specific"],
    appliesTo: ["pregnant", "postpartum"],
    summary:
      "For healthy pregnant and postpartum women, moderate-intensity physical activity can be appropriate, but MYO must treat pregnancy/postpartum status as a safety context and avoid individualized medical advice.",
    claims: [
      "Healthy pregnant and postpartum women can generally do moderate-intensity physical activity.",
      "Users already doing vigorous activity may often continue during and after pregnancy, but individual clearance and symptoms matter.",
    ],
    safetyBoundaries: [
      "Ask whether the user's clinician has given any activity restrictions before modifying training.",
      "Escalate to clinician guidance for pain, bleeding, dizziness, chest symptoms, severe shortness of breath, contractions, fluid leakage, or any concerning symptom.",
      "Do not create pregnancy-specific programming as medical advice; make conservative, reviewable suggestions only.",
    ],
  },
  {
    entryId: "cdc_chronic_conditions_disabilities_activity_2025",
    title: "Physical activity for chronic conditions and disabilities",
    sourceName: "CDC",
    sourceUrl:
      "https://www.cdc.gov/physical-activity-basics/guidelines/chronic-health-conditions-and-disabilities.html",
    sourceType: "government_guideline",
    reviewedAt: "2026-05-11T00:00:00.000Z",
    tags: ["chronic_conditions", "disability", "diabetes", "arthritis", "hypertension", "accessibility"],
    appliesTo: ["adult", "chronic_condition", "disability"],
    summary:
      "Adults with chronic conditions or disabilities can benefit from physical activity, but activity type and amount should be adapted to ability and professional guidance.",
    claims: [
      "Adults with chronic conditions or disabilities should avoid inactivity and be as active as they are able.",
      "When able, the broad baseline is aerobic activity plus muscle-strengthening activities involving major muscle groups.",
    ],
    safetyBoundaries: [
      "Do not infer safe exercise types for a specific disability or chronic condition without user-stated constraints or clinician guidance.",
      "Ask what restrictions or professional guidance the user has received before adapting a plan around a chronic condition.",
    ],
  },
  {
    entryId: "ada_physical_activity_diabetes_2016",
    title: "Physical activity and exercise with diabetes",
    sourceName: "American Diabetes Association",
    sourceUrl: "https://pubmed.ncbi.nlm.nih.gov/27926890/",
    sourceType: "medical_society_guideline",
    reviewedAt: "2026-05-11T00:00:00.000Z",
    tags: ["diabetes", "prediabetes", "glucose", "aerobic", "resistance_training", "chronic_conditions"],
    appliesTo: ["adult", "diabetes", "prediabetes", "chronic_condition"],
    summary:
      "ADA guidance supports physical activity as important for diabetes management, with attention to complications, glucose context, medications, and clinician guidance.",
    claims: [
      "Both aerobic and resistance training can be relevant for people with diabetes, depending on context.",
      "Exercise planning should account for diabetes complications and safety constraints.",
    ],
    safetyBoundaries: [
      "MYO must not provide insulin, medication, or blood-glucose treatment instructions.",
      "Escalate to clinician guidance for hypoglycemia risk, complications, medication questions, or symptoms.",
    ],
  },
  {
    entryId: "acsm_resistance_training_healthy_adults_2026",
    title: "Resistance training prescription for healthy adults",
    sourceName: "American College of Sports Medicine",
    sourceUrl: "https://acsm.org/effective-resistance-training-program-infographic/",
    sourceType: "medical_society_guideline",
    reviewedAt: "2026-05-11T00:00:00.000Z",
    tags: [
      "resistance_training",
      "strength",
      "hypertrophy",
      "power",
      "progression",
      "adult",
      "muscle_gain",
    ],
    appliesTo: ["adult", "healthy_adult"],
    summary:
      "ACSM's 2026 resistance-training guidance emphasizes consistency, goal-specific loading/volume, personalization, and simple progression for healthy adults.",
    claims: [
      "The largest practical gain often comes from moving from no resistance training to consistent resistance training.",
      "Strength emphasis generally uses heavier loads; hypertrophy emphasizes adequate weekly volume; power emphasizes moving appropriate loads quickly.",
      "The best plan must fit the user's schedule, comfort, goals, and adherence constraints.",
    ],
    safetyBoundaries: [
      "This applies to healthy adults; do not apply aggressive loading to pain, pregnancy, frailty, uncontrolled chronic conditions, or minors.",
      "Use as a planning guide, not a competition-prep protocol.",
    ],
  },
  {
    entryId: "issn_protein_exercise_2017",
    title: "Protein and exercise position stand",
    sourceName: "International Society of Sports Nutrition",
    sourceUrl: "https://jissn.biomedcentral.com/articles/10.1186/s12970-017-0177-8",
    sourceType: "medical_society_guideline",
    reviewedAt: "2026-05-11T00:00:00.000Z",
    tags: ["protein", "nutrition", "muscle_gain", "resistance_training", "recovery"],
    appliesTo: ["adult", "exercising_individual"],
    summary:
      "ISSN's position stand supports higher protein intake ranges for exercising people seeking training adaptations, while total context and safety matter.",
    claims: [
      "For many exercising individuals, roughly 1.4-2.0 g/kg/day protein is a common evidence-based range for supporting training adaptations.",
      "Protein targets should be adjusted for total energy intake, goals, preferences, and medical constraints.",
    ],
    safetyBoundaries: [
      "Do not prescribe high-protein targets for kidney disease, eating disorder concerns, minors, pregnancy, or medical conditions without professional guidance.",
      "Frame protein as a range and estimate, not a medical diet prescription.",
    ],
  },
  {
    entryId: "issn_female_athlete_nutrition_2023",
    title: "Nutritional concerns of the female athlete",
    sourceName: "International Society of Sports Nutrition",
    sourceUrl: "https://www.tandfonline.com/doi/abs/10.1080/15502783.2023.2204066",
    sourceType: "medical_society_guideline",
    reviewedAt: "2026-05-11T00:00:00.000Z",
    tags: [
      "female_athlete",
      "energy_availability",
      "menstrual_function",
      "menopause",
      "protein",
      "nutrition",
      "recovery",
    ],
    appliesTo: ["adult", "female", "athlete"],
    summary:
      "ISSN highlights energy availability, menstrual function, hormonal context, menopause, protein distribution, recovery, and underrepresentation of women in sports science.",
    claims: [
      "Adequate energy availability is a primary nutrition concern for female athletes.",
      "Female users may need context-aware nutrition and recovery guardrails rather than aggressive deficit-first planning.",
    ],
    safetyBoundaries: [
      "Do not infer menstrual status, pregnancy, menopause, or energy availability from sex/gender alone.",
      "Ask user-stated context and escalate for disordered eating signs, amenorrhea, pregnancy concerns, or medical symptoms.",
    ],
  },
  {
    entryId: "acog_exercise_pregnancy_faq_2026",
    title: "Exercise during pregnancy FAQ",
    sourceName: "American College of Obstetricians and Gynecologists",
    sourceUrl: "https://www.acog.org/womens-health/faqs/exercise-during-pregnancy",
    sourceType: "medical_society_guideline",
    reviewedAt: "2026-05-11T00:00:00.000Z",
    tags: ["pregnancy", "postpartum", "symptom_escalation", "clinician"],
    appliesTo: ["pregnant", "postpartum"],
    summary:
      "ACOG frames exercise as generally safe in healthy, normal pregnancies while emphasizing warning signs and clinician-specific restrictions.",
    claims: [
      "If pregnancy is healthy and normal, continuing or starting regular physical activity is generally safe.",
      "The user should follow clinician restrictions when present.",
    ],
    safetyBoundaries: [
      "For pregnancy/postpartum concerns, avoid diagnosis and avoid high-intensity prescriptions.",
      "If warning signs are reported, stop exercise guidance and direct the user to contact their obstetric care team or emergency care as appropriate.",
    ],
  },
  {
    entryId: "myo_readiness_low_recovery_v1",
    title: "Low-readiness workout adaptation rule",
    sourceName: "MYO internal reviewed coaching note",
    sourceType: "expert_reviewed_note",
    reviewedAt: "2026-05-11T00:00:00.000Z",
    tags: ["hungover", "sleep", "soreness", "low_readiness", "recovery", "less_time"],
    appliesTo: ["adult", "general_population"],
    summary:
      "When a user reports low readiness, poor sleep, a hangover, or unusual fatigue, MYO should favor conservative adaptations over intensity escalation.",
    claims: [
      "Prefer reducing load, sets, intensity, or impact before adding work.",
      "A short easy session, mobility session, walk, or full rest can be a valid plan-preserving adaptation.",
    ],
    safetyBoundaries: [
      "Escalate if the user reports fainting, chest pain, severe dehydration, confusion, vomiting that prevents hydration, or severe symptoms.",
      "Do not normalize training hard through acute illness or dangerous symptoms.",
    ],
  },
  {
    entryId: "myo_pain_injury_adjustment_v1",
    title: "Pain and injury workout adjustment rule",
    sourceName: "MYO internal reviewed coaching note",
    sourceType: "expert_reviewed_note",
    reviewedAt: "2026-05-11T00:00:00.000Z",
    tags: ["pain", "injury", "ankle", "knee", "shoulder", "back", "safety"],
    appliesTo: ["adult", "general_population"],
    summary:
      "Pain or injury reports should trigger safety-first follow-up and plan proposals that avoid loading the painful area until the situation is clearer.",
    claims: [
      "For localized pain, avoid exercises that reproduce or worsen symptoms.",
      "A safe response asks for basic context, offers conservative substitutions, and recommends clinician review for concerning or persistent symptoms.",
    ],
    safetyBoundaries: [
      "Do not diagnose, name a specific injury, prescribe rehab protocols, or promise recovery timelines.",
      "Escalate for severe pain, inability to bear weight, deformity, swelling after trauma, numbness, chest symptoms, neurological symptoms, or worsening symptoms.",
    ],
  },
  {
    entryId: "myo_schedule_disruption_v1",
    title: "Schedule disruption and missed workout adaptation rule",
    sourceName: "MYO internal reviewed coaching note",
    sourceType: "expert_reviewed_note",
    reviewedAt: "2026-05-11T00:00:00.000Z",
    tags: ["skip", "missed_workout", "travel", "less_time", "schedule"],
    appliesTo: ["adult", "general_population"],
    summary:
      "When a user misses, skips, travels, or has less time, the coach should preserve the weekly intent without cramming unsafe volume into the remaining days.",
    claims: [
      "Do not automatically double the next workout after a missed session.",
      "Prefer rescheduling, shortening, or prioritizing the highest-value movements for the user's current goal.",
    ],
    safetyBoundaries: [
      "Avoid turning missed workouts into punishment.",
      "Do not increase weekly intensity or volume without considering recovery and schedule.",
    ],
  },
] satisfies ResearchCorpusEntry[];

export function retrieveResearchCorpus(input: {
  userContent: string;
  profile?: Record<string, unknown> | null;
  maxEntries?: number;
}): RetrievedCorpusEntry[] {
  const queryText = [
    input.userContent,
    profileTerms(input.profile),
  ]
    .join(" ")
    .toLowerCase();

  const scored = RESEARCH_CORPUS.map((entry) => {
    const matchReasons: string[] = [];
    let score = 0;

    for (const tag of entry.tags) {
      const normalized = tag.replace(/_/g, " ").toLowerCase();
      if (queryText.includes(normalized) || queryText.includes(tag.toLowerCase())) {
        score += 3;
        matchReasons.push(`tag:${tag}`);
      }
    }

    for (const [term, reason] of KEYWORD_REASONS) {
      if (queryText.includes(term)) {
        score += reason.includes("pregnancy") || reason.includes("injury") ? 5 : 2;
        matchReasons.push(reason);
      }
    }

    if (entry.entryId === "pag_adults_strength_aerobic_2018") {
      score += 1;
      matchReasons.push("baseline");
    }

    return { entry, score, matchReasons: [...new Set(matchReasons)] };
  })
    .filter((item) => item.score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, input.maxEntries ?? 4);

  return scored.map(({ entry, matchReasons }) => ({
    entryId: entry.entryId,
    title: entry.title,
    sourceName: entry.sourceName,
    sourceUrl: entry.sourceUrl,
    sourceType: entry.sourceType,
    reviewedAt: entry.reviewedAt,
    tags: entry.tags,
    appliesTo: entry.appliesTo,
    summary: entry.summary,
    claims: entry.claims,
    safetyBoundaries: entry.safetyBoundaries,
    matchReasons,
  }));
}

function profileTerms(profile: Record<string, unknown> | null | undefined) {
  if (!profile) return "";
  const fields = [
    profile.sexOrGender,
    profile.sexOrGenderSelfDescription,
    profile.trainingExperience,
    ...(Array.isArray(profile.injuriesOrLimitations) ? profile.injuriesOrLimitations : []),
    ...(Array.isArray(profile.goals) ? profile.goals : []),
  ];
  return fields.filter((value): value is string => typeof value === "string").join(" ");
}

const KEYWORD_REASONS: Array<[string, string]> = [
  ["pregnant", "pregnancy_or_postpartum"],
  ["pregnancy", "pregnancy_or_postpartum"],
  ["postpartum", "pregnancy_or_postpartum"],
  ["older", "older_adult"],
  ["senior", "older_adult"],
  ["65", "older_adult"],
  ["balance", "older_adult_balance"],
  ["fall", "older_adult_balance"],
  ["diabetes", "chronic_condition"],
  ["prediabetes", "chronic_condition"],
  ["glucose", "chronic_condition"],
  ["arthritis", "chronic_condition"],
  ["hypertension", "chronic_condition"],
  ["disabled", "disability"],
  ["disability", "disability"],
  ["female", "female_context"],
  ["woman", "female_context"],
  ["women", "female_context"],
  ["menopause", "female_context"],
  ["menstrual", "female_context"],
  ["protein", "nutrition_protein"],
  ["ankle", "injury_or_pain"],
  ["knee", "injury_or_pain"],
  ["shoulder", "injury_or_pain"],
  ["back", "injury_or_pain"],
  ["hurt", "injury_or_pain"],
  ["pain", "injury_or_pain"],
  ["injury", "injury_or_pain"],
  ["hungover", "low_readiness"],
  ["hangover", "low_readiness"],
  ["tired", "low_readiness"],
  ["sore", "low_readiness"],
  ["sleep", "low_readiness"],
  ["less time", "schedule_or_time_constraint"],
  ["shorten", "schedule_or_time_constraint"],
  ["skip", "schedule_or_time_constraint"],
  ["missed", "schedule_or_time_constraint"],
  ["travel", "schedule_or_time_constraint"],
  ["yoga", "style_preference"],
  ["mobility", "style_preference"],
  ["muscle", "resistance_training_goal"],
  ["strength", "resistance_training_goal"],
  ["hypertrophy", "resistance_training_goal"],
  ["ripped", "resistance_training_goal"],
];
