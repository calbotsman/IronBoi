import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { z } from "zod";
import {
  CoachInputMode,
  CoachingLens,
  GoalType,
  PlannedWorkoutDay,
  ProgramProposal,
  TrainingFocus,
  UserHealthProfile,
  WorkoutPlan,
} from "../contracts/coach-agent.js";
import {
  coachSessionMessagePath,
  coachSessionPath,
  profilePath,
  programProposalPath,
  trainingProgramPath,
  workoutPlanPath,
} from "../paths.js";
import { buildTrainingProgramFromDays } from "../workouts/program.js";

export const OnboardingAnswerRequest = z.object({
  messageId: z.string().min(1).optional(),
  content: z.string().default(""),
  timestamp: z.string().datetime(),
  inputMode: CoachInputMode.default("text"),
  structuredAnswer: z.record(z.string(), z.unknown()).optional(),
});

export const AcceptProgramProposalRequest = z.object({
  proposalId: z.string().min(1),
  decidedAt: z.string().datetime().optional(),
});

type OnboardingAnswerRequest = z.infer<typeof OnboardingAnswerRequest>;
type OnboardingDraft = Record<string, unknown>;
type PlannedWorkoutDayType = z.infer<typeof PlannedWorkoutDay>;
type UserHealthProfileType = z.infer<typeof UserHealthProfile>;

const ONBOARDING_SESSION_ID = "onboarding";
const REQUIRED_FIELDS = [
  "goals",
  "ageYears",
  "sexOrGender",
  "heightCm",
  "weightKg",
  "trainingExperience",
  "equipment",
  "daysPerWeek",
  "sessionLengthMin",
  "trainingFocus",
  "injuriesOrLimitations",
  "dietaryConstraints",
  // coachingLens is intentionally LAST: it's a first-run hook (everyone meets
  // protocols), but ordering it after the core fields keeps the "Last one…"
  // question honest and stops an in-flight draft that already cleared the core
  // fields from being bounced backward when this field was added.
  "coachingLens",
] as const;

const QUESTIONS: Record<string, string> = {
  goals: "What is your main goal right now: build muscle, lose fat, get stronger, improve general fitness, mobility, endurance, build habits, or return to training?",
  ageYears: "How old are you?",
  sexOrGender: "Which sex or gender should I use for general fitness estimates?",
  heightCm: "What is your height?",
  weightKg: "What is your current weight?",
  trainingExperience: "What is your training experience: new, beginner, intermediate, or advanced?",
  equipment: "What equipment do you have access to?",
  daysPerWeek: "How many days per week do you realistically want to train?",
  sessionLengthMin: "How long do you want each workout to be?",
  trainingFocus: "I can recommend the structure from your goal, experience, schedule, and equipment. Do you want to use MYO's recommended focus, or steer it toward a muscle split, full-body training, strength + conditioning, mobility/recovery, or endurance conditioning?",
  coachingLens: "Last one: how would you like me to explain things? I can keep my own balanced voice, or coach through a protocol — recovery & nervous system (Huberman), hypertrophy science (Schoenfeld), female physiology (Sims), or longevity & measurement (Blueprint). You can change this anytime.",
  injuriesOrLimitations: "Any injuries, pain, limitations, or movements you want me to avoid?",
  dietaryConstraints: "Any nutrition constraints or preferences I should account for?",
};

