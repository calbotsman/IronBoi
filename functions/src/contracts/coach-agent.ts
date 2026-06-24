import { z } from "zod";

export const ISODateTime = z.string().datetime();

export const SexOrGender = z.enum([
  "female",
  "male",
  "non_binary",
  "prefer_not_to_say",
  "self_described",
]);

export const TrainingExperience = z.enum([
  "new",
  "beginner",
  "intermediate",
  "advanced",
]);

export const TrainingFocus = z.enum([
  "myo_recommended",
  "muscle_split",
  "full_body",
  "strength_conditioning",
  "mobility_recovery",
  "endurance_conditioning",
]);

export const GoalType = z.enum([
  "strength",
  "muscle_gain",
  "fat_loss",
  "general_fitness",
  "mobility",
  "endurance",
  "habit_building",
  "return_to_training",
]);

// Explanatory "lens" the user can pick so the coach frames its EXPLANATIONS
// through a credible authority's emphasis. Per docs/design/myo-personas-*
// (Rowan's call): lenses are "ways to understand your training," not
// celebrity worship, and they never override safety or corpus grounding.
// Kept to the audited top three (Mercer dossier) plus "none".
export const CoachingLens = z.enum([
  "none",
  "huberman", // recovery, circadian, nervous-system framing
  "schoenfeld", // hypertrophy mechanics: tension, volume, progression
  "sims", // female-physiology and cycle-aware framing
  "blueprint", // measurement-driven longevity, consistency (Bryan Johnson)
]);

export const DataCategory = z.enum([
  "profile",
  "coach_memory",
  "workout_logs",
  "manual_metrics",
  "healthkit_steps",
  "healthkit_workouts",
  "healthkit_active_energy",
  "healthkit_resting_heart_rate",
  "healthkit_sleep",
  "healthkit_body_weight",
  "healthkit_hrv",
  "conversation_history",
]);

export const RiskLevel = z.enum(["low", "medium", "high", "blocked"]);
export const CoachInputMode = z.enum(["text", "tap", "dictation", "live_voice"]);
export const OnboardingStatus = z.enum([
  "not_started",
  "collecting",
  "proposal_ready",
  "complete",
]);
export const PlanAdjustmentCategory = z.enum([
  "time_limit",
  "equipment_limit",
  "skip_or_reschedule",
  "readiness_low",
  "style_preference",
  "injury_pain",
  "pregnancy_postpartum",
  "travel",
  "nutrition_context",
  "other",
]);
export const PlanAdjustmentDecision = z.enum([
  "pending",
  "accepted",
  "rejected",
  "edited",
]);

export const CoachAgentContract = z.object({
  id: z.literal("myo_coach"),
  version: z.string().min(1),
  identity: z.object({
    displayName: z.literal("MYO Coach"),
    role: z.string().min(1),
    productBoundary: z.literal("general_wellness_fitness"),
    notFor: z.array(z.string()).default([
      "diagnosis",
      "disease treatment",
      "emergency handling",
      "clinical decision support",
      "rehabilitation protocols without review",
    ]),
  }),
  soul: z.object({
    coachingPhilosophy: z.string().min(1),
    motivationalStyle: z.string().min(1),
    refusalStyle: z.string().min(1),
  }),
  brain: z.object({
    planningPrinciples: z.array(z.string()).min(1),
    memoryUseRules: z.array(z.string()).min(1),
    uncertaintyRules: z.array(z.string()).min(1),
  }),
  safetyPolicy: z.object({
    emergencyEscalation: z.string().min(1),
    medicalBoundary: z.string().min(1),
    blockedTopics: z.array(z.string()).min(1),
    clinicianEscalationTriggers: z.array(z.string()).min(1),
    populationAwareInputs: z.array(z.string()).min(1),
  }),
  memoryPolicy: z.object({
    userInspectable: z.literal(true),
    userEditable: z.literal(true),
    userDeletable: z.literal(true),
    defaultRetention: z.string().min(1),
    writeRequiresSource: z.literal(true),
    noCrossUserRetrieval: z.literal(true),
  }),
  retrievalPolicy: z.object({
    corpusRequiredFor: z.array(z.string()).min(1),
    allowedWithoutCorpus: z.array(z.string()).min(1),
    citationMode: z.enum(["internal", "user_visible_when_helpful"]),
    staleCorpusBehavior: z.enum(["answer_generic_only", "refuse"]),
  }),
  toolRegistry: z.array(z.string()).min(1),
  responseContract: z.object({
    defaultFormat: z.literal("coach_response_v1"),
    supportsToolCards: z.literal(true),
    requiresSafetyLabelForHighRisk: z.literal(true),
  }),
}).strict();

