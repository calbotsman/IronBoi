import { z } from "zod";
import {
  CoachMemoryFact,
  MetricSnapshot,
  PlanAdjustmentScope,
  UserHealthProfile,
  WorkoutLog,
} from "./coach-agent.js";

export const ToolCallBase = z.object({
  toolCallId: z.string().min(1),
  requestedAt: z.string().datetime(),
}).strict();

export const ToolResultBase = z.object({
  toolCallId: z.string().min(1),
  outcome: z.enum([
    "ok",
    "validation_error",
    "blocked_by_policy",
    "not_found",
    "error",
  ]),
  message: z.string().optional(),
}).strict();

export const LogWorkoutRequest = ToolCallBase.extend({
  tool: z.literal("log_workout"),
  workout: WorkoutLog,
});

export const LogWorkoutResult = ToolResultBase.extend({
  workoutId: z.string().optional(),
  memoryCandidates: z.array(CoachMemoryFact).default([]),
});

export const ReadRecentMetricsRequest = ToolCallBase.extend({
  tool: z.literal("read_recent_metrics"),
  categories: z
    .array(
      z.enum([
        "steps",
        "active_energy",
        "resting_heart_rate",
        "sleep",
        "body_weight",
        "hrv",
      ]),
    )
    .min(1),
  lookbackDays: z.number().int().min(1).max(30),
});

export const ReadRecentMetricsResult = ToolResultBase.extend({
  snapshots: z.array(MetricSnapshot).default([]),
  missingConsentCategories: z.array(z.string()).default([]),
});

export const GeneratePlanRequest = ToolCallBase.extend({
  tool: z.literal("generate_plan"),
  profile: UserHealthProfile,
  horizonDays: z.number().int().min(1).max(28),
  constraints: z.array(z.string()).default([]),
});

export const PlannedWorkout = z.object({
  plannedWorkoutId: z.string().min(1),
  dayIndex: z.number().int().min(0),
  title: z.string().min(1),
  goal: z.string().min(1),
  estimatedDurationMin: z.number().int().positive(),
  exercises: z
    .array(
      z.object({
        name: z.string().min(1),
        prescription: z.string().min(1),
        substitutionOptions: z.array(z.string()).default([]),
        safetyNotes: z.array(z.string()).default([]),
      }).strict(),
    )
    .default([]),
}).strict();

export const GeneratePlanResult = ToolResultBase.extend({
  planId: z.string().optional(),
  workouts: z.array(PlannedWorkout).default([]),
  requiredDisclaimers: z.array(z.string()).default([]),
});

export const AdaptPlanRequest = ToolCallBase.extend({
  tool: z.literal("adapt_plan"),
  planId: z.string().min(1).default("current"),
  reason: z.enum([
    "too_hard",
    "too_easy",
    "pain_or_discomfort",
    "time_constraint",
    "equipment_unavailable",
    "schedule_change",
    "missed_session",
  ]),
  userNote: z.string().optional(),
  // Mirrors PlanAdjustmentProposal.appliesTo — dayKey defaults to today when
  // omitted (see workouts/planAdjustments.ts resolveAppliesToDayKey).
  // Enum, not free string: a model that sends "Monday" instead of "Mon"
  // would otherwise plant a junk day key the iOS renderer silently drops.
  dayKey: z.enum(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]).optional(),
  exerciseName: z.string().min(1).optional(),
  // Omit until the user has said whether they want "just today" or "going
  // forward" — the tool result flags needsScopeConfirmation when this is
  // absent so the model asks before calling again with the answer.
  scope: PlanAdjustmentScope.optional(),
  // Model-authored replacement days: concrete exercise substitutions (e.g.
  // back-safe swaps) rather than the server's mechanical trim/skip patches.
  // Hard-bounded: ≤7 days, ≤12 exercises/day, name ≤80 chars, ints/nonneg
  // enforced by PlannedExercise. Server re-validates everything.
  dayPatches: z
    .array(
      z.object({
        dayKey: z.enum(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]),
        dayName: z.string().min(1).max(60),
        replacementExercises: z
          .array(
            z.object({
              name: z.string().min(1).max(80),
              sets: z.number().int().min(1).max(8),
              reps: z.number().int().min(1).max(30),
              weight: z.number().min(0).max(600).default(0),
            }).strict()
              // Volume sanity: 8x30 bodyweight is fine; 8x30 loaded is not a
              // recovery adjustment. Bounds are a backstop — the card now
              // shows every exercise before the user approves.
              .refine((exercise) => exercise.sets * exercise.reps <= 120, {
                message: "sets x reps too high for a plan adjustment",
              }),
          )
          .min(1)
          .max(12),
      }).strict(),
    )
    .min(1)
    .max(7)
    .optional(),
  // Pain triage attestation — only meaningful for reason=pain_or_discomfort.
  // The model must have ASKED the red-flag questions in a prior exchange and
  // report what the user said. The server independently screens the text for
  // severe markers; this attestation can lower risk only when that absolute
  // screen also comes back clean.
  painTriage: z
    .object({
      redFlagsAsked: z.literal(true),
      userReportsSevere: z.boolean(),
      description: z.string().min(1).max(200),
    })
    .strict()
    .optional(),
  // Suggested recovery window (days) before the coach checks back in.
  // Clamped server-side to 3–14; defaults to 5 when omitted.
  recoveryDays: z.number().int().min(1).max(30).optional(),
});

