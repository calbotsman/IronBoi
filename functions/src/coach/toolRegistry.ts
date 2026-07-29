import type { Firestore } from "firebase-admin/firestore";
import {
  AcceptPlanAdjustmentToolRequest,
  AdaptPlanRequest,
  AskFollowUpQuestionRequest,
  ClearPlanOverridesToolRequest,
  RejectPlanAdjustmentToolRequest,
} from "../contracts/tool-calls.js";
import {
  acceptLatestPlanAdjustmentFromChat,
  createClearOverridesProposalFromTool,
  createPlanAdjustmentProposalFromTool,
  hasSevereMarkers,
  rejectLatestPlanAdjustmentFromChat,
} from "../workouts/planAdjustments.js";
import { safeLogger } from "../logging/safeLogger.js";
import type { ToolRegistry } from "../tools/executor.js";
import type { CoachToolDeclaration } from "./modelProvider.js";

// Gemini function declarations — a hand-written mirror of the Zod args
// schemas below. Gemini's function-calling API takes an OpenAPI-3.0-subset
// JSON Schema, not a Zod schema directly. tool-calls.ts stays the runtime
// source of truth: every call's args are re-validated against it before
// execution, regardless of what the model actually sent.
export const COACH_TOOL_DECLARATIONS: CoachToolDeclaration[] = [
  {
    name: "adapt_plan",
    description:
      "Propose a change to the user's workout plan (skip, shorten, or otherwise adjust a day) in response to something they said. This creates a review card the user must approve in the app — it never mutates the plan directly. If they haven't told you whether the change should apply to just that day or carry forward through the rest of their plan, omit `scope` here and ask them in your reply; call this again with `scope` once they answer (nothing is created until scope is known).",
    parameters: {
      type: "object",
      properties: {
        reason: {
          type: "string",
          enum: [
            "too_hard",
            "too_easy",
            "pain_or_discomfort",
            "time_constraint",
            "equipment_unavailable",
            "schedule_change",
            "missed_session",
            "returning_from_layoff",
          ],
          description:
            "missed_session = ONE session missed. returning_from_layoff = the user has been away long enough that resuming at full load is wrong ('I fell off', 'haven't trained in a few weeks', 'was travelling for a month') — pair it with rampWeeks. NOT for a layoff they are still unwell or in pain from; see the ramp guidance.",
        },
        userNote: {
          type: "string",
          description: "A short paraphrase of what the user said — shown on the review card.",
        },
        dayKey: {
          type: "string",
          enum: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
          description: "Defaults to today if omitted.",
        },
        exerciseName: { type: "string" },
        scope: {
          type: "string",
          enum: ["today", "rest_of_week", "going_forward", "reentry_ramp"],
          description:
            "Only set once the user has told you which they want. rest_of_week = the adjusted days apply this week only, then the plan reverts automatically. reentry_ramp is implied by rampWeeks — don't set it yourself, and never ask 'today or going forward?' about a ramp.",
        },
        rampWeeks: {
          type: "array",
          // Bounds mirrored from AdaptPlanRequest.rampWeeks. Without them the
          // model can't see the limits and its call is rejected by Zod before
          // the self-correcting hints ever run.
          minItems: 2,
          maxItems: 6,
          description:
            "A GRADED RETURN over several weeks — the right answer for returning_from_layoff. Index 0 is the rest of the user's current week, 1 the next calendar week, and so on. You author only the percentages and a short reason per week; the server builds every session by scaling the user's OWN plan, so don't send exercises. Must step up (never down) and the LAST week must be 100 so the plan actually returns to normal. 2–6 weeks. Typical: 3 weeks off → [60, 80, 100].",
          items: {
            type: "object",
            properties: {
              intensityPct: {
                type: "integer",
                minimum: 40,
                maximum: 100,
                description: "40–100. Percentage of the user's normal sets and load for that week.",
              },
              note: {
                type: "string",
                minLength: 1,
                maxLength: 120,
                description: "One short line the user will read on the card, e.g. 'Rebuild the movement pattern, leave reps in reserve.'",
              },
            },
            required: ["intensityPct", "note"],
          },
        },
        dayPatches: {
          type: "array",
          description:
            "Concrete replacement content for each day you're adjusting — real exercises with sets/reps/weight, not placeholders. Use for substitutions (e.g. a back-safe week, or a swap when the user's space or kit won't allow a movement). REQUIRED to make an equipment_unavailable / too_hard / too_easy proposal approvable: without it the card has nothing for the user to review and cannot be applied. Max 7 days.",
          items: {
            type: "object",
            properties: {
              dayKey: { type: "string", enum: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] },
              dayName: { type: "string", description: "Short workout title, e.g. 'Back-safe pull'." },
              replacementExercises: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    name: { type: "string" },
                    sets: { type: "integer" },
                    reps: { type: "integer" },
                    weight: { type: "number", description: "Pounds; 0 for bodyweight." },
                  },
                  required: ["name", "sets", "reps"],
                },
              },
            },
            required: ["dayKey", "dayName", "replacementExercises"],
          },
        },
        painTriage: {
          type: "object",
          description:
            "REQUIRED for pain_or_discomfort proposals to be appliable. Only set after you have ASKED the red-flag questions (sharp/shooting pain? numbness or tingling? pain radiating? recent trauma?) and the user answered. Never fabricate.",
          properties: {
            redFlagsAsked: {
              type: "boolean",
              description:
                "Must be true — set only after you ACTUALLY asked the red-flag questions. If you haven't asked yet, omit painTriage entirely and ask them first.",
            },
            userReportsSevere: { type: "boolean" },
            description: {
              type: "string",
              description: "The user's own words about the pain, briefly.",
            },
          },
          required: ["redFlagsAsked", "userReportsSevere", "description"],
        },
        recoveryDays: {
          type: "integer",
          description:
            "For pain adjustments: days until you should check back in (3–14). Defaults to 5.",
        },
      },
      required: ["reason", "userNote"],
    },
  },
  {
    name: "accept_plan_adjustment",
    description:
      "Apply the pending plan-change proposal the user is looking at. Call this ONLY when the user has clearly said yes to the proposed change in their latest message ('yes, update my training', 'do it', 'sounds good'). If they haven't said how far it should reach yet, pass scope only if they told you; if the result says scope_required, ask 'just that day, or going forward?' and call again with their answer. Never call this speculatively — an unprompted accept changes the user's real training plan.",
    parameters: {
      type: "object",
      properties: {
        scope: {
          type: "string",
          enum: ["today", "rest_of_week", "going_forward"],
          description: "Only if the user has said which they want.",
        },
      },
      required: [],
    },
  },
  {
    name: "reject_plan_adjustment",
    description:
      "Dismiss the pending plan-change proposal. Call when the user declines it ('no thanks', 'leave my plan alone'). If they want something different instead, don't reject — call adapt_plan with the new request (it replaces the old proposal automatically).",
    // No parameters on purpose: Gemini 400s OBJECT schemas with empty
    // properties, so zero-arg tools omit the field (provider also guards).
  },
  {
    name: "clear_plan_overrides",
    description:
      "Propose returning to the user's regular plan by removing temporary day adjustments (e.g. after an injury recovery window when the user says they feel better). Creates a review card / needs a yes like any other change.",
    parameters: {
      type: "object",
      properties: {
        userNote: {
          type: "string",
          description: "Why the plan is going back to normal, in the user's words.",
        },
      },
      required: ["userNote"],
    },
  },
  {
    name: "ask_follow_up_question",
    description:
      "End your turn on one specific clarifying question instead of guessing — use this when you need a detail before proposing a plan change or answering safely.",
    parameters: {
      type: "object",
      properties: {
        reason: {
          type: "string",
          enum: [
            "missing_profile",
            "ambiguous_goal",
            "possible_safety_issue",
            "plan_constraint",
            "consent_required",
          ],
        },
        question: { type: "string" },
      },
      required: ["reason", "question"],
    },
  },
];