export const UserHealthProfile = z.object({
  userId: z.string().min(1),
  ageYears: z.number().int().min(13).max(120),
  sexOrGender: SexOrGender,
  sexOrGenderSelfDescription: z.string().optional(),
  heightCm: z.number().positive().optional(),
  weightKg: z.number().positive().optional(),
  goals: z.array(GoalType).min(1),
  goalNotes: z.string().optional(),
  trainingExperience: TrainingExperience,
  injuriesOrLimitations: z.array(z.string()).default([]),
  equipment: z.array(z.string()).default([]),
  schedule: z.object({
    daysPerWeek: z.number().int().min(1).max(7).optional(),
    preferredDays: z.array(z.string()).default([]),
    sessionLengthMin: z.number().int().positive().optional(),
  }).strict(),
  preferences: z.object({
    coachingTone: z.enum(["direct", "warm", "balanced"]).default("balanced"),
    preferredWorkoutTime: z.enum(["morning", "afternoon", "evening", "flexible"]).default("flexible"),
    dislikedExercises: z.array(z.string()).default([]),
    trainingFocus: TrainingFocus.default("myo_recommended"),
    coachingLens: CoachingLens.default("none"),
  }).strict(),
  dietaryConstraints: z.array(z.string()).default([]),
  onboardingStatus: OnboardingStatus.default("complete"),
  onboardingStep: z.string().optional(),
  onboardingMissingFields: z.array(z.string()).default([]),
  createdAt: ISODateTime,
  updatedAt: ISODateTime,
}).strict();

// Phase 2 Task 2.3 — Memory proposal queue.
// Coach-inferred facts default to "proposed" and don't enter the prompt
// until confirmed (either by user_stated source on upsert, or by an
// explicit confirmMemoryFact call). "rejected" is reserved for future
// user-rejection UI; today the alternative is deleteMemoryFact.
export const CoachMemoryFactState = z.enum([
  "proposed",
  "confirmed",
  "rejected",
]);

export const CoachMemoryFact = z.object({
  userId: z.string().min(1),
  factId: z.string().min(1),
  category: z.enum([
    "preference",
    "constraint",
    "adherence_pattern",
    "exercise_response",
    "motivation",
    "schedule",
    "equipment",
    "safety_note",
  ]),
  content: z.string().min(1),
  source: z.enum([
    "user_stated",
    "coach_inferred",
    "log_derived",
    "healthkit_derived",
  ]),
  confidence: z.number().min(0).max(1),
  // Phase 2 Task 2.3 — proposal queue fields.
  // `state` is optional in the contract to keep client callers backward
  // compatible; the server upsert decides the final state based on `source`.
  state: CoachMemoryFactState.optional(),
  sourceMessageId: z.string().optional(),
  evidenceExcerpt: z.string().max(500).optional(),
  expiresAt: ISODateTime.optional(),
  lastConfirmedAt: ISODateTime.optional(),
  createdAt: ISODateTime,
  lastReinforcedAt: ISODateTime.optional(),
  userEditable: z.literal(true),
  userDeletedAt: ISODateTime.optional(),
}).strict();

export const WorkoutLog = z.object({
  userId: z.string().min(1),
  sessionId: z.string().min(1),
  date: z.string().date(),
  source: z.enum(["manual", "healthkit_import", "coach_generated"]),
  exercises: z
    .array(
      z.object({
        name: z.string().min(1),
        sets: z
          .array(
            z.object({
              reps: z.number().int().nonnegative().optional(),
              loadKg: z.number().nonnegative().optional(),
              durationSec: z.number().int().nonnegative().optional(),
              distanceM: z.number().nonnegative().optional(),
              rpe: z.number().min(1).max(10).optional(),
              notes: z.string().optional(),
            }).strict(),
          )
          .default([]),
      }).strict(),
    )
    .default([]),
  durationSec: z.number().int().nonnegative().optional(),
  perceivedEffort: z.number().min(1).max(10).optional(),
  postSessionNotes: z.string().optional(),
  createdAt: ISODateTime,
}).strict();

export const PlannedExercise = z.object({
  name: z.string().min(1),
  sets: z.number().int().nonnegative(),
  reps: z.number().int().nonnegative(),
  weight: z.number().nonnegative().default(0),
}).strict();

export const PlannedWorkoutDay = z.object({
  name: z.string().min(1),
  muscles: z.array(z.string()).default([]),
  exercises: z.array(PlannedExercise).default([]),
}).strict();

