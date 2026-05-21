import { randomUUID } from "node:crypto";
import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { z } from "zod";
import {
  PlanAdjustmentCategory,
  PlanAdjustmentProposal,
  RiskLevel,
} from "../contracts/coach-agent.js";
import { retrieveResearchCorpus } from "../corpus/researchCorpus.js";
import { safeLogger } from "../logging/safeLogger.js";
import { planAdjustmentProposalPath, profilePath, workoutPlanPath } from "../paths.js";

export const AcceptPlanAdjustmentProposalRequest = z.object({
  proposalId: z.string().min(1),
  decidedAt: z.string().datetime().optional(),
});

const WorkoutPlanAdjustmentStructuredAnswer = z
  .object({
    kind: z.literal("workout_plan_adjustment"),
    dayKey: z.string().min(1).optional(),
    exerciseName: z.string().min(1).optional(),
  })
  .passthrough();

type AdjustmentCategory = z.infer<typeof PlanAdjustmentCategory>;
type AdjustmentRiskLevel = z.infer<typeof RiskLevel>;

export async function maybeCreatePlanAdjustmentProposal(input: {
  db: Firestore;
  userId: string;
  content: string;
  structuredAnswer?: unknown;
}) {
  const trimmed = input.content.trim();
  if (!trimmed) return null;

  const structured = WorkoutPlanAdjustmentStructuredAnswer.safeParse(input.structuredAnswer);
  const category = classifyPlanAdjustment(trimmed, structured.success);
  if (!category) return null;

  const profileSnap = await input.db.doc(profilePath(input.userId)).get();
  const profile = profileSnap.exists ? profileSnap.data() ?? null : null;
  const retrievedCorpus = retrieveResearchCorpus({
    userContent: trimmed,
    profile,
    maxEntries: 4,
  });

  const now = new Date().toISOString();
  const proposalId = `adjustment_${randomUUID()}`;
  const riskLevel = riskForCategory(category, trimmed);
  const requiresFollowUp = needsFollowUp(category, riskLevel);
  const appliesTo = {
    planId: "current",
    ...resolveAppliesToDayKey(category, structured.success ? structured.data.dayKey : undefined),
    ...(structured.success && structured.data.exerciseName
      ? { exerciseName: structured.data.exerciseName }
      : {}),
  };

  const proposal = PlanAdjustmentProposal.parse({
    userId: input.userId,
    proposalId,
    source: structured.success ? "workout_detail" : "coach_chat",
    decision: "pending",
    category,
    riskLevel,
    originalUserText: trimmed,
    summary: summaryForCategory(category, structured.success ? structured.data.exerciseName : undefined),
    rationale: rationaleForCategory(category),
    appliesTo,
    proposedPlanPatch: patchForCategory(category, requiresFollowUp),
    sourceCorpusEntryIds: retrievedCorpus.map((entry) => entry.entryId),
    safetyNotes: safetyNotesForCategory(category, retrievedCorpus.flatMap((entry) => entry.safetyBoundaries)),
    requiresFollowUp,
    ...(structured.success ? { structuredAnswer: structured.data } : {}),
    createdAt: now,
  });

  await input.db.doc(planAdjustmentProposalPath(input.userId, proposalId)).set({
    ...proposal,
    serverCreatedAt: FieldValue.serverTimestamp(),
  });

  safeLogger.info("Plan adjustment proposal created", {
    event: "plan_adjustment_proposal_created",
    userId: input.userId,
    proposalId,
    outcome: category,
  });

  return {
    proposalId,
    category,
    riskLevel,
    requiresFollowUp,
    sourceCorpusEntryIds: proposal.sourceCorpusEntryIds,
  };
}