export async function processOnboardingAnswer(
  db: Firestore,
  userId: string,
  request: OnboardingAnswerRequest,
  defaultPlan: Record<string, PlannedWorkoutDayType>,
) {
  const turnId = request.messageId ?? `onboarding_${Date.now()}`;
  const profileRef = db.doc(profilePath(userId));
  const profileSnap = await profileRef.get();
  const current = profileSnap.data() ?? {};
  const draft = applyAnswer(
    readDraft(current.onboardingDraft),
    current.onboardingStep,
    request.content,
    request.structuredAnswer,
  );
  const missingFields = missingRequiredFields(draft);
  const nextStep = missingFields[0] ?? "proposal_ready";

  await db.doc(coachSessionPath(userId, ONBOARDING_SESSION_ID)).set(
    {
      userId,
      sessionId: ONBOARDING_SESSION_ID,
      startedAt: current.startedAt ?? request.timestamp,
      outcome: "active",
      serverUpdatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  await db
    .doc(coachSessionMessagePath(userId, ONBOARDING_SESSION_ID, turnId))
    .set({
      userId,
      sessionId: ONBOARDING_SESSION_ID,
      messageId: turnId,
      role: "user",
      content: request.content,
      timestamp: request.timestamp,
      inputMode: request.inputMode,
      structuredAnswer: request.structuredAnswer ?? {},
      status: "complete",
      toolCallIds: [],
      serverCreatedAt: FieldValue.serverTimestamp(),
    });

  if (missingFields.length > 0) {
    await profileRef.set(
      {
        userId,
        onboardingStatus: "collecting",
        onboardingStep: nextStep,
        onboardingMissingFields: missingFields,
        onboardingDraft: draft,
        updatedAt: request.timestamp,
        serverUpdatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    const nextPrompt = questionForStep(nextStep, draft);
    await writeCoachMessage(db, userId, `${turnId}_coach`, request.timestamp, nextPrompt);
    return {
      ok: true,
      onboardingStatus: "collecting",
      onboardingStep: nextStep,
      onboardingMissingFields: missingFields,
      nextPrompt,
    };
  }

  const proposal = buildProgramProposal(userId, request.timestamp, draft, defaultPlan);
  await Promise.all([
    profileRef.set(
      {
        userId,
        onboardingStatus: "proposal_ready",
        onboardingStep: "review_plan",
        onboardingMissingFields: [],
        onboardingDraft: draft,
        activeProgramProposalId: proposal.proposalId,
        updatedAt: request.timestamp,
        serverUpdatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    ),
    db.doc(programProposalPath(userId, proposal.proposalId)).set({
      ...proposal,
      serverCreatedAt: FieldValue.serverTimestamp(),
    }),
    writeCoachMessage(
      db,
      userId,
      `${turnId}_coach`,
      request.timestamp,
      "I have enough to draft your first MYO plan. Review the weekly workout plan and calorie estimate, then accept it when it looks right.",
    ),
  ]);

  return {
    ok: true,
    onboardingStatus: "proposal_ready",
    proposal,
  };
}

export async function acceptProgramProposal(
  db: Firestore,
  userId: string,
  request: z.infer<typeof AcceptProgramProposalRequest>,
) {
  const proposalRef = db.doc(programProposalPath(userId, request.proposalId));
  const profileRef = db.doc(profilePath(userId));
  const workoutPlanRef = db.doc(workoutPlanPath(userId, "current"));
  const trainingProgramRef = db.doc(trainingProgramPath(userId));
  const serverDecidedAt = new Date().toISOString();

  await db.runTransaction(async (transaction) => {
    const proposalSnap = await transaction.get(proposalRef);
    if (!proposalSnap.exists) {
      throw new Error("program_proposal_not_found");
    }

    const proposal = parseProgramProposalDocument(proposalSnap.data());
    if (proposal.userId !== userId) {
      throw new Error("program_proposal_user_mismatch");
    }
    if (proposal.decision !== "pending") {
      throw new Error("program_proposal_not_pending");
    }

    transaction.set(
      profileRef,
      acceptedProfileUpdate(proposal.profile, request.proposalId, serverDecidedAt),
      { merge: true },
    );

    transaction.set(
      workoutPlanRef,
      {
        ...proposal.workoutPlan,
        planId: "current",
        userId,
        updatedAt: serverDecidedAt,
        serverUpdatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    // New program's week clock starts today — this is the first time the
    // user has a plan at all, so there's no "activeWeekIndex" history to
    // preserve.
    const program = buildTrainingProgramFromDays(
      userId,
      proposal.workoutPlan.days,
      serverDecidedAt.slice(0, 10),
      serverDecidedAt,
    );
    transaction.set(trainingProgramRef, {
      ...program,
      serverUpdatedAt: FieldValue.serverTimestamp(),
    });

    transaction.set(
      proposalRef,
      {
        decision: "accepted",
        decidedAt: serverDecidedAt,
        // Only write clientDecidedAt when present — Firestore rejects
        // `undefined`, which 500'd the whole accept when the client omitted it.
        ...(request.decidedAt !== undefined ? { clientDecidedAt: request.decidedAt } : {}),
        serverDecidedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  });

  return { ok: true, proposalId: request.proposalId, decidedAt: serverDecidedAt };
}

function parseProgramProposalDocument(data: FirebaseFirestore.DocumentData | undefined) {
  const raw = data ?? {};
  return ProgramProposal.parse({
    userId: raw.userId,
    proposalId: raw.proposalId,
    source: raw.source,
    decision: raw.decision,
    profile: raw.profile,
    workoutPlan: raw.workoutPlan,
    nutritionTargets: raw.nutritionTargets,
    createdAt: raw.createdAt,
    decidedAt: raw.decidedAt,
  });
}

function acceptedProfileUpdate(
  profile: UserHealthProfileType,
  proposalId: string,
  serverDecidedAt: string,
) {
  return compactUndefined({
    userId: profile.userId,
    ageYears: profile.ageYears,
    sexOrGender: profile.sexOrGender,
    sexOrGenderSelfDescription: profile.sexOrGenderSelfDescription,
    heightCm: profile.heightCm,
    weightKg: profile.weightKg,
    goals: profile.goals,
    goalNotes: profile.goalNotes,
    trainingExperience: profile.trainingExperience,
    injuriesOrLimitations: profile.injuriesOrLimitations,
    equipment: profile.equipment,
    schedule: profile.schedule,
    preferences: profile.preferences,
    dietaryConstraints: profile.dietaryConstraints,
    createdAt: profile.createdAt,
    onboardingStatus: "complete",
    onboardingStep: "complete",
    onboardingMissingFields: [],
    activeProgramProposalId: proposalId,
    updatedAt: serverDecidedAt,
    serverUpdatedAt: FieldValue.serverTimestamp(),
  });
}

function compactUndefined<T extends Record<string, unknown>>(value: T): T {
  return Object.fromEntries(
    Object.entries(value).filter(([, entry]) => entry !== undefined),
  ) as T;
}

function readDraft(value: unknown): OnboardingDraft {
  return value && typeof value === "object" && !Array.isArray(value)
    ? { ...(value as OnboardingDraft) }
    : {};
}

function applyAnswer(
  draft: OnboardingDraft,
  currentStep: unknown,
  content: string,
  structuredAnswer?: Record<string, unknown>,
) {
  const next = { ...draft, ...(structuredAnswer ?? {}) };
  if (structuredAnswer && Object.keys(structuredAnswer).length > 0) {
    return normalizeDraft(next);
  }

  const step = typeof currentStep === "string" ? currentStep : missingRequiredFields(next)[0];

  if (step && content.trim()) {
    next[step] = normalizeStepValue(step, content.trim());
  }

  return normalizeDraft(next);
}

function normalizeDraft(draft: OnboardingDraft): OnboardingDraft {
  const next = { ...draft };
  if (typeof next.goals === "string") next.goals = parseGoals(next.goals);
  if (typeof next.equipment === "string") next.equipment = splitList(next.equipment);
  if (Array.isArray(next.equipment)) next.equipment = cleanList(next.equipment);
  if (typeof next.dietaryConstraints === "string") {
    next.dietaryConstraints = splitList(next.dietaryConstraints);
  }
  if (Array.isArray(next.dietaryConstraints)) {
    next.dietaryConstraints = cleanList(next.dietaryConstraints);
  }
  if (typeof next.injuriesOrLimitations === "string") {
    next.injuriesOrLimitations = splitList(next.injuriesOrLimitations);
  }
  if (Array.isArray(next.injuriesOrLimitations)) {
    next.injuriesOrLimitations = cleanList(next.injuriesOrLimitations);
  }
  if (typeof next.sexOrGender === "string") next.sexOrGender = normalizeSexOrGender(next.sexOrGender);
  if (typeof next.trainingExperience === "string") {
    next.trainingExperience = normalizeTrainingExperience(next.trainingExperience);
  }
  if (typeof next.trainingFocus === "string") {
    next.trainingFocus = normalizeTrainingFocus(next.trainingFocus);
  }
  for (const field of ["ageYears", "daysPerWeek", "sessionLengthMin"]) {
    if (typeof next[field] === "string") next[field] = parseNumber(next[field]);
  }
  if (typeof next.heightCm === "string") next.heightCm = parseHeightCm(next.heightCm);
  if (typeof next.weightKg === "string") next.weightKg = parseWeightKg(next.weightKg);
  return next;
}

function normalizeStepValue(step: string, content: string) {
  switch (step) {
    case "goals":
      return parseGoals(content);
    case "equipment":
    case "dietaryConstraints":
    case "injuriesOrLimitations":
      return splitList(content);
    case "sexOrGender":
      return normalizeSexOrGender(content);
    case "trainingExperience":
      return normalizeTrainingExperience(content);
    case "trainingFocus":
      return normalizeTrainingFocus(content);
    case "coachingLens":
      return normalizeCoachingLens(content);
    case "ageYears":
    case "daysPerWeek":
    case "sessionLengthMin":
      return parseNumber(content);
    case "heightCm":
      return parseHeightCm(content);
    case "weightKg":
      return parseWeightKg(content);
    default:
      return content;
  }
}

function missingRequiredFields(draft: OnboardingDraft) {
  return REQUIRED_FIELDS.filter((field) => {
    const value = draft[field];
    return value === undefined || value === null || value === "" || (Array.isArray(value) && value.length === 0);
  });
}

function buildProgramProposal(
  userId: string,
  now: string,
  draft: OnboardingDraft,
  defaultPlan: Record<string, PlannedWorkoutDayType>,
) {
  const profile = UserHealthProfile.parse({
    userId,
    ageYears: draft.ageYears,
    sexOrGender: draft.sexOrGender,
    heightCm: draft.heightCm,
    weightKg: draft.weightKg,
    goals: draft.goals,
    goalNotes: Array.isArray(draft.goals) ? (draft.goals as string[]).join(", ") : undefined,
    trainingExperience: draft.trainingExperience,
    injuriesOrLimitations: draft.injuriesOrLimitations ?? [],
    equipment: draft.equipment ?? [],
    schedule: {
      daysPerWeek: draft.daysPerWeek,
      preferredDays: [],
      sessionLengthMin: draft.sessionLengthMin,
    },
    preferences: {
      coachingTone: "balanced",
      preferredWorkoutTime: "flexible",
      dislikedExercises: [],
      trainingFocus: normalizeTrainingFocus(draft.trainingFocus),
      coachingLens: normalizeCoachingLens(draft.coachingLens),
    },
    dietaryConstraints: draft.dietaryConstraints ?? [],
    onboardingStatus: "proposal_ready",
    onboardingStep: "review_plan",
    onboardingMissingFields: [],
    createdAt: now,
    updatedAt: now,
  });

  const workoutPlan = buildWorkoutPlanFromProfile(userId, profile, defaultPlan, now);

  return ProgramProposal.parse({
    userId,
    proposalId: `onboarding_${Date.now()}`,
    source: "onboarding",
    decision: "pending",
    profile,
    workoutPlan,
    nutritionTargets: buildNutritionTargets(profile),
    createdAt: now,
  });
}

function questionForStep(step: string, draft: OnboardingDraft) {
  if (step !== "trainingFocus") {
    return QUESTIONS[step] ?? "What else should I know before I build your plan?";
  }

  const recommended = recommendTrainingFocus(draft);
  const reasons = focusReasons(draft);
  return [
    `Based on what you told me, I recommend ${trainingFocusLabel(recommended)} as the starting focus.`,
    reasons ? `Why: ${reasons}.` : "Why: it gives us a practical starting structure without overfitting the plan too early.",
    "",
    "Want to use MYO's recommendation, or steer it toward a muscle split, full-body training, strength + conditioning, mobility/recovery, or endurance conditioning?",
  ].join("\n");
}

// Canonical training-day distributions per weekly frequency. These are
// the splits a real coach would prescribe — front-loading a 3-day plan
// into Mon/Tue/Wed (the old behavior) gives you three workouts and four
// straight days off, which is not how anyone trains. The reasoning:
//
//   1 day:  Mon                         → start-of-week anchor
//   2 days: Mon, Thu                    → ~72h between sessions
//   3 days: Mon, Wed, Fri               → classic Mon/Wed/Fri split
//   4 days: Mon, Tue, Thu, Fri          → upper/lower or push/pull
//   5 days: Mon, Tue, Wed, Fri, Sat     → Thu as midweek deload day
//   6 days: Mon, Tue, Wed, Thu, Fri, Sat → Sunday rest
//   7 days: Mon..Sun                    → every day, with at least one
//                                         active-recovery slot
const CANONICAL_TRAINING_DAYS: Record<number, string[]> = {
  1: ["Mon"],
  2: ["Mon", "Thu"],
  3: ["Mon", "Wed", "Fri"],
  4: ["Mon", "Tue", "Thu", "Fri"],
  5: ["Mon", "Tue", "Wed", "Fri", "Sat"],
  6: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
  7: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
};

const WEEK_ORDER = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] as const;

// Reusable plan builder — used by both the onboarding proposal flow AND
// the standalone regenerateWorkoutPlan callable. Same logic, same days
// distribution, same shape. Don't duplicate this elsewhere.
export function buildWorkoutPlanFromProfile(
  userId: string,
  profile: {
    schedule: { daysPerWeek?: number; preferredDays?: string[] };
  },
  defaultPlan: Record<string, PlannedWorkoutDayType>,
  now: string,
) {
  return WorkoutPlan.parse({
    userId,
    planId: "current",
    source: "coach_generated",
    days: selectPlanDays(
      defaultPlan,
      profile.schedule.daysPerWeek ?? 3,
      profile.schedule.preferredDays,
    ),
    updatedAt: now,
  });
}

export function selectPlanDays(
  defaultPlan: Record<string, PlannedWorkoutDayType>,
  daysPerWeek: number,
  preferredDays?: string[],
) {
  const clamped = Math.max(1, Math.min(7, daysPerWeek));
  const trainingDays = pickTrainingDays(clamped, preferredDays);

  // For each training day, pull the next day-with-exercises from the seed
  // plan in seed order. Seed Mon→Sun is a curated rotation so distributing
  // it by index (not by exact day) keeps the muscle-group rhythm.
  const seedDaysWithExercises = WEEK_ORDER.map((day) => defaultPlan[day]).filter(
    (value) => value && (value.exercises?.length ?? 0) > 0,
  );

  const restDay = { name: "Rest", muscles: [], exercises: [] };
  return Object.fromEntries(
    WEEK_ORDER.map((day) => {
      const trainingIdx = trainingDays.indexOf(day);
      if (trainingIdx === -1) return [day, restDay];
      // Modulo so we wrap when daysPerWeek > seed-day-count.
      const seed =
        seedDaysWithExercises[trainingIdx % seedDaysWithExercises.length];
      return [day, seed ?? restDay];
    }),
  );
}

// If the user listed preferred days in onboarding and they're well-formed
// AND there are enough of them to satisfy daysPerWeek, honor them.
// Otherwise fall back to the canonical schedule.
function pickTrainingDays(
  daysPerWeek: number,
  preferredDays?: string[],
): string[] {
  const valid = (preferredDays ?? [])
    .map((d) => d.slice(0, 3))
    .filter((d): d is (typeof WEEK_ORDER)[number] =>
      (WEEK_ORDER as readonly string[]).includes(d),
    );
  if (valid.length >= daysPerWeek) {
    // Take the first N in week order to keep deterministic ordering.
    const set = new Set(valid);
    return WEEK_ORDER.filter((d) => set.has(d)).slice(0, daysPerWeek);
  }
  return CANONICAL_TRAINING_DAYS[daysPerWeek] ?? CANONICAL_TRAINING_DAYS[3];
}

function recommendTrainingFocus(draft: OnboardingDraft): z.infer<typeof TrainingFocus> {
  const goals = Array.isArray(draft.goals) ? draft.goals : [];
  const daysPerWeek = typeof draft.daysPerWeek === "number" ? draft.daysPerWeek : 3;
  const experience = typeof draft.trainingExperience === "string" ? draft.trainingExperience : "beginner";
  const equipment = Array.isArray(draft.equipment)
    ? draft.equipment.join(" ").toLowerCase()
    : "";

  if (goals.includes("mobility") || goals.includes("return_to_training")) {
    return "mobility_recovery";
  }
  if (goals.includes("endurance") && !goals.includes("muscle_gain") && !goals.includes("strength")) {
    return "endurance_conditioning";
  }
  if (daysPerWeek <= 3 || experience === "new" || experience === "beginner") {
    return "full_body";
  }
  if ((goals.includes("muscle_gain") || goals.includes("fat_loss")) && daysPerWeek >= 5) {
    return "muscle_split";
  }
  if (goals.includes("strength") || /barbell|kettlebell|dumbbell|gym/.test(equipment)) {
    return "strength_conditioning";
  }
  return "myo_recommended";
}

function focusReasons(draft: OnboardingDraft) {
  const parts: string[] = [];
  const goals = Array.isArray(draft.goals) ? draft.goals.map(String) : [];
  const daysPerWeek = typeof draft.daysPerWeek === "number" ? draft.daysPerWeek : undefined;
  const experience = typeof draft.trainingExperience === "string" ? draft.trainingExperience : undefined;
  const equipment = Array.isArray(draft.equipment) ? draft.equipment : [];
  const age = typeof draft.ageYears === "number" ? draft.ageYears : undefined;
  const sexOrGender = typeof draft.sexOrGender === "string" ? draft.sexOrGender : undefined;

  if (goals.length) parts.push(`your stated goal is ${goals.join(" + ").replace(/_/g, " ")}`);
  if (daysPerWeek) parts.push(`you can train ${daysPerWeek} days per week`);
  if (experience) parts.push(`you marked yourself ${experience}`);
  if (equipment.length) parts.push("your equipment supports progressive resistance");
  if (age && age < 18) parts.push("you are under 18, so MYO keeps nutrition targets conservative");
  if (sexOrGender === "female") {
    parts.push("sex/gender context only affects broad estimates and population-aware safety checks");
  }

  return parts.slice(0, 4).join(", ");
}

function trainingFocusLabel(focus: z.infer<typeof TrainingFocus>) {
  switch (focus) {
    case "muscle_split":
      return "a muscle-group split";
    case "full_body":
      return "full-body training";
    case "strength_conditioning":
      return "strength + conditioning";
    case "mobility_recovery":
      return "mobility/recovery";
    case "endurance_conditioning":
      return "endurance conditioning";
    case "myo_recommended":
    default:
      return "MYO's recommended focus";
  }
}

function buildNutritionTargets(profile: UserHealthProfileType) {
  const proteinMin = Math.round((profile.weightKg ?? 70) * 1.6);
  const proteinMax = Math.round((profile.weightKg ?? 70) * 2.2);
  const safetyNotes = [
    "General wellness estimate only; adjust based on trend, energy, performance, and professional guidance when needed.",
  ];

  if (profile.ageYears < 18) {
    return {
      proteinGrams: { min: proteinMin, max: proteinMax },
      assumptions: ["Minor profile: calorie targets are intentionally withheld."],
      safetyNotes: ["For minors, MYO avoids calorie targets and recommends guardian/clinician guidance."],
    };
  }

  const height = profile.heightCm ?? 175;
  const weight = profile.weightKg ?? 75;
  const sexAdjustment = profile.sexOrGender === "female" ? -161 : 5;
  const bmr = 10 * weight + 6.25 * height - 5 * profile.ageYears + sexAdjustment;
  const maintenance = Math.round((bmr * 1.45) / 50) * 50;
  const goalAdjustment = profile.goals.includes("fat_loss") ? -250 : profile.goals.includes("muscle_gain") ? 200 : 0;
  const target = maintenance + goalAdjustment;

  return {
    calories: {
      min: Math.max(1200, target - 150),
      max: Math.max(1300, target + 150),
      note: "Estimated daily calorie range, not a medical prescription.",
    },
    proteinGrams: { min: proteinMin, max: proteinMax },
    assumptions: [
      "Uses a standard BMR estimate and a moderate activity multiplier.",
      "Should be adjusted after 2-3 weeks of weight, energy, and performance trend data.",
    ],
    safetyNotes,
  };
}

async function writeCoachMessage(
  db: Firestore,
  userId: string,
  messageId: string,
  timestamp: string,
  content: string,
) {
  await db.doc(coachSessionMessagePath(userId, ONBOARDING_SESSION_ID, messageId)).set({
    userId,
    sessionId: ONBOARDING_SESSION_ID,
    messageId,
    role: "coach",
    content,
    timestamp,
    status: "complete",
    toolCallIds: [],
    serverCreatedAt: FieldValue.serverTimestamp(),
  });
}

function parseNumber(value: string) {
  const match = value.match(/\d+(\.\d+)?/);
  return match ? Number(match[0]) : undefined;
}

function parseHeightCm(value: string) {
  const lower = value.toLowerCase();
  const feetInches = lower.match(/(\d+)\s*(?:'|ft|feet)\s*(\d+)?/);
  if (feetInches) {
    const feet = Number(feetInches[1]);
    const inches = Number(feetInches[2] ?? 0);
    return Math.round((feet * 12 + inches) * 2.54);
  }
  const numeric = parseNumber(value);
  if (!numeric) return undefined;
  return lower.includes("cm") || numeric > 100 ? numeric : Math.round(numeric * 2.54);
}

function parseWeightKg(value: string) {
  const lower = value.toLowerCase();
  const numeric = parseNumber(value);
  if (!numeric) return undefined;
  return lower.includes("kg") ? numeric : Math.round(numeric * 0.453592 * 10) / 10;
}

function splitList(value: string) {
  if (/\b(no|none|nothing)\b/i.test(value)) return ["none"];
  return cleanList(
    value
      .replace(/\b(i also have|i have|access to|available to me)\b/gi, "")
    .split(/,| and |\n/i)
      .map((item) => item.trim()),
  );
}

function cleanList(values: unknown[]) {
  const cleaned = values
    .filter((item): item is string => typeof item === "string")
    .map((item) =>
      item
        .trim()
        .replace(/^(a|an|the)\s+/i, "")
        .replace(/\s+/g, " "),
    )
    .filter(Boolean);

  return [...new Set(cleaned)];
}

function parseGoals(value: string): z.infer<typeof GoalType>[] {
  const lower = value.toLowerCase();
  const goals: z.infer<typeof GoalType>[] = [];
  if (/strength|strong/.test(lower)) goals.push("strength");
  if (/muscle|ripped|hypertrophy|gain/.test(lower)) goals.push("muscle_gain");
  if (/fat|lean|lose|cut|weight loss/.test(lower)) goals.push("fat_loss");
  if (/mobile|mobility|flex/.test(lower)) goals.push("mobility");
  if (/endurance|cardio|stamina/.test(lower)) goals.push("endurance");
  if (/habit|consistent/.test(lower)) goals.push("habit_building");
  if (/return|restart|back/.test(lower)) goals.push("return_to_training");
  if (goals.length === 0) goals.push("general_fitness");
  return [...new Set(goals)];
}

function normalizeSexOrGender(value: string) {
  const lower = value.toLowerCase();
  if (/female|woman|girl/.test(lower)) return "female";
  if (/male|man|boy/.test(lower)) return "male";
  if (/non/.test(lower)) return "non_binary";
  if (/prefer/.test(lower)) return "prefer_not_to_say";
  return "self_described";
}

function normalizeTrainingExperience(value: string) {
  const lower = value.toLowerCase();
  if (/advanced|expert/.test(lower)) return "advanced";
  if (/intermediate/.test(lower)) return "intermediate";
  if (/beginner|some/.test(lower)) return "beginner";
  return "new";
}

function normalizeCoachingLens(value: unknown): z.infer<typeof CoachingLens> {
  if (typeof value !== "string") return "none";
  const lower = value.toLowerCase();
  if (/huberman|nervous|circadian|sleep/.test(lower)) return "huberman";
  if (/schoenfeld|hypertroph|tension|volume/.test(lower)) return "schoenfeld";
  if (/sims|female|cycle|menstru/.test(lower)) return "sims";
  if (/blueprint|johnson|longevity|measure/.test(lower)) return "blueprint";
  return "none";
}

function normalizeTrainingFocus(value: unknown): z.infer<typeof TrainingFocus> {
  if (typeof value !== "string") return "myo_recommended";
  const lower = value.toLowerCase();
  if (/split|push|pull|legs|muscle|body part|bodypart|ppl/.test(lower)) return "muscle_split";
  if (/full|whole/.test(lower)) return "full_body";
  if (/strength|conditioning|athletic|power/.test(lower)) return "strength_conditioning";
  if (/mobility|recover|yoga|stretch/.test(lower)) return "mobility_recovery";
  if (/endurance|cardio|peloton|stamina/.test(lower)) return "endurance_conditioning";
  return "myo_recommended";
}