export const ActiveWorkoutSet = z.object({
  setIndex: z.number().int().nonnegative(),
  completed: z.boolean().default(false),
  reps: z.number().int().nonnegative().optional(),
  weight: z.number().nonnegative().optional(),
}).strict();

export const ActiveWorkoutExercise = z.object({
  exerciseIndex: z.number().int().nonnegative(),
  name: z.string().min(1),
  targetSets: z.number().int().nonnegative(),
  targetReps: z.number().int().nonnegative(),
  targetWeight: z.number().nonnegative().default(0),
  completedSets: z.array(ActiveWorkoutSet).default([]),
  exerciseDone: z.boolean().default(false),
  notes: z.string().optional(),
}).strict();

export const ActiveWorkoutSession = z.object({
  userId: z.string().min(1),
  sessionId: z.string().min(1),
  planId: z.string().min(1).default("current"),
  dayKey: z.string().min(1),
  workoutName: z.string().min(1),
  status: z.enum(["active", "completed", "abandoned"]).default("active"),
  startedAt: ISODateTime,
  updatedAt: ISODateTime,
  completedAt: ISODateTime.optional(),
  exercises: z.array(ActiveWorkoutExercise).default([]),
}).strict();

export const WorkoutPlan = z.object({
  userId: z.string().min(1),
  planId: z.string().min(1),
  source: z.enum(["legacy_pwa", "coach_generated", "user_edited"]),
  days: z.record(z.string(), PlannedWorkoutDay),
  updatedAt: ISODateTime,
}).strict();

export const DailyCheck = z.object({
  userId: z.string().min(1),
  date: z.string().date(),
  checks: z.record(z.string(), z.boolean()),
  updatedAt: ISODateTime,
}).strict();

export const MetricSnapshot = z.object({
  userId: z.string().min(1),
  snapshotId: z.string().min(1),
  capturedAt: ISODateTime,
  source: z.enum(["manual", "healthkit"]),
  metrics: z.object({
    steps: z.number().int().nonnegative().optional(),
    activeEnergyKcal: z.number().nonnegative().optional(),
    restingHeartRateBpm: z.number().positive().optional(),
    sleepDurationMin: z.number().nonnegative().optional(),
    bodyWeightKg: z.number().positive().optional(),
    hrvMs: z.number().positive().optional(),
  }).strict(),
  interpretationPolicy: z.literal("context_only_not_deterministic"),
}).strict();

// Phase 2 Task 2.4 — HealthKit ingestion at event-sample granularity.
//
// Per audit D7: replaces the lossy "one MetricSnapshot doc per day" pattern
// for HealthKit data. Each iOS HealthKit sample lands at
// users/{uid}/healthSamples/{sampleHash} with full provenance. Daily roll-
// ups will land in users/{uid}/derivedSummaries/ as healthContext_{date}
// docs once the rollup function ships (separate follow-up).
//
// MetricSnapshot stays for manual entries (weigh-ins typed in by hand).

export const HealthSampleCategory = z.enum([
  "steps",
  "active_energy_kcal",
  "resting_heart_rate_bpm",
  "sleep_duration_min",
  "body_weight_kg",
  "hrv_ms",
  "workout",
]);

// `sampleHash` is the document ID. iOS must compute it deterministically
// from {category, startDate, endDate, sourceBundleId, deviceUUID, value}
// so re-ingesting the same HealthKit sample is idempotent. Length ≥ 12
// (hex) keeps collisions negligible at expected sample volumes.
export const HealthSample = z.object({
  userId: z.string().min(1),
  category: HealthSampleCategory,
  value: z.number(),
  unit: z.string().min(1),
  startDate: ISODateTime,
  endDate: ISODateTime,
  sourceBundleId: z.string().optional(),
  deviceUUID: z.string().optional(),
  sampleHash: z.string().min(12),
  ingestedAt: ISODateTime,
}).strict();

// Client sends samples without userId/ingestedAt — server injects both.
export const IngestHealthSampleInput = HealthSample.omit({
  userId: true,
  ingestedAt: true,
}).strict();

export const IngestHealthSamplesRequest = z.object({
  samples: z.array(IngestHealthSampleInput).min(1).max(500),
}).strict();

export const IngestHealthSamplesResult = z.object({
  inserted: z.number().int().nonnegative(),
  duplicates: z.number().int().nonnegative(),
  rejectedNoConsent: z.array(z.string()).default([]),
}).strict();