// The envelope fields on ToolCallBase (toolCallId, requestedAt, tool
// literal) describe how a call is logged, not what the model sends —
// Gemini's function-calling protocol gives us only {name, args}. Validate
// just the domain args here.
const AdaptPlanArgs = AdaptPlanRequest.omit({ toolCallId: true, requestedAt: true, tool: true });
const AcceptPlanAdjustmentArgs = AcceptPlanAdjustmentToolRequest.omit({
  toolCallId: true,
  requestedAt: true,
  tool: true,
});
const RejectPlanAdjustmentArgs = RejectPlanAdjustmentToolRequest.omit({
  toolCallId: true,
  requestedAt: true,
  tool: true,
});
const ClearPlanOverridesArgs = ClearPlanOverridesToolRequest.omit({
  toolCallId: true,
  requestedAt: true,
  tool: true,
});
const AskFollowUpQuestionArgs = AskFollowUpQuestionRequest.omit({
  toolCallId: true,
  requestedAt: true,
  tool: true,
});

// Validation failures return {ok:false} so the model can retry — but they
// must NOT be silent to the operator: chronic malformed args (schema drift,
// a model update changing enum casing) would otherwise mean no proposals
// get created while the coach keeps telling users "I've set that up."
// Log issue paths only, never values (userNote is user/model content).
function logToolValidationFailure(userId: string, tool: string, issues: Array<{ path: PropertyKey[]; code: string }>) {
  safeLogger.warn("Coach tool args failed validation", {
    event: "coach_tool_args_invalid",
    userId,
    tool,
    errorDetail: issues
      .slice(0, 5)
      .map((issue) => `${issue.path.join(".")}:${issue.code}`)
      .join(","),
  });
}

