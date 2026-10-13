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
  userRoot,
  workoutPlanPath,
} from "../paths.js";
import { buildTrainingProgramFromDays } from "../workouts/program.js";
import { attachDefaultProgression } from "../workouts/progressionDefaults.js";
import { fitPlanToUser } from "../workouts/planFit.js";
import { trainingDaysPerWeek, welcomeMessage } from "../journey/recap.js";
import { writeGeneralCoachMessage } from "../journey/messages.js";
import { safeLogger } from "../logging/safeLogger.js";

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
// Six things up front (docs/product/habit-journey-plan.md §1); everything
// else — height, weight, diet, exact age, the coaching lens — the coach learns
// by talking, or has a sensible default. The app asks these on the coach
// screen as cards; the server only needs the answers in this order.
const REQUIRED_FIELDS = [
  "goals",
  "trainingExperience",
  "equipment",
  "ageYears",
  "preferredDays",
  "injuriesOrLimitations",
] as const;

const QUESTIONS: Record<string, string> = {
  goals: "What do you want from training right now?",
  trainingExperience: "How much have you trained before?",
  equipment: "Where will you train, and with what?",
  ageYears: "Roughly how old are you?",
  preferredDays: "Which days work, and what time?",
  injuriesOrLimitations: "Last one: does anything hurt, or has a doctor told you to limit exercise?",
};

/**
 * Said yes to "has a doctor told you to limit exercise / chest pain, dizziness
 * or fainting when active?" (a PAR-Q+ style screen). The coach is not a
 * doctor: the plan starts at the gentlest level and the welcome says to get
 * cleared first. Kept as a limitation so the coach sees it on every turn.
 */