// Daily rollup shape. Builder is a separate follow-up; defining the type
// now so callers (coach context bundle, etc.) can take a dependency.
export const DerivedHealthContext = z.object({
  userId: z.string().min(1),
  date: z.string().date(),
  totals: z.object({
    steps: z.number().nonnegative().optional(),
    activeEnergyKcal: z.number().nonnegative().optional(),
    sleepMinutes: z.number().nonnegative().optional(),
    workoutCount: z.number().int().nonnegative().optional(),
  }).strict(),
  ranges: z.object({
    restingHeartRateBpm: z.object({
      min: z.number(),
      max: z.number(),
      avg: z.number(),
    }).strict().optional(),
    hrvMs: z.object({
      min: z.number(),
      max: z.number(),
      avg: z.number(),
    }).strict().optional(),
    bodyWeightKg: z.object({
      min: z.number(),
      max: z.number(),
      avg: z.number(),
    }).strict().optional(),
  }).strict(),
  sampleCount: z.number().int().nonnegative(),
  updatedAt: ISODateTime,
}).strict();

// Phase 3 Task 3.4 — Audit log for sensitive writes.
//
// Records WHAT happened (eventType + actor) and WHEN, never WHAT VALUE. The
// audit log is for "did the user grant consent on X date" type questions —
// not for replaying values, which would leak PII into a log surface.
//
// payloadHash is a 16-char prefix of sha256(JSON(payload)). Enough to detect
// "two events refer to the same payload" without exposing the payload itself.

export const AuditEventType = z.enum([
  "memory_fact_written",
  "memory_fact_confirmed",
  "memory_fact_deleted",
  "consent_granted",
  "consent_revoked",
  "health_samples_ingested",
  "daily_spend_cap_reached",
  "account_deletion_requested",
]);

export const AuditActor = z.enum(["user", "coach", "system"]);

export const AuditEvent = z.object({
  eventId: z.string().min(1),
  eventType: AuditEventType,
  actor: AuditActor,
  timestamp: ISODateTime,
  payloadHash: z.string().optional(),
  // Correlates audit events back to the coach turn that produced them.
  turnId: z.string().optional(),
  // Lets a multi-step user action (e.g. consent grant + healthkit init)
  // get grouped under one ID for later review.
  correlationId: z.string().optional(),
}).strict();

export const ConsentRecord = z.object({
  userId: z.string().min(1),
  recordId: z.string().min(1),
  category: DataCategory,
  purpose: z.string().min(1),
  granted: z.boolean(),
  grantedAt: ISODateTime.optional(),
  revokedAt: ISODateTime.optional(),
  scope: z.object({
    read: z.boolean().default(false),
    write: z.boolean().default(false),
    share: z.boolean().default(false),
    retrieval: z.boolean().default(false),
  }).strict(),
  policyVersion: z.string().min(1),
}).strict();

export const CoachMessage = z.object({
  messageId: z.string().min(1),
  role: z.enum(["user", "coach", "tool", "system"]),
  content: z.string(),
  timestamp: ISODateTime,
  riskLevel: RiskLevel.optional(),
  inputMode: CoachInputMode.optional(),
  structuredAnswer: z.record(z.string(), z.unknown()).optional(),
  turnId: z.string().optional(),
  toolCallIds: z.array(z.string()).default([]),
}).strict();

export const ResearchCorpusEntry = z.object({
  entryId: z.string().min(1),
  title: z.string().min(1),
  sourceName: z.string().min(1),
  sourceUrl: z.string().url().optional(),
  sourceType: z.enum([
    "government_guideline",
    "medical_society_guideline",
    "internal_domain_seed",
    "expert_reviewed_note",
  ]),
  reviewedAt: ISODateTime,
  tags: z.array(z.string()).default([]),
  appliesTo: z.array(z.string()).default([]),
  summary: z.string().min(1),
  claims: z.array(z.string()).default([]),
  safetyBoundaries: z.array(z.string()).default([]),
  staleAfter: ISODateTime.optional(),
}).strict();

export const NutritionTargets = z.object({
  calories: z
    .object({
      min: z.number().int().positive(),
      max: z.number().int().positive(),
      note: z.string().min(1),
    }).strict()
    .optional(),
  proteinGrams: z.object({
    min: z.number().int().positive(),
    max: z.number().int().positive(),
  }).strict(),
  assumptions: z.array(z.string()).default([]),
  safetyNotes: z.array(z.string()).default([]),
}).strict();

export const ProgramProposal = z.object({
  userId: z.string().min(1),
  proposalId: z.string().min(1),
  source: z.literal("onboarding"),
  decision: z.enum(["pending", "accepted", "rejected", "edited"]).default("pending"),
  profile: UserHealthProfile,
  workoutPlan: WorkoutPlan,
  nutritionTargets: NutritionTargets,
  createdAt: ISODateTime,
  decidedAt: ISODateTime.optional(),
}).strict();

