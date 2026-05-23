import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { safeLogger } from "../logging/safeLogger.js";
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
import { selectCoachModelProvider } from "./modelProvider.js";
import { assembleCoachSystemPrompt } from "./prompt.js";
import {
  classifyUserMessage,
  refusalForVerdict,
  type SafetyVerdict,
} from "./safety.js";

type OrchestrateCoachTurnArgs = {
  db: Firestore;
  coach: Record<string, unknown>;
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
      return;
    }

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
    const system = assembleCoachSystemPrompt(coach as never, contextBundle);
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

    let result;
    try {
      result = await provider.generateCoachReply({
        system,
        userContent,
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

    await assistantRef.set(
      {
        content,
        status: terminalStatusFor(postflight),
        riskLevel: preflight.riskTier === "high" ? "high" : "low",
        requiredUserAction:
          preflight.category === "injury_pain" ? "seek_clinician" : "none",
        postflightCategory: postflight.category,
        promptTokens: result.usage.inputTokens,
        completionTokens: result.usage.outputTokens,
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