export const AdaptPlanResult = ToolResultBase.extend({
  updatedPlanId: z.string().optional(),
  changes: z.array(z.string()).default([]),
  escalationRequired: z.boolean().default(false),
});

// Chat-driven decision on the CURRENT pending proposal ("yes, update
// training" / "no thanks"). No proposalId arg on purpose: the model never
// sees proposal ids, and letting it supply one would be an unnecessary
// model-controlled selector — the server always resolves the single most
// recent pending proposal for the authenticated user.
export const AcceptPlanAdjustmentToolRequest = ToolCallBase.extend({
  tool: z.literal("accept_plan_adjustment"),
  // Required if the proposal itself doesn't already carry a scope — the
  // user must have said "just today" or "going forward" first.
  scope: PlanAdjustmentScope.optional(),
});

export const AcceptPlanAdjustmentToolResult = ToolResultBase.extend({
  proposalId: z.string().optional(),
  appliedScope: PlanAdjustmentScope.optional(),
});

export const RejectPlanAdjustmentToolRequest = ToolCallBase.extend({
  tool: z.literal("reject_plan_adjustment"),
});

// Ramp-back-up: removes future-dated dailyOverrides so the template shows
// through again. Proposal-gated like every other mutation — this request
// shape is what the model sends; the actual delete happens on accept.
export const ClearPlanOverridesToolRequest = ToolCallBase.extend({
  tool: z.literal("clear_plan_overrides"),
  userNote: z.string().min(1).max(300),
});

export const RejectPlanAdjustmentToolResult = ToolResultBase.extend({
  proposalId: z.string().optional(),
});

export const ExplainExerciseRequest = ToolCallBase.extend({
  tool: z.literal("explain_exercise"),
  exerciseName: z.string().min(1),
  userContext: z.object({
    experience: z.string().optional(),
    limitations: z.array(z.string()).default([]),
  }).strict().optional(),
});

export const ExplainExerciseResult = ToolResultBase.extend({
  explanation: z.string().optional(),
  formCues: z.array(z.string()).default([]),
  commonMistakes: z.array(z.string()).default([]),
  contraindications: z.array(z.string()).default([]),
  corpusEntryIds: z.array(z.string()).default([]),
});

export const FlagRiskRequest = ToolCallBase.extend({
  tool: z.literal("flag_risk"),
  userText: z.string().min(1),
  detectedRisk: z.enum([
    "emergency",
    "injury_or_pain",
    "eating_disorder_adjacent",
    "unsafe_weight_loss",
    "supplement_or_drug_protocol",
    "underage",
    "prompt_injection",
  ]),
});

export const FlagRiskResult = ToolResultBase.extend({
  riskLevel: z.enum(["medium", "high", "blocked"]),
  userFacingMessage: z.string(),
  allowedNextActions: z.array(z.string()).default([]),
});

export const SummarizeProgressRequest = ToolCallBase.extend({
  tool: z.literal("summarize_progress"),
  lookbackDays: z.number().int().min(1).max(90),
});

export const SummarizeProgressResult = ToolResultBase.extend({
  summary: z.string().optional(),
  adherencePercent: z.number().min(0).max(100).optional(),
  highlights: z.array(z.string()).default([]),
  cautions: z.array(z.string()).default([]),
});

export const AskFollowUpQuestionRequest = ToolCallBase.extend({
  tool: z.literal("ask_follow_up_question"),
  reason: z.enum([
    "missing_profile",
    "ambiguous_goal",
    "possible_safety_issue",
    "plan_constraint",
    "consent_required",
  ]),
  question: z.string().min(1),
});

export const AskFollowUpQuestionResult = ToolResultBase.extend({
  renderedQuestion: z.string().optional(),
});

export const CoachToolRequest = z.discriminatedUnion("tool", [
  LogWorkoutRequest,
  ReadRecentMetricsRequest,
  GeneratePlanRequest,
  AdaptPlanRequest,
  AcceptPlanAdjustmentToolRequest,
  RejectPlanAdjustmentToolRequest,
  ClearPlanOverridesToolRequest,
  ExplainExerciseRequest,
  FlagRiskRequest,
  SummarizeProgressRequest,
  AskFollowUpQuestionRequest,
]);

export const CoachToolResult = z.union([
  LogWorkoutResult,
  ReadRecentMetricsResult,
  GeneratePlanResult,
  AdaptPlanResult,
  AcceptPlanAdjustmentToolResult,
  RejectPlanAdjustmentToolResult,
  ExplainExerciseResult,
  FlagRiskResult,
  SummarizeProgressResult,
  AskFollowUpQuestionResult,
]);

export type CoachToolRequest = z.infer<typeof CoachToolRequest>;
export type CoachToolResult = z.infer<typeof CoachToolResult>;