export type CoachToolRegistryContext = {
  // The latest pending proposal AT TURN START (null if none). The accept
  // tool refuses anything newer — a proposal the model just created cannot
  // be accepted in the same turn; the user must say yes in a later message.
  latestPendingProposalId: string | null;
  // The user's local calendar date from the triggering message, when the
  // client sent one. Keys today-scope overrides to the user's day instead
  // of the server's timezone.
  clientDate?: string;
  // The RAW text of the user's triggering message — never model-authored.
  // The injury severe-screen and category coercion run over this so a model
  // paraphrase can't route around the triage gate.
  rawUserText?: string;
};

export function buildCoachToolRegistry(
  db: Firestore,
  context: CoachToolRegistryContext,
): ToolRegistry {
  return {
    adapt_plan: async (rawArgs) => {
      // executeTool injects userId onto every handler's args — strip it
      // before validating against AdaptPlanArgs, which doesn't declare it.
      const { userId, ...args } = rawArgs;
      const parsed = AdaptPlanArgs.safeParse(args);
      if (!parsed.success) {
        logToolValidationFailure(userId, "adapt_plan", parsed.error.issues);
        // The declaration types redFlagsAsked as boolean but the contract is
        // literal true — an honest "I haven't asked yet" attestation must get
        // guidance, not a dead-end error (this handler exists to make the
        // loop self-correcting).
        const redFlagsNotAsked = parsed.error.issues.some(
          (issue) =>
            issue.path.join(".") === "painTriage.redFlagsAsked",
        );
        if (redFlagsNotAsked) {
          return {
            ok: false,
            error: "invalid_adapt_plan_args",
            hint: "If you haven't asked the red-flag questions yet, ask them first and call adapt_plan WITHOUT painTriage; attest redFlagsAsked:true only after actually asking.",
          };
        }
        // Zod runs BEFORE validateReentryRamp, so a ramp that violates the
        // schema bounds (wrong week count, out-of-range percentage, overlong
        // note) never reaches the RAMP_HINTS table below. Without this the
        // model gets a bare "invalid_adapt_plan_args" and retries identically.
        if (parsed.error.issues.some((issue) => issue.path[0] === "rampWeeks")) {
          return {
            ok: false,
            error: "invalid_adapt_plan_args",
            hint: "rampWeeks must be 2–6 entries, each { intensityPct: 40–100 (integer), note: ≤120 chars }. It must step up, never down, and the last entry must be 100.",
          };
        }
        return { ok: false, error: "invalid_adapt_plan_args" };
      }
      const result = await createPlanAdjustmentProposalFromTool({
        db,
        userId,
        reason: parsed.data.reason,
        userNote: parsed.data.userNote,
        dayKey: parsed.data.dayKey,
        exerciseName: parsed.data.exerciseName,
        scope: parsed.data.scope,
        dayPatches: parsed.data.dayPatches,
        painTriage: parsed.data.painTriage,
        recoveryDays: parsed.data.recoveryDays,
        rampWeeks: parsed.data.rampWeeks,
        rawUserText: context.rawUserText,
        clientDate: context.clientDate,
      });
      // Arg SHAPE only (no content) — the 2026-07-20 live E2E failures were
      // undiagnosable because nothing recorded whether the model sent
      // painTriage/dayPatches at all.
      safeLogger.info("adapt_plan proposal shaped", {
        event: "adapt_plan_shape",
        userId,
        category: result.category,
        riskLevel: result.riskLevel,
        requiresFollowUp: result.requiresFollowUp,
        scope: parsed.data.scope ?? null,
        dayPatchCount: parsed.data.dayPatches?.length ?? 0,
        hasPainTriage: Boolean(parsed.data.painTriage),
        rampWeekCount: parsed.data.rampWeeks?.length ?? 0,
        // Percentages only — the per-week `note` is model-authored text and
        // stays off the wire.
        rampShape: parsed.data.rampWeeks?.map((week) => week.intensityPct).join("-") ?? null,
        proposalId: "proposalId" in result ? result.proposalId : null,
      });

      // Self-correcting loop for ramps, same principle as the pain branch
      // below: a rejected ramp shape is a fixable authoring mistake, so tell
      // the model exactly what to change instead of returning a bare error
      // it will retry identically.
      const RAMP_HINTS: Record<string, string> = {
        ramp_must_end_at_full_intensity:
          "The LAST rampWeeks entry must be intensityPct: 100 — otherwise the user never actually returns to their normal plan. Re-send with a final 100% week.",
        ramp_intensity_must_not_decrease:
          "rampWeeks must step UP (or hold), never down. Re-send with non-decreasing intensityPct values.",
        ramp_needs_at_least_two_weeks:
          "A ramp needs at least 2 weeks (a reduced week, then a return). For a single reduced week use scope: rest_of_week instead.",
        ramp_first_week_must_be_reduced:
          "The FIRST rampWeeks entry must be below 100 — a ramp starting at full intensity changes nothing.",
        ramp_weeks_missing:
          "reason: returning_from_layoff needs rampWeeks. Re-send with 2–6 weeks of {intensityPct, note}, e.g. [{intensityPct:60,...},{intensityPct:80,...},{intensityPct:100,...}].",
        ramp_not_valid_while_unwell:
          "The user is still symptomatic from an illness. Do NOT propose a ramp — say plainly that returning to training while still unwell should be cleared with their clinician first, and keep the reply brief.",
        ramp_not_valid_for_this_category:
          "This user's own words describe pain or a pregnancy/postpartum context, so a ramp is the wrong tool — it scales their existing plan down but cannot work AROUND anything. Follow the pain triage instead: ask the red-flag questions, then call adapt_plan with dayPatches containing substitute exercises.",
        ramp_requires_reentry_ramp_scope:
          "Don't set `scope` when sending rampWeeks — the ramp implies its own scope. Re-send without the scope field.",
        reentry_ramp_scope_requires_ramp_weeks:
          "scope: reentry_ramp is only valid together with rampWeeks. Either send rampWeeks, or pick a different scope.",
        ramp_has_no_training_days_to_scale:
          "The user's plan has no training days left inside the ramp's reduced weeks, so there is nothing to scale down. Check the plan before proposing a ramp.",
      };
      if ("error" in result && result.error && RAMP_HINTS[result.error]) {
        return { ok: false, error: result.error, hint: RAMP_HINTS[result.error] };
      }
      // Self-correcting loop: a pain proposal that lands locked tells the
      // model WHY in the tool result, so it can re-call adapt_plan with the
      // missing fields in the SAME turn instead of presenting a dead-end
      // card. Prompt-level nudges alone failed twice on live E2E — the
      // model kept omitting painTriage even after asking the red-flag
      // questions.
      if (
        "proposalId" in result &&
        result.proposalId &&
        result.category === "injury_pain" &&
        result.riskLevel === "high"
      ) {
        // Severe screen first: when the ABSOLUTE screen (or a reported red
        // flag) is what locked the proposal, no retry can ever make it
        // appliable — promising one would burn tool rounds on a dead end.
        // Same joined-text shape the risk resolution itself screens.
        const severeLocked =
          parsed.data.painTriage?.userReportsSevere === true ||
          hasSevereMarkers(
            [
              parsed.data.userNote ?? "",
              parsed.data.painTriage?.description ?? "",
              context.rawUserText ?? "",
            ].join(". "),
          );
        const missing: string[] = [];
        if (!parsed.data.painTriage) {
          missing.push(
            "painTriage (attest the red-flag answers you already collected: redFlagsAsked, userReportsSevere, description in the user's words)",
          );
        }
        if (!parsed.data.dayPatches?.length) {
          missing.push("dayPatches (concrete substitute exercises for each adjusted day)");
        }
        return {
          ok: true,
          ...result,
          proposalLocked: true,
          lockReason:
            !severeLocked && missing.length
              ? `Proposal saved but HIGH RISK and NOT appliable — missing: ${missing.join("; ")}. If the user has ALREADY answered the red-flag questions and denied all red flags, call adapt_plan again NOW with the missing fields filled in — the new proposal replaces this one and becomes approvable. If they haven't answered yet, ask the red-flag questions first.`
              : "Proposal saved but HIGH RISK — either the user's words contain a severe symptom marker or they reported a red flag. Do NOT retry; keep the reply brief and recommend a clinician.",
        };
      }
      return { ok: true, ...result };
    },
    clear_plan_overrides: async (rawArgs) => {
      const { userId, ...args } = rawArgs;
      const parsed = ClearPlanOverridesArgs.safeParse(args);
      if (!parsed.success) {
        logToolValidationFailure(userId, "clear_plan_overrides", parsed.error.issues);
        return { ok: false, error: "invalid_clear_plan_overrides_args" };
      }
      const result = await createClearOverridesProposalFromTool({
        db,
        userId,
        userNote: parsed.data.userNote,
      });
      return { ok: true, ...result };
    },
    accept_plan_adjustment: async (rawArgs) => {
      const { userId, ...args } = rawArgs;
      const parsed = AcceptPlanAdjustmentArgs.safeParse(args);
      if (!parsed.success) {
        logToolValidationFailure(userId, "accept_plan_adjustment", parsed.error.issues);
        return { ok: false, error: "invalid_accept_plan_adjustment_args" };
      }
      const result = await acceptLatestPlanAdjustmentFromChat(
        db,
        userId,
        parsed.data.scope,
        context.latestPendingProposalId,
        context.clientDate,
      );
      safeLogger.info("Chat-driven plan adjustment decision", {
        event: "plan_adjustment_chat_accept",
        userId,
        outcome: result.ok ? "accepted" : result.error,
      });
      return result;
    },
    reject_plan_adjustment: async (rawArgs) => {
      const { userId, ...args } = rawArgs;
      const parsed = RejectPlanAdjustmentArgs.safeParse(args);
      if (!parsed.success) {
        logToolValidationFailure(userId, "reject_plan_adjustment", parsed.error.issues);
        return { ok: false, error: "invalid_reject_plan_adjustment_args" };
      }
      return rejectLatestPlanAdjustmentFromChat(db, userId);
    },
    ask_follow_up_question: (rawArgs) => {
      const { userId, ...args } = rawArgs;
      const parsed = AskFollowUpQuestionArgs.safeParse(args);
      if (!parsed.success) {
        logToolValidationFailure(userId, "ask_follow_up_question", parsed.error.issues);
        return { ok: false, error: "invalid_ask_follow_up_question_args" };
      }
      return { ok: true, renderedQuestion: parsed.data.question };
    },
  };
}