export const CLEARANCE_NOTE = "Doctor-advised limit or symptoms when active: get medical clearance before training";

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
        onboardingDraft: withoutUndefined(draft),
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
  // Changing an answer after the plan is drafted drafts a new one; the old
  // one is retired so the app (which shows "the" pending proposal) can't
  // show — or accept — a stale plan.
  const stale = await db
    .collection(`${userRoot(userId)}/programProposals`)
    .where("source", "==", "onboarding")
    .where("decision", "==", "pending")
    .get();
  await Promise.all(stale.docs.map((doc) =>
    doc.ref.set({ decision: "edited", serverDecidedAt: FieldValue.serverTimestamp() }, { merge: true })));
  await Promise.all([
    profileRef.set(
      {
        userId,
        onboardingStatus: "proposal_ready",
        onboardingStep: "review_plan",
        onboardingMissingFields: [],
        onboardingDraft: withoutUndefined(draft),
        activeProgramProposalId: proposal.proposalId,
        updatedAt: request.timestamp,
        serverUpdatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    ),
    db.doc(programProposalPath(userId, proposal.proposalId)).set({
      // Height, weight and the rest aren't asked up front any more, so the
      // proposal carries undefined fields Firestore would reject.
      ...withoutUndefined(proposal),
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

  const draftTime = (await profileRef.get()).get("onboardingDraft.preferredTime");
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
      acceptedProfileUpdate(
        proposal.profile,
        request.proposalId,
        serverDecidedAt,
        // The training time picked in onboarding (the draft keeps it).
        typeof draftTime === "string" ? draftTime : undefined,
      ),
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

  await welcomeToCoach(db, userId, request.proposalId, serverDecidedAt);

  return { ok: true, proposalId: request.proposalId, decidedAt: serverDecidedAt };
}

/**
 * The first thing the coach says once the plan is accepted — by name if we
 * know it, and pointing straight at today's first session. Best-effort: the
 * plan is already accepted, so a failure here costs the greeting, not the plan.
 */
async function welcomeToCoach(db: Firestore, userId: string, proposalId: string, now: string) {
  try {
    const [profileSnap, planSnap, logsSnap] = await Promise.all([
      db.doc(profilePath(userId)).get(),
      db.doc(workoutPlanPath(userId, "current")).get(),
      db.collection(`${userRoot(userId)}/workoutLogs`).limit(1).get(),
    ]);
    const name = profileSnap.get("preferredName");
    const limits = profileSnap.get("injuriesOrLimitations");
    const content = welcomeMessage({
      name: typeof name === "string" && name.length > 0 ? name : undefined,
      daysPerWeek: trainingDaysPerWeek(planSnap.get("days")),
      returning: !logsSnap.empty,
      clearanceAdvised: Array.isArray(limits) && limits.includes(CLEARANCE_NOTE),
    });
    await writeGeneralCoachMessage(db, userId, `welcome_${proposalId}`, content, now);
  } catch (error) {
    safeLogger.warn("Welcome message failed", {
      event: "welcome_message_failed",
      userId,
      errorDetail: error instanceof Error ? error.message.slice(0, 200) : "unknown_error",
    });
  }
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
  preferredTime?: string,
) {
  return compactUndefined({
    preferredTime,
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
    // When the habit clock starts (journey/metrics.ts measures from here).
    onboardingCompletedAt: serverDecidedAt,
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
    // "Mondays and Thursdays at 6" answers both halves of the schedule card.
    if (step === "preferredDays" && next.preferredTime === undefined) {
      const time = parseTime(content);
      if (time) next.preferredTime = time;
    }
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
    // The doctor / chest pain / dizziness screen, however it was answered,
    // becomes one plain note the coach sees on every turn.
    const items = cleanList(next.injuriesOrLimitations)
      .map((item) => (item === CLEARANCE_NOTE || needsClearance(item) ? CLEARANCE_NOTE : item));
    const cleared = [...new Set(items)];
    next.injuriesOrLimitations = cleared.length > 1 ? cleared.filter((item) => item !== "none") : cleared;
  }
  if (typeof next.sexOrGender === "string") next.sexOrGender = normalizeSexOrGender(next.sexOrGender);
  if (typeof next.trainingExperience === "string") {
    next.trainingExperience = normalizeTrainingExperience(next.trainingExperience);
  }
  if (typeof next.trainingFocus === "string") {
    next.trainingFocus = normalizeTrainingFocus(next.trainingFocus);
  }
  for (const field of ["daysPerWeek", "sessionLengthMin"]) {
    if (typeof next[field] === "string") next[field] = parseNumber(next[field]);
  }
  if (typeof next.ageYears === "string") next.ageYears = parseAge(next.ageYears);
  if (typeof next.preferredDays === "string") next.preferredDays = parseDays(next.preferredDays);
  if (Array.isArray(next.preferredDays)) {
    const days = parseDays(next.preferredDays.join(" "));
    next.preferredDays = days;
    if (days.length > 0) next.daysPerWeek = days.length;
  }
  if (typeof next.preferredTime === "string") next.preferredTime = parseTime(next.preferredTime) ?? undefined;
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
      return parseAge(content);
    case "preferredDays":
      return parseDays(content);
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
  const preferredDays = Array.isArray(draft.preferredDays) ? (draft.preferredDays as string[]) : [];
  const preferredTime = typeof draft.preferredTime === "string" ? draft.preferredTime : undefined;
  const clearanceAdvised = Array.isArray(draft.injuriesOrLimitations)
    && (draft.injuriesOrLimitations as string[]).includes(CLEARANCE_NOTE);
  const profile = UserHealthProfile.parse({
    userId,
    ageYears: draft.ageYears,
    // Not asked up front any more: only broad estimates used it.
    sexOrGender: draft.sexOrGender ?? "prefer_not_to_say",
    heightCm: draft.heightCm,
    weightKg: draft.weightKg,
    goals: draft.goals,
    goalNotes: Array.isArray(draft.goals) ? (draft.goals as string[]).join(", ") : undefined,
    trainingExperience: draft.trainingExperience,
    injuriesOrLimitations: draft.injuriesOrLimitations ?? [],
    equipment: draft.equipment ?? [],
    schedule: {
      daysPerWeek: preferredDays.length || draft.daysPerWeek || 3,
      preferredDays,
      sessionLengthMin: draft.sessionLengthMin ?? 45,
    },
    preferences: {
      coachingTone: "balanced",
      preferredWorkoutTime: workoutTimeOfDay(preferredTime),
      dislikedExercises: [],
      // Not asked any more: the coach picks the structure from the answers.
      trainingFocus: draft.trainingFocus !== undefined
        ? normalizeTrainingFocus(draft.trainingFocus)
        : recommendTrainingFocus({ ...draft, daysPerWeek: preferredDays.length || draft.daysPerWeek }),
      coachingLens: normalizeCoachingLens(draft.coachingLens),
    },
    dietaryConstraints: draft.dietaryConstraints ?? [],
    onboardingStatus: "proposal_ready",
    onboardingStep: "review_plan",
    onboardingMissingFields: [],
    createdAt: now,
    updatedAt: now,
  });

  // The focus answer lives under preferences; the builder reads it from the
  // top level. Passing the profile straight through dropped it, so every plan
  // fell back to the days-per-week rule whatever the user picked.
  const workoutPlan = buildWorkoutPlanFromProfile(
    userId,
    {
      ...profile,
      trainingFocus: profile.preferences.trainingFocus,
      // A doctor's limit: the gentlest starting loads, whatever they said.
      trainingExperience: clearanceAdvised ? "new" : profile.trainingExperience,
    },
    defaultPlan,
    now,
  );

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
    trainingFocus?: z.infer<typeof TrainingFocus>;
    // Fit the plan to what they have and how long they've trained.
    equipment?: string[];
    trainingExperience?: z.infer<typeof UserHealthProfile>["trainingExperience"];
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
      profile.trainingFocus,
      { equipment: profile.equipment, experience: profile.trainingExperience },
    ),
    updatedAt: now,
  });
}

/**
 * Which structure the plan takes. Onboarding recommends full-body for
 * three days or fewer (and for anyone new) and a split for five or more —
 * and until 2026-10-09 the generator ignored that answer and handed out
 * the seed's push/pull rotation regardless: "I recommend full-body" then a
 * Push day. The generator now follows the same rule as the recommendation.
 */
export function planStructure(
  focus: z.infer<typeof TrainingFocus> | undefined,
  daysPerWeek: number,
): "full_body" | "split" {
  switch (focus) {
    case "full_body":
    case "mobility_recovery":
    case "endurance_conditioning":
      return "full_body";
    case "muscle_split":
    case "strength_conditioning":
      return "split";
    default:
      return daysPerWeek <= 3 ? "full_body" : "split";
  }
}

export function selectPlanDays(
  defaultPlan: Record<string, PlannedWorkoutDayType>,
  daysPerWeek: number,
  preferredDays?: string[],
  focus?: z.infer<typeof TrainingFocus>,
  fit?: Parameters<typeof fitPlanToUser>[1],
) {
  const clamped = Math.max(1, Math.min(7, daysPerWeek));
  const trainingDays = pickTrainingDays(clamped, preferredDays);

  const seedDaysWithExercises = WEEK_ORDER.map((day) => defaultPlan[day]).filter(
    (value) => value && (value.exercises?.length ?? 0) > 0,
  );
  const sessions =
    planStructure(focus, clamped) === "full_body"
      ? fullBodySessions(seedDaysWithExercises)
      : splitSessions(seedDaysWithExercises);

  const restDay = { name: "Rest", muscles: [], exercises: [] };
  const selected = Object.fromEntries(
    WEEK_ORDER.map((day) => {
      const trainingIdx = trainingDays.indexOf(day);
      if (trainingIdx === -1) return [day, restDay];
      // Modulo so we wrap when daysPerWeek > session count.
      const session = sessions[trainingIdx % sessions.length];
      return [day, session ?? restDay];
    }),
  ) as Record<string, PlannedWorkoutDayType>;
  // Fitted to their equipment and experience BEFORE progression attaches, so
  // a swapped-in lift gets its own rule, not the one it replaced.
  const fitted = fit ? fitPlanToUser(selected, fit) : selected;
  // Every loaded exercise the catalog knows gets a progression rule, so the
  // plan actually moves week to week (see workouts/progressionDefaults.ts).
  return attachDefaultProgression(fitted).days;
}

function isLegsDay(day: PlannedWorkoutDayType) {
  return day.muscles.some((m) => /leg|glute|quad|hamstring/i.test(m)) || /leg/i.test(day.name);
}
function isPushDay(day: PlannedWorkoutDayType) {
  return day.muscles.some((m) => /chest|shoulder/i.test(m)) || /push/i.test(day.name);
}
function isPullDay(day: PlannedWorkoutDayType) {
  return day.muscles.some((m) => /back/i.test(m)) || /pull/i.test(day.name);
}

/**
 * The seed's distinct days (the seed pads Sat/Sun with a copy of Friday)
 * in an order a coach would prescribe: a legs day inside the first three,
 * so a three-day split is push / pull / legs and not push / pull / push.
 */
function splitSessions(seedDays: PlannedWorkoutDayType[]): PlannedWorkoutDayType[] {
  const unique: PlannedWorkoutDayType[] = [];
  const seen = new Set<string>();
  for (const day of seedDays) {
    const key = `${day.name}|${day.exercises.map((e) => e.name).join(",")}`;
    if (!seen.has(key)) {
      seen.add(key);
      unique.push(day);
    }
  }
  const legsIdx = unique.findIndex(isLegsDay);
  if (legsIdx > 2) {
    const [legs] = unique.splice(legsIdx, 1);
    unique.splice(2, 0, legs);
  }
  return unique.length ? unique : seedDays;
}

/**
 * Full-body sessions built from the seed: each takes a lower-body lift, a
 * push, a pull and a core or carry move from different seed days, rotating
 * through them so A, B and C differ. Sets, reps and weights come with the
 * exercise from the seed, so progression rules still attach.
 */
function fullBodySessions(seedDays: PlannedWorkoutDayType[]): PlannedWorkoutDayType[] {
  const pool = (pick: (d: PlannedWorkoutDayType) => boolean) =>
    seedDays.filter(pick).flatMap((d) => d.exercises);
  const legs = pool(isLegsDay);
  const push = pool(isPushDay);
  const pull = pool(isPullDay);
  const core = seedDays.flatMap((d) => d.exercises).filter((e) => /plank|leg raise|carry|dead bug|bird.?dog/i.test(e.name));
  // Nothing to compose from (a seed with no legs or no push day): fall
  // back to the split so the user still gets a plan.
  if (!legs.length || !push.length || !pull.length) return splitSessions(seedDays);

  // Compounds first in each pool: the seed lists them first on each day,
  // and the big lift should open the session.
  const nth = <T,>(list: T[], i: number) => list[i % list.length];
  const sessions: PlannedWorkoutDayType[] = [];
  const count = Math.min(3, Math.max(legs.length, push.length, pull.length));
  const seen = new Set<string>();
  for (let i = 0; i < count; i += 1) {
    const picks = [nth(legs, i), nth(push, i), nth(pull, i), core.length ? nth(core, i) : undefined]
      .filter((e): e is NonNullable<typeof e> => Boolean(e));
    const key = picks.map((e) => e.name).join(",");
    if (seen.has(key)) continue;
    seen.add(key);
    sessions.push({
      name: `Full body · ${String.fromCharCode(65 + sessions.length)}`,
      muscles: ["Legs", "Chest", "Back", "Core"],
      exercises: picks,
    });
  }
  return sessions;
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

/** "34", "thirty"-free: a number; or a band chip ("18–39") → its middle. */
function parseAge(value: string): number | undefined {
  const band = value.match(/(\d{2})\s*[–-]\s*(\d{2})/);
  if (band) return Math.round((Number(band[1]) + Number(band[2])) / 2);
  const plus = value.match(/(\d{2})\s*\+/);
  if (plus) return Number(plus[1]) + 5;
  const n = parseNumber(value);
  return n !== undefined && Number.isInteger(n) && n >= 13 && n <= 120 ? n : undefined;
}

const DAY_WORDS: Array<[RegExp, (typeof WEEK_ORDER)[number]]> = [
  [/\bmon(day)?s?\b/, "Mon"],
  [/\btue(s|sday)?s?\b/, "Tue"],
  [/\bwed(nesday)?s?\b/, "Wed"],
  [/\bthu(r|rs|rsday)?s?\b/, "Thu"],
  [/\bfri(day)?s?\b/, "Fri"],
  [/\bsat(urday)?s?\b/, "Sat"],
  [/\bsun(day)?s?\b/, "Sun"],
];

/** "Mon, Wed, Fri", "weekdays", "3 days" → training days in week order. */
export function parseDays(value: string): string[] {
  const lower = value.toLowerCase();
  if (/\b(every ?day|daily)\b/.test(lower)) return [...WEEK_ORDER];
  const days = new Set<string>();
  if (/\bweekdays?\b/.test(lower)) ["Mon", "Tue", "Wed", "Thu", "Fri"].forEach((d) => days.add(d));
  if (/\bweekends?\b/.test(lower)) ["Sat", "Sun"].forEach((d) => days.add(d));
  for (const [pattern, day] of DAY_WORDS) if (pattern.test(lower)) days.add(day);
  if (days.size === 0) {
    const count = lower.match(/\b([1-7])\s*(x|times|days?)\b/);
    if (count) return CANONICAL_TRAINING_DAYS[Number(count[1])] ?? [];
  }
  return WEEK_ORDER.filter((d) => days.has(d));
}

/** "6pm", "6:30", "after work", "mornings" → "HH:MM", or undefined. */
export function parseTime(value: string): string | undefined {
  const lower = value.toLowerCase();
  const clock = lower.match(/\b(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?(?!\s*(x|times|days?))\b/);
  // A bare digit that's really a day count ("3 days") isn't a time.
  if (clock && (clock[2] || clock[3] || /\bat\s+\d/.test(lower))) {
    let hour = Number(clock[1]);
    const minute = Number(clock[2] ?? 0);
    const meridiem = clock[3]?.replace(/\./g, "");
    if (meridiem === "pm" && hour < 12) hour += 12;
    if (meridiem === "am" && hour === 12) hour = 0;
    // "at 6" with no am/pm: people mean evening for 1–6, morning for 7–11.
    if (!meridiem && hour >= 1 && hour <= 6) hour += 12;
    if (hour <= 23 && minute <= 59) return `${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}`;
  }
  if (/\bmorning|before work|early\b/.test(lower)) return "07:00";
  if (/\blunch|noon|midday\b/.test(lower)) return "12:00";
  if (/\bafternoon\b/.test(lower)) return "15:00";
  if (/\bafter work|evening\b/.test(lower)) return "18:00";
  if (/\bnight\b/.test(lower)) return "20:00";
  return undefined;
}

function workoutTimeOfDay(time: string | undefined): "morning" | "afternoon" | "evening" | "flexible" {
  if (!time) return "flexible";
  const hour = Number(time.slice(0, 2));
  return hour < 11 ? "morning" : hour < 16 ? "afternoon" : "evening";
}

/** A yes to the doctor / chest pain / dizziness / fainting screen. */
export function needsClearance(value: string): boolean {
  return /\b(doctor|physician|cardiolog|chest pain|dizz|faint|pass(ed)? out|heart)/i.test(value);
}

/** A copy with every undefined value dropped, at any depth (Firestore rejects them). */
function withoutUndefined<T>(value: T): T {
  if (Array.isArray(value)) return value.map((item) => withoutUndefined(item)) as T;
  if (value && typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype) {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .filter(([, item]) => item !== undefined)
        .map(([key, item]) => [key, withoutUndefined(item)]),
    ) as T;
  }
  return value;
}
