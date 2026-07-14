import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { safeLogger } from "../logging/safeLogger.js";
import { recordAuditEventBestEffort } from "../audit/log.js";
import { coachSessionMessagePath } from "../paths.js";
import {
  checkDailyUsageCap,
  markDailyUsageCapReached,
  recordCoachTurnUsage,
  usagePath,
} from "../usage/cap.js";
import { loadCoachContext } from "./context.js";
import { buildCoachContextBundle } from "./contextBundle.js";
import { retrieveResearchCorpus } from "../corpus/researchCorpus.js";
import { selectCoachModelProvider, type CoachToolExecutor } from "./modelProvider.js";
import { assembleCoachPrompt, type CoachConfig } from "./prompt.js";
import {
  classifyUserMessage,
  refusalForVerdict,
  type SafetyVerdict,
} from "./safety.js";
import { COACH_TOOL_DECLARATIONS, buildCoachToolRegistry } from "./toolRegistry.js";
import { executeTool } from "../tools/executor.js";

// Feature-flagged so the new Gemini function-calling loop (adapt_plan,
// ask_follow_up_question) can ship dark and run alongside the existing
// deterministic classifier (workouts/planAdjustments.ts's
// maybeCreatePlanAdjustmentProposal, still called from sendCoachMessageHttp)
// for a release before that classifier is retired. Both paths write to the
// same planAdjustmentProposals collection, so either can be reviewed
// side-by-side in the proposal history during the overlap period.
function isCoachToolLoopEnabled(): boolean {
  return process.env.IRONBOI_COACH_TOOL_LOOP_ENABLED === "true";
}

type OrchestrateCoachTurnArgs = {
  db: Firestore;
  coach: CoachConfig;
  userId: string;
  sessionId: string;
  messageId: string;
  turnId: string;
  userContent: string;
  geminiApiKey?: string;
};

// Phase 1 Task 1.4 — abort the in-flight model call 5s before the function's
// own timeout (60s, set on the trigger config in index.ts). This gives us
// enough budget to write a clean "model_timeout" doc instead of letting the
// platform kill the function mid-write.
const COACH_MODEL_TIMEOUT_MS = 55_000;

function terminalStatusFor(verdict: SafetyVerdict) {
  return verdict.riskTier === "blocked" ? "blocked" : "complete";
}

function isAbortError(error: unknown): boolean {
  return (
    error instanceof Error &&
    (error.name === "AbortError" || error.name === "DOMException")
  );
}