export async function acceptPlanAdjustmentProposal(
  db: Firestore,
  userId: string,
  request: z.infer<typeof AcceptPlanAdjustmentProposalRequest>,
) {
  const proposalRef = db.doc(planAdjustmentProposalPath(userId, request.proposalId));
  const planRef = db.doc(workoutPlanPath(userId, "current"));
  const serverDecidedAt = new Date().toISOString();

  await db.runTransaction(async (transaction) => {
    const [proposalSnap, planSnap] = await Promise.all([
      transaction.get(proposalRef),
      transaction.get(planRef),
    ]);

    if (!proposalSnap.exists) {
      throw new Error("plan_adjustment_proposal_not_found");
    }
    if (!planSnap.exists) {
      throw new Error("workout_plan_not_found");
    }

    const proposal = parsePlanAdjustmentProposalDocument(proposalSnap.data());
    if (proposal.userId !== userId) {
      throw new Error("plan_adjustment_user_mismatch");
    }
    if (proposal.decision !== "pending") {
      throw new Error("plan_adjustment_not_pending");
    }
    if (proposal.riskLevel !== "low" || proposal.requiresFollowUp) {
      throw new Error("plan_adjustment_requires_review");
    }

    const nextPlanPatch = planPatchForAcceptedProposal(proposal, planSnap.data() ?? {});
    transaction.set(
      planRef,
      {
        ...nextPlanPatch,
        source: "user_edited",
        updatedAt: serverDecidedAt,
        serverUpdatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    transaction.set(
      proposalRef,
      {
        decision: "accepted",
        decidedAt: serverDecidedAt,
        clientDecidedAt: request.decidedAt,
        serverDecidedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  });

  safeLogger.info("Plan adjustment proposal accepted", {
    event: "plan_adjustment_proposal_accepted",
    userId,
    proposalId: request.proposalId,
    outcome: "accepted",
  });

  return { ok: true, proposalId: request.proposalId, decidedAt: serverDecidedAt };
}

function parsePlanAdjustmentProposalDocument(data: FirebaseFirestore.DocumentData | undefined) {
  const raw = data ?? {};
  return PlanAdjustmentProposal.parse({
    userId: raw.userId,
    proposalId: raw.proposalId,
    source: raw.source,
    decision: raw.decision,
    category: raw.category,
    riskLevel: raw.riskLevel,
    originalUserText: raw.originalUserText,
    summary: raw.summary,
    rationale: raw.rationale,
    appliesTo: raw.appliesTo,
    proposedPlanPatch: raw.proposedPlanPatch,
    sourceCorpusEntryIds: raw.sourceCorpusEntryIds,
    safetyNotes: raw.safetyNotes,
    requiresFollowUp: raw.requiresFollowUp,
    structuredAnswer: raw.structuredAnswer,
    createdAt: raw.createdAt,
    decidedAt: raw.decidedAt,
  });
}

function planPatchForAcceptedProposal(
  proposal: z.infer<typeof PlanAdjustmentProposal>,
  plan: Record<string, unknown>,
) {
  const days = isRecord(plan.days) ? plan.days : {};
  const dayKey = proposal.appliesTo.dayKey ?? currentDayKey();

  if (proposal.category === "skip_or_reschedule") {
    return {
      days: {
        ...days,
        [dayKey]: {
          name: "Rest · Skipped",
          muscles: [],
          exercises: [],
        },
      },
    };
  }

  throw new Error("plan_adjustment_patch_not_supported");
}

function resolveAppliesToDayKey(category: AdjustmentCategory, dayKey: string | undefined) {
  if (dayKey) return { dayKey };
  if (category === "skip_or_reschedule" || category === "time_limit" || category === "readiness_low") {
    return { dayKey: currentDayKey() };
  }
  return {};
}

function currentDayKey() {
  const weekday = new Intl.DateTimeFormat("en-US", {
    weekday: "short",
    timeZone: "America/New_York",
  }).format(new Date());
  return weekday;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function classifyPlanAdjustment(content: string, hasWorkoutContext: boolean): AdjustmentCategory | null {
  const text = content.toLowerCase();

  if (matchesAny(text, ["pregnant", "pregnancy", "postpartum", "trimester"])) {
    return "pregnancy_postpartum";
  }
  if (matchesAny(text, [
    "hurt",
    "pain",
    "injury",
    "injured",
    "ankle",
    "knee",
    "shoulder",
    "back",
    "wrist",
    "hip",
    "swollen",
    "sprain",
  ])) {
    return "injury_pain";
  }
  if (matchesAny(text, ["hungover", "hangover", "sick", "tired", "fatigue", "exhausted", "sore", "sleep"])) {
    return "readiness_low";
  }
  if (matchesAny(text, ["less time", "shorten", "quick", "only have", "minutes", "minute", "busy"])) {
    return "time_limit";
  }
  if (matchesAny(text, ["skip", "missed", "can't train", "cannot train", "reschedule", "move this", "move it"])) {
    return "skip_or_reschedule";
  }
  if (matchesAny(text, ["travel", "hotel", "airport", "vacation", "on the road"])) {
    return "travel";
  }
  if (matchesAny(text, ["no gym", "no equipment", "dumbbell only", "kettlebell only", "bodyweight", "machine unavailable"])) {
    return "equipment_limit";
  }
  if (matchesAny(text, ["yoga", "pilates", "mobility", "stretch", "conditioning", "cardio", "different style"])) {
    return "style_preference";
  }
  if (matchesAny(text, ["calorie", "protein", "diet", "nutrition", "meal", "cutting", "bulking"])) {
    return "nutrition_context";
  }
  if (hasWorkoutContext && matchesAny(text, ["change", "swap", "adjust", "better", "modify", "replace", "too hard", "too easy"])) {
    return "other";
  }

  return null;
}

function matchesAny(text: string, needles: string[]) {
  return needles.some((needle) => text.includes(needle));
}

function riskForCategory(category: AdjustmentCategory, content: string): AdjustmentRiskLevel {
  const text = content.toLowerCase();
  if (
    matchesAny(text, [
      "chest pain",
      "can't breathe",
      "cannot breathe",
      "faint",
      "fainted",
      "bleeding",
      "numb",
      "deformity",
      "severe pain",
    ])
  ) {
    return "high";
  }
  if (category === "injury_pain" || category === "pregnancy_postpartum") return "high";
  if (category === "readiness_low" || category === "nutrition_context") return "medium";
  return "low";
}

function needsFollowUp(category: AdjustmentCategory, riskLevel: AdjustmentRiskLevel) {
  return riskLevel !== "low" || category === "equipment_limit" || category === "other";
}

function summaryForCategory(category: AdjustmentCategory, exerciseName?: string) {
  const target = exerciseName ? ` for ${exerciseName}` : "";
  const summaries: Record<AdjustmentCategory, string> = {
    time_limit: `User needs a shorter workout option${target}.`,
    equipment_limit: `User needs an equipment-aware workout adjustment${target}.`,
    skip_or_reschedule: "User needs to skip, move, or reschedule training without cramming unsafe volume.",
    readiness_low: "User reported low readiness and needs a conservative training adjustment.",
    style_preference: "User wants a different training style while preserving the week's intent.",
    injury_pain: "User reported pain or injury and needs a safety-first adjustment.",
    pregnancy_postpartum: "User mentioned pregnancy or postpartum context and needs conservative, clinician-aware guidance.",
    travel: "User needs a travel-compatible training adjustment.",
    nutrition_context: "User raised nutrition context that may affect plan targets or recovery guidance.",
    other: `User requested a workout-plan adjustment${target}.`,
  };
  return summaries[category];
}

function rationaleForCategory(category: AdjustmentCategory) {
  const rationales: Record<AdjustmentCategory, string> = {
    time_limit: "Shortening should preserve the highest-value movements and reduce volume before intensity becomes sloppy.",
    equipment_limit: "Equipment constraints should drive substitutions that preserve the intended movement pattern when possible.",
    skip_or_reschedule: "Missed sessions should preserve weekly intent without automatically doubling volume later.",
    readiness_low: "Low readiness calls for reducing load, volume, intensity, or impact before adding work.",
    style_preference: "Style changes can improve adherence if the plan still respects the user's goals and recovery.",
    injury_pain: "Pain reports require avoiding aggravating movements and gathering more context before progressing.",
    pregnancy_postpartum: "Pregnancy and postpartum context requires conservative, clinician-aware boundaries.",
    travel: "Travel plans should use available time, space, and equipment without punishing the user for constraints.",
    nutrition_context: "Nutrition changes should be range-based and constrained by safety context, not strict medical dieting.",
    other: "The user supplied a flexible reason, so MYO should review context before changing the plan.",
  };
  return rationales[category];
}

function patchForCategory(category: AdjustmentCategory, requiresFollowUp: boolean) {
  if (requiresFollowUp) {
    return {
      type: "review_only",
      title: "Ask one follow-up before changing the plan",
      changes: [
        "Keep the current plan unchanged until the missing context is clear.",
        "Use the user's reason, current workout, and safety context to propose a specific edit next.",
      ],
    };
  }

  const patches: Record<AdjustmentCategory, { type: string; title: string; changes: string[] }> = {
    time_limit: {
      type: "shorten_workout",
      title: "Shorten today's workout",
      changes: [
        "Prioritize the main compound movement or highest-value exercise first.",
        "Reduce accessory volume before increasing intensity.",
      ],
    },
    equipment_limit: {
      type: "review_only",
      title: "Find equipment-matched substitutions",
      changes: ["Map unavailable equipment to same-pattern alternatives."],
    },
    skip_or_reschedule: {
      type: "reschedule_day",
      title: "Preserve the week without cramming",
      changes: [
        "Move or skip the session while protecting recovery.",
        "Do not automatically double the next workout.",
      ],
    },
    readiness_low: {
      type: "review_only",
      title: "Reduce intensity for low readiness",
      changes: ["Consider easier load, fewer sets, mobility, walking, or rest."],
    },
    style_preference: {
      type: "replace_day_focus",
      title: "Swap the style while preserving intent",
      changes: ["Replace the session with a style-compatible option that respects the weekly goal."],
    },
    injury_pain: {
      type: "review_only",
      title: "Safety-first adjustment",
      changes: ["Avoid movements that reproduce or worsen symptoms until more context is known."],
    },
    pregnancy_postpartum: {
      type: "review_only",
      title: "Clinician-aware adjustment",
      changes: ["Keep suggestions conservative and ask about clinician restrictions."],
    },
    travel: {
      type: "replace_day_focus",
      title: "Travel-compatible workout",
      changes: ["Use available space, time, and equipment while preserving the day's intent."],
    },
    nutrition_context: {
      type: "review_only",
      title: "Review nutrition context",
      changes: ["Use range-based guidance and avoid medical diet prescriptions."],
    },
    other: {
      type: "review_only",
      title: "Review requested change",
      changes: ["Turn the user's freeform reason into a specific plan edit after context check."],
    },
  };
  return patches[category];
}

function safetyNotesForCategory(category: AdjustmentCategory, corpusSafetyNotes: string[]) {
  const notes = [...corpusSafetyNotes];
  if (category === "injury_pain") {
    notes.unshift("Do not diagnose injuries or prescribe rehab protocols. Escalate for severe or worsening symptoms.");
  }
  if (category === "pregnancy_postpartum") {
    notes.unshift("Ask about clinician restrictions and avoid high-intensity pregnancy/postpartum prescriptions.");
  }
  if (category === "nutrition_context") {
    notes.unshift("Use estimate ranges, not strict medical nutrition plans.");
  }
  return [...new Set(notes)].slice(0, 6);
}