export const PlanAdjustmentProposal = z.object({
  userId: z.string().min(1),
  proposalId: z.string().min(1),
  source: z.enum(["coach_chat", "workout_detail", "system"]),
  decision: PlanAdjustmentDecision.default("pending"),
  category: PlanAdjustmentCategory,
  riskLevel: RiskLevel,
  originalUserText: z.string().min(1),
  summary: z.string().min(1),
  rationale: z.string().min(1),
  appliesTo: z.object({
    planId: z.string().min(1).default("current"),
    dayKey: z.string().min(1).optional(),
    exerciseName: z.string().min(1).optional(),
  }).strict(),
  proposedPlanPatch: z.object({
    type: z.enum([
      "review_only",
      "modify_exercise",
      "replace_exercise",
      "shorten_workout",
      "reschedule_day",
      "replace_day_focus",
    ]),
    title: z.string().min(1),
    changes: z.array(z.string().min(1)).default([]),
    replacementDay: PlannedWorkoutDay.optional(),
  }).strict(),
  sourceCorpusEntryIds: z.array(z.string()).default([]),
  safetyNotes: z.array(z.string()).default([]),
  requiresFollowUp: z.boolean().default(false),
  structuredAnswer: z.record(z.string(), z.unknown()).optional(),
  createdAt: ISODateTime,
  decidedAt: ISODateTime.optional(),
}).strict();

export const CoachSession = z.object({
  userId: z.string().min(1),
  sessionId: z.string().min(1),
  startedAt: ISODateTime,
  endedAt: ISODateTime.optional(),
  messages: z.array(CoachMessage).default([]),
  outcome: z
    .enum(["active", "completed", "abandoned", "blocked_by_safety"])
    .default("active"),
}).strict();

export const CoachResponse = z.object({
  responseId: z.string().min(1),
  userId: z.string().min(1),
  sessionId: z.string().min(1),
  format: z.literal("coach_response_v1"),
  message: z.string(),
  riskLevel: RiskLevel.default("low"),
  toolCards: z
    .array(
      z.object({
        type: z.enum([
          "planned_workout",
          "workout_logged",
          "progress_summary",
          "follow_up_question",
          "safety_notice",
        ]),
        title: z.string().min(1),
        body: z.string().optional(),
        payload: z.record(z.string(), z.unknown()).default({}),
      }).strict(),
    )
    .default([]),
  memoryWriteCandidates: z.array(CoachMemoryFact).default([]),
  corpusEntryIds: z.array(z.string()).default([]),
  requiredUserAction: z
    .enum([
      "none",
      "answer_follow_up",
      "grant_consent",
      "seek_clinician",
      "contact_emergency_services",
    ])
    .default("none"),
}).strict();

export type CoachAgentContract = z.infer<typeof CoachAgentContract>;
export type UserHealthProfile = z.infer<typeof UserHealthProfile>;
export type CoachMemoryFact = z.infer<typeof CoachMemoryFact>;
export type ActiveWorkoutExercise = z.infer<typeof ActiveWorkoutExercise>;
export type ActiveWorkoutSession = z.infer<typeof ActiveWorkoutSession>;
export type WorkoutLog = z.infer<typeof WorkoutLog>;
export type WorkoutPlan = z.infer<typeof WorkoutPlan>;
export type DailyCheck = z.infer<typeof DailyCheck>;
export type MetricSnapshot = z.infer<typeof MetricSnapshot>;
export type ConsentRecord = z.infer<typeof ConsentRecord>;
export type CoachSession = z.infer<typeof CoachSession>;
export type CoachResponse = z.infer<typeof CoachResponse>;
export type ProgramProposal = z.infer<typeof ProgramProposal>;
export type PlanAdjustmentProposal = z.infer<typeof PlanAdjustmentProposal>;
export type ResearchCorpusEntry = z.infer<typeof ResearchCorpusEntry>;
export type HealthSampleCategory = z.infer<typeof HealthSampleCategory>;
export type HealthSample = z.infer<typeof HealthSample>;
export type IngestHealthSampleInput = z.infer<typeof IngestHealthSampleInput>;
export type IngestHealthSamplesRequest = z.infer<typeof IngestHealthSamplesRequest>;
export type IngestHealthSamplesResult = z.infer<typeof IngestHealthSamplesResult>;
export type DerivedHealthContext = z.infer<typeof DerivedHealthContext>;
export type AuditEventType = z.infer<typeof AuditEventType>;
export type AuditActor = z.infer<typeof AuditActor>;
export type AuditEvent = z.infer<typeof AuditEvent>;