export async function orchestrateCoachTurn({
  db,
  coach,
  userId,
  sessionId,
  messageId,
  turnId,
  userContent,
  geminiApiKey,
}: OrchestrateCoachTurnArgs) {
  const assistantMessageId = `${messageId}_coach`;
  const assistantRef = db.doc(
    coachSessionMessagePath(userId, sessionId, assistantMessageId),
  );
  const existing = await assistantRef.get();
  if (existing.exists && ["streaming", "complete", "blocked"].includes(existing.get("status"))) {
    return;
  }

  const preflight = classifyUserMessage(userContent);
  if (preflight.riskTier === "blocked") {
    const refusal = refusalForVerdict(preflight);
    await assistantRef.set({
      messageId: assistantMessageId,
      role: "coach",
      content: refusal.content,
      timestamp: new Date().toISOString(),
      riskLevel: "blocked",
      toolCallIds: [],
      status: "blocked",
      turnId,
      requiredUserAction: refusal.requiredUserAction,
      preflightCategory: preflight.category,
      sourceMessageId: messageId,
      serverCreatedAt: FieldValue.serverTimestamp(),
      serverCompletedAt: FieldValue.serverTimestamp(),
    });
    return;
  }

  await assistantRef.set({
    messageId: assistantMessageId,
    role: "coach",
    content: "",
    timestamp: new Date().toISOString(),
    riskLevel: preflight.riskTier === "high" ? "high" : "low",
    toolCallIds: [],
    status: "streaming",
    turnId,
    preflightCategory: preflight.category,
    sourceMessageId: messageId,
    serverCreatedAt: FieldValue.serverTimestamp(),
  });

  try {
    const usageCap = await checkDailyUsageCap(db, userId);
    if (!usageCap.allowed) {
      await markDailyUsageCapReached(db.doc(usagePath(userId, usageCap.dateKey)), usageCap.reason);
      await assistantRef.set(
        {
          content:
            "You've hit today's coach message limit. Your training data is still saved, and you can ask me more tomorrow.",
          status: "complete",
          riskLevel: "low",
          requiredUserAction: "none",
          usageCapReached: true,
          usageCapReason: usageCap.reason,
          serverCompletedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      safeLogger.warn("Coach daily usage cap reached", {
        event: "coach_daily_usage_cap_reached",
        userId,
        sessionId,
        messageId,
        turnId,
        outcome: usageCap.reason,
      });
      // Phase 3.4 — audit log. System-initiated, correlated to the coach
      // turn that hit the cap.
      await recordAuditEventBestEffort(db, {
        userId,
        eventType: "daily_spend_cap_reached",
        actor: "system",
        turnId,
        payload: { reason: usageCap.reason, dateKey: usageCap.dateKey },
      });
      return;
    }

    const toolLoopEnabled = isCoachToolLoopEnabled();
    const context = await loadCoachContext(db, userId, sessionId);
    const retrievedCorpus = retrieveResearchCorpus({
      userContent,
      profile: context.profile ?? null,
    });
    const contextBundle = buildCoachContextBundle(context, {
      userId,
      sessionId,
      retrievedCorpus,
    });
    const { system, userMessage } = assembleCoachPrompt(
      coach,
      contextBundle,
      userContent,
      { toolsEnabled: toolLoopEnabled },
    );
    const provider = selectCoachModelProvider({ geminiApiKey });

    if (!provider) {
      const fallback =
        "I have your message queued. A coach model is not configured in this environment yet, so I can sync your training data but cannot generate a full coach reply here.";
      await assistantRef.set(
        {
          content: fallback,
          status: "complete",
          riskLevel: preflight.riskTier === "high" ? "high" : "low",
          requiredUserAction:
            preflight.category === "injury_pain" ? "seek_clinician" : "none",
          serverCompletedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      return;
    }

    await assistantRef.set({
      modelProvider: provider.provider,
      model: provider.model,
    }, { merge: true });

    const modelAbort = new AbortController();
    const modelTimeoutHandle = setTimeout(() => {
      modelAbort.abort();
    }, COACH_MODEL_TIMEOUT_MS);

    const toolRegistry = toolLoopEnabled ? buildCoachToolRegistry(db) : undefined;
    const executeCoachTool: CoachToolExecutor | undefined = toolRegistry
      ? async (toolName, toolArgs) => {
          try {
            const toolResult = await executeTool(toolRegistry, toolName, toolArgs, {
              authenticatedUserId: userId,
            });
            return toolResult as Record<string, unknown>;
          } catch (error) {
            safeLogger.warn("Coach tool execution failed", {
              event: "coach_tool_execution_failed",
              userId,
              sessionId,
              messageId,
              turnId,
              tool: toolName,
              errorDetail: error instanceof Error ? error.message.slice(0, 200) : "unknown_error",
            });
            return { ok: false, error: "tool_execution_failed" };
          }
        }
      : undefined;

    let result;
    try {
      result = await provider.generateCoachReply({
        system,
        // Phase 1.1 — userContent on the wire is the XML-tagged userMessage,
        // not the raw user turn. The boundary contract is in `system`.
        userContent: userMessage,
        tools: toolLoopEnabled ? COACH_TOOL_DECLARATIONS : undefined,
        executeTool: executeCoachTool,
        signal: modelAbort.signal,
        onText: async (partialContent) => {
          await assistantRef.set(
            { content: partialContent, status: "streaming" },
            { merge: true },
          );
        },
      });
    } finally {
      clearTimeout(modelTimeoutHandle);
    }
    const content = result.content;
    await recordCoachTurnUsage(db, userId, usageCap.dateKey, result.usage);

    const postflight = classifyUserMessage(content);
    if (postflight.riskTier === "blocked") {
      const refusal = refusalForVerdict(postflight);
      await assistantRef.set(
        {
          content: refusal.content,
          status: "blocked",
          riskLevel: "blocked",
          requiredUserAction: refusal.requiredUserAction,
          postflightCategory: postflight.category,
          promptTokens: result.usage.inputTokens,
          completionTokens: result.usage.outputTokens,
          serverCompletedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      return;
    }

    // Surface the reviewed sources that grounded this turn so the iOS bubble
    // can show "Informed by …". These are the top retrieved corpus entries fed
    // to the model for this reply — the evidence base, not a parsed quote.
    const sources = retrievedCorpus.slice(0, 2).map((entry) => {
      const source: Record<string, string> = {
        entryId: entry.entryId,
        label: entry.sourceName,
        title: entry.title,
      };
      if (entry.sourceUrl) {
        source.sourceUrl = entry.sourceUrl;
      }
      return source;
    });

    await assistantRef.set(
      {
        content,
        status: terminalStatusFor(postflight),
        riskLevel: preflight.riskTier === "high" ? "high" : "low",
        requiredUserAction:
          preflight.category === "injury_pain" ? "seek_clinician" : "none",
        postflightCategory: postflight.category,
        sources,
        promptTokens: result.usage.inputTokens,
        completionTokens: result.usage.outputTokens,
        toolCallIds: result.toolCalls.map((call) => call.name),
        serverCompletedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  } catch (error) {
    const aborted = isAbortError(error);
    const errorCode = aborted ? "model_timeout" : "coach_orchestration_error";

    safeLogger.error("Coach turn error", {
      event: aborted ? "coach_model_timeout" : "coach_turn_error",
      userId,
      sessionId,
      messageId,
      turnId,
      errorCode,
      errorDetail: error instanceof Error ? error.message.slice(0, 300) : "unknown_error",
    });
    await assistantRef.set(
      {
        content: aborted
          ? "That reply took longer than I have to think. Your message is saved — try again or send a shorter version."
          : "I'm having trouble right now. Your message is saved, but I need you to try again in a moment.",
        status: "error",
        errorCode,
        serverCompletedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  }
}
