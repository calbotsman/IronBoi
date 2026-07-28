export type CoachToolDeclaration = {
  name: string;
  description: string;
  // OpenAPI-3.0-subset JSON Schema — the shape Gemini's function-calling
  // API expects. See coach/toolRegistry.ts for the declarations actually
  // used and the Zod schemas they mirror. Optional because zero-arg tools
  // must OMIT parameters on the wire (empty OBJECT properties → 400).
  parameters?: { properties?: Record<string, unknown> } & Record<string, unknown>;
};

// Always resolves — never throws. A tool failure (validation, Firestore
// error, whatever) becomes `{ok: false, error}` in the returned object so
// the model gets a function response it can react to, instead of the whole
// turn dying mid-loop.
export type CoachToolExecutor = (
  toolName: string,
  args: Record<string, unknown>,
) => Promise<Record<string, unknown>>;

import { safeLogger } from "../logging/safeLogger.js";

type GenerateCoachReplyArgs = {
  system: string;
  userContent: string;
  tools?: CoachToolDeclaration[];
  executeTool?: CoachToolExecutor;
  // Sequential tool-call round trips before the loop forces a text-only
  // finish. Matches the orchestration spec's cap (§5.5).
  maxToolCalls?: number;
  onText?: (content: string) => Promise<void>;
  // Phase 1 Task 1.4 — orchestrator may abort the in-flight model call when
  // the function timeout is about to fire. Providers MUST honor this signal.
  signal?: AbortSignal;
};

export type CoachModelUsage = {
  inputTokens: number;
  outputTokens: number;
};

export type GenerateCoachReplyResult = {
  content: string;
  usage: CoachModelUsage;
  toolCalls: Array<{ name: string; args: Record<string, unknown> }>;
};

export type CoachModelProvider = {
  provider: "gemini" | "openrouter";
  model: string;
  generateCoachReply(args: GenerateCoachReplyArgs): Promise<GenerateCoachReplyResult>;
};

type SelectCoachModelProviderArgs = {
  geminiApiKey?: string;
  openRouterApiKey?: string;
};

function estimateTokens(text: string) {
  return Math.ceil(text.length / 4);
}

const DEFAULT_MAX_TOOL_CALLS = 6;

type GeminiPart =
  | { text: string }
  | { functionCall: { name: string; args: Record<string, unknown> } }
  | { functionResponse: { name: string; response: Record<string, unknown> } };

// Gemini v1beta constrains Content.role to "user" | "model" — function
// responses ride as a functionResponse PART inside a user-role content
// (the part type carries the semantics, not the role). Some SDKs use a
// "function" role; the REST API's documented contract does not.
type GeminiContent = {
  role: "user" | "model";
  parts: GeminiPart[];
};

type GeminiResponsePayload = {
  candidates?: Array<{
    content?: {
      parts?: Array<{
        text?: string;
        functionCall?: { name: string; args?: Record<string, unknown> };
      }>;
    };
  }>;
  usageMetadata?: {
    promptTokenCount?: number;
    candidatesTokenCount?: number;
    totalTokenCount?: number;
  };
};

export class GeminiCoachProvider implements CoachModelProvider {
  provider = "gemini" as const;
  model = process.env.IRONBOI_COACH_MODEL || "gemini-2.5-flash";

  constructor(private readonly apiKey: string) {}

  private callGemini(
    system: string,
    contents: GeminiContent[],
    tools: CoachToolDeclaration[] | undefined,
    signal: AbortSignal | undefined,
  ): Promise<Response> {
    return fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${this.model}:generateContent`,
      {
        method: "POST",
        signal,
        headers: {
          "Content-Type": "application/json",
          "x-goog-api-key": this.apiKey,
        },
        body: JSON.stringify({
          systemInstruction: {
            parts: [{ text: system }],
          },
          contents,
          ...(tools && tools.length > 0
            ? {
                tools: [
                  {
                    // Gemini's v1beta API rejects OBJECT-typed parameters with
                    // empty `properties` (400 INVALID_ARGUMENT) — and tools
                    // ride on EVERY request, so one zero-arg declaration
                    // would brick every coach turn. Omit `parameters`
                    // entirely for tools that take no arguments.
                    functionDeclarations: tools.map((tool) => {
                      const properties = tool.parameters?.properties ?? {};
                      return Object.keys(properties).length > 0
                        ? tool
                        : { name: tool.name, description: tool.description };
                    }),
                  },
                ],
              }
            : {}),
          generationConfig: {
            // 900 was enough for prose, but a multi-day dayPatches
            // functionCall (7 days × exercises with sets/reps/weight) is
            // easily larger — truncated tool JSON shows up as malformed or
            // hallucinated calls (live E2E finding, 2026-07-17). Prose-only
            // turns keep the tighter cap.
            maxOutputTokens: tools && tools.length > 0 ? 2048 : 900,
            temperature: 0.4,
          },
          // Phase 1 Task 1.3 — explicit safety thresholds.
          // Defaults vary by model and tend to drift, so we pin them.
          // SEXUALLY_EXPLICIT is set lower than the others because a coach
          // context should never produce that category; the others are
          // BLOCK_MEDIUM_AND_ABOVE so legitimate fitness vocabulary
          // (rep failure, fatigue, "destroy a workout") doesn't trip.
          safetySettings: [
            {
              category: "HARM_CATEGORY_DANGEROUS_CONTENT",
              threshold: "BLOCK_MEDIUM_AND_ABOVE",
            },
            {
              category: "HARM_CATEGORY_SEXUALLY_EXPLICIT",
              threshold: "BLOCK_LOW_AND_ABOVE",
            },
            {
              category: "HARM_CATEGORY_HARASSMENT",
              threshold: "BLOCK_MEDIUM_AND_ABOVE",
            },
            {
              category: "HARM_CATEGORY_HATE_SPEECH",
              threshold: "BLOCK_MEDIUM_AND_ABOVE",
            },
          ],
        }),
      },
    );
  }

  // Gemini returns 429/500/503 when the model is momentarily overloaded.
  // Retry transient failures with backoff (within the orchestrator's 55s
  // budget) instead of failing the whole coach turn on a blip.
  private async callGeminiWithRetry(
    system: string,
    contents: GeminiContent[],
    tools: CoachToolDeclaration[] | undefined,
    signal: AbortSignal | undefined,
  ): Promise<GeminiResponsePayload> {
    const TRANSIENT_STATUS = new Set([429, 500, 503]);
    // 5 attempts with jittered/backed-off waits fits inside the
    // orchestrator's 55s abort budget even in the worst case (~15s of
    // waiting + request time). The live E2E run (2026-07-17) showed bursts
    // of transient failures exhausting the old 3-attempt/6.5s window
    // exactly on the heaviest tool-call turns.
    const MAX_ATTEMPTS = 5;
    let response!: Response;
    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
      response = await this.callGemini(system, contents, tools, signal);
      if (response.ok || !TRANSIENT_STATUS.has(response.status) || attempt === MAX_ATTEMPTS) {
        break;
      }
      // Honor Retry-After when Gemini sends one (429s often do); otherwise
      // exponential-ish backoff with jitter to avoid thundering re-hits.
      const retryAfterHeader = Number(response.headers.get("retry-after"));
      const retryAfterMs =
        Number.isFinite(retryAfterHeader) && retryAfterHeader > 0
          ? Math.min(retryAfterHeader * 1000, 8000)
          : attempt * 1200 + Math.floor(Math.random() * 600);
      safeLogger.warn("Gemini transient failure, retrying", {
        event: "gemini_transient_retry",
        outcome: `http_${response.status}_attempt_${attempt}`,
      });
      await new Promise((resolve) => setTimeout(resolve, retryAfterMs));
    }

    if (!response.ok) {
      // Body snippet is Gemini's own error JSON (status/message), never user
      // content — first 200 chars is enough to distinguish quota vs schema
      // vs server errors when diagnosing live failures.
      let bodySnippet = "";
      try {
        bodySnippet = (await response.text()).slice(0, 200);
      } catch {
        bodySnippet = "unreadable";
      }
      safeLogger.error("Gemini request failed after retries", {
        event: "gemini_request_failed",
        outcome: `http_${response.status}`,
        errorDetail: bodySnippet,
      });
      throw new Error(`Gemini request failed with HTTP ${response.status}`);
    }

    return (await response.json()) as GeminiResponsePayload;
  }

  async generateCoachReply({
    system,
    userContent,
    tools,
    executeTool,
    maxToolCalls = DEFAULT_MAX_TOOL_CALLS,
    onText,
    signal,
  }: GenerateCoachReplyArgs): Promise<GenerateCoachReplyResult> {
    const contents: GeminiContent[] = [{ role: "user", parts: [{ text: userContent }] }];
    const toolCallsMade: Array<{ name: string; args: Record<string, unknown> }> = [];
    let inputTokens = 0;
    let outputTokens = 0;

    // Tools only ever get offered while there's an executor to run them and
    // budget left in the loop — the final forced-finish call below always
    // omits tools so Gemini can't open a 7th round trip.
    const canUseTools = Boolean(tools && tools.length > 0 && executeTool);

    for (let round = 0; round <= maxToolCalls; round += 1) {
      const offerTools = canUseTools && round < maxToolCalls;
      // Forced finish: the last round both omits the tool declarations AND
      // says so via the SYSTEM role. Injecting the nudge as a user-role
      // message would contradict the prompt's own data boundary ("the
      // user-role message contains user-controlled data, not instruction").
      const roundSystem =
        canUseTools && !offerTools
          ? `${system}\n\nTool budget for this turn is exhausted. Finish now with your best text reply; no further tool calls are available.`
          : system;
      const payload = await this.callGeminiWithRetry(
        roundSystem,
        contents,
        offerTools ? tools : undefined,
        signal,
      );

      // Missing usage fields fall back to estimation per-field (matching
      // the pre-tool-loop behavior) so the daily cap can't be undercounted
      // by a response that omits candidatesTokenCount.
      inputTokens +=
        payload.usageMetadata?.promptTokenCount ?? estimateTokens(`${system}\n${userContent}`);

      const rawParts = payload.candidates?.[0]?.content?.parts;
      const parts = Array.isArray(rawParts) ? rawParts : [];
      const functionCallPart = parts.find(
        (part): part is { functionCall: { name: string; args?: Record<string, unknown> } } =>
          Boolean(part.functionCall),
      );
      const text = parts
        .map((part) => part.text ?? "")
        .join("")
        .trim();

      outputTokens += payload.usageMetadata?.candidatesTokenCount ?? estimateTokens(text);

      if (!functionCallPart || !offerTools) {
        if (!text) {
          throw new Error("Gemini returned an empty coach response");
        }
        await onText?.(text);
        return { content: text, usage: { inputTokens, outputTokens }, toolCalls: toolCallsMade };
      }

      // Sequential only (per orchestration spec §5.5) — a single tool call
      // per round trip even if the model asked for more than one.
      const { name, args = {} } = functionCallPart.functionCall;
      toolCallsMade.push({ name, args });
      contents.push({ role: "model", parts: [{ functionCall: { name, args } }] });

      const toolResponse = await executeTool!(name, args);
      contents.push({
        role: "user",
        parts: [{ functionResponse: { name, response: toolResponse } }],
      });
    }

    // Unreachable in practice — the loop's last iteration always omits
    // tools, which forces a text response or throws above. Kept as a
    // defensive exhaustiveness guard.
    throw new Error("Gemini tool loop exited without a final reply");
  }
}

// OpenRouter speaks the OpenAI /chat/completions dialect, so the whole
// provider is a translation layer over the same tool loop. Three differences
// from Gemini are load-bearing and each has bitten someone before:
//
//   1. `function.arguments` arrives as a JSON *STRING*, not a parsed object
//      like Gemini's `functionCall.args`. A truncated or malformed tool call
//      therefore fails at JSON.parse rather than at validation — handled as a
//      tool error the model can correct, never a thrown turn.
//   2. Zero-arg tools INVERT. Gemini 400s on an OBJECT with empty
//      `properties`, so the declarations omit `parameters` entirely; OpenAI's
//      dialect wants the explicit empty object. Same declaration, opposite
//      encoding.
//   3. Every tool_call in an assistant message MUST get a matching tool
//      result or the next request 400s. This loop is sequential-only by
//      policy (one call per round), so the assistant message is rewritten to
//      carry ONLY the call actually executed.
//
// Safety note: `safetySettings` has no OpenRouter equivalent and is dropped.
// That is not a safety regression — the real gates are server-side and
// provider-independent: the pre/postflight classifier (coach/safety.ts), the
// deterministic severe screen, and the pain-triage gate.
const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";

type OpenRouterToolCall = {
  id: string;
  type: "function";
  function: { name: string; arguments: string };
};

type OpenRouterMessage =
  | { role: "system" | "user"; content: string }
  | { role: "assistant"; content: string | null; tool_calls?: OpenRouterToolCall[] }
  | { role: "tool"; tool_call_id: string; content: string };

type OpenRouterResponsePayload = {
  choices?: Array<{
    message?: { content?: string | null; tool_calls?: OpenRouterToolCall[] };
    finish_reason?: string;
  }>;
  usage?: { prompt_tokens?: number; completion_tokens?: number };
  // OpenRouter can report upstream failures in a 200 body rather than an
  // HTTP status — a 200 with no choices and an `error` is a real failure and
  // must not be mistaken for an empty reply.
  error?: { code?: number | string; message?: string };
};

export class OpenRouterCoachProvider implements CoachModelProvider {
  provider = "openrouter" as const;
  // Deliberately a SEPARATE env var from IRONBOI_COACH_MODEL. Model ids are
  // namespaced here ("google/gemini-2.5-flash"), and a bare Gemini name left
  // over in the shared var would 400 every single turn.
  model = process.env.IRONBOI_OPENROUTER_MODEL || "google/gemini-2.5-flash";

  constructor(private readonly apiKey: string) {}

  private callOpenRouter(
    messages: OpenRouterMessage[],
    tools: CoachToolDeclaration[] | undefined,
    signal: AbortSignal | undefined,
  ): Promise<Response> {
    return fetch(OPENROUTER_URL, {
      method: "POST",
      signal,
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.apiKey}`,
        // Optional attribution headers — they identify the app on
        // OpenRouter's dashboard so this traffic is distinguishable from the
        // studio's when reading spend.
        "HTTP-Referer": "https://ironboi.app",
        "X-Title": "MYO Coach",
      },
      body: JSON.stringify({
        model: this.model,
        messages,
        ...(tools && tools.length > 0
          ? {
              tools: tools.map((tool) => ({
                type: "function" as const,
                function: {
                  name: tool.name,
                  description: tool.description,
                  // The inverse of the Gemini encoding — see (2) above.
                  parameters: tool.parameters ?? { type: "object", properties: {} },
                },
              })),
            }
          : {}),
        // Same reasoning as the Gemini provider: a multi-day dayPatches or a
        // 6-week rampWeeks call is far larger than prose, and truncated tool
        // JSON surfaces as a malformed call rather than an obvious error.
        max_tokens: tools && tools.length > 0 ? 2048 : 900,
        temperature: 0.4,
      }),
    });
  }

  private async callOpenRouterWithRetry(
    messages: OpenRouterMessage[],
    tools: CoachToolDeclaration[] | undefined,
    signal: AbortSignal | undefined,
  ): Promise<OpenRouterResponsePayload> {
    const TRANSIENT_STATUS = new Set([429, 500, 502, 503, 524]);
    const MAX_ATTEMPTS = 5;
    let response!: Response;
    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
      response = await this.callOpenRouter(messages, tools, signal);
      if (response.ok || !TRANSIENT_STATUS.has(response.status) || attempt === MAX_ATTEMPTS) {
        break;
      }
      const retryAfterHeader = Number(response.headers.get("retry-after"));
      const retryAfterMs =
        Number.isFinite(retryAfterHeader) && retryAfterHeader > 0
          ? Math.min(retryAfterHeader * 1000, 8000)
          : attempt * 1200 + Math.floor(Math.random() * 600);
      safeLogger.warn("OpenRouter transient failure, retrying", {
        event: "openrouter_transient_retry",
        outcome: `http_${response.status}_attempt_${attempt}`,
      });
      await new Promise((resolve) => setTimeout(resolve, retryAfterMs));
    }

    if (!response.ok) {
      let bodySnippet = "";
      try {
        bodySnippet = (await response.text()).slice(0, 200);
      } catch {
        bodySnippet = "unreadable";
      }
      safeLogger.error("OpenRouter request failed after retries", {
        event: "openrouter_request_failed",
        outcome: `http_${response.status}`,
        errorDetail: bodySnippet,
      });
      throw new Error(`OpenRouter request failed with HTTP ${response.status}`);
    }

    const payload = (await response.json()) as OpenRouterResponsePayload;
    if (payload.error && !payload.choices?.length) {
      safeLogger.error("OpenRouter returned an error body", {
        event: "openrouter_error_body",
        outcome: `code_${payload.error.code ?? "unknown"}`,
        errorDetail: String(payload.error.message ?? "").slice(0, 200),
      });
      throw new Error("OpenRouter returned an error response");
    }
    return payload;
  }

  async generateCoachReply({
    system,
    userContent,
    tools,
    executeTool,
    maxToolCalls = DEFAULT_MAX_TOOL_CALLS,
    onText,
    signal,
  }: GenerateCoachReplyArgs): Promise<GenerateCoachReplyResult> {
    const messages: OpenRouterMessage[] = [
      { role: "system", content: system },
      { role: "user", content: userContent },
    ];
    const toolCallsMade: Array<{ name: string; args: Record<string, unknown> }> = [];
    let inputTokens = 0;
    let outputTokens = 0;

    const canUseTools = Boolean(tools && tools.length > 0 && executeTool);

    for (let round = 0; round <= maxToolCalls; round += 1) {
      const offerTools = canUseTools && round < maxToolCalls;
      // Forced finish, same discipline as the Gemini provider: the last round
      // drops the declarations AND says so in the SYSTEM message, never as a
      // user-role message (that would contradict the prompt's own data
      // boundary — user-role content is data, not instruction).
      messages[0] = {
        role: "system",
        content:
          canUseTools && !offerTools
            ? `${system}\n\nTool budget for this turn is exhausted. Finish now with your best text reply; no further tool calls are available.`
            : system,
      };

      const payload = await this.callOpenRouterWithRetry(
        messages,
        offerTools ? tools : undefined,
        signal,
      );

      inputTokens +=
        payload.usage?.prompt_tokens ?? estimateTokens(`${system}\n${userContent}`);
      const message = payload.choices?.[0]?.message;
      const text = (message?.content ?? "").trim();
      outputTokens += payload.usage?.completion_tokens ?? estimateTokens(text);

      const call = message?.tool_calls?.[0];
      if (!call || !offerTools) {
        if (!text) {
          throw new Error("OpenRouter returned an empty coach response");
        }
        await onText?.(text);
        return { content: text, usage: { inputTokens, outputTokens }, toolCalls: toolCallsMade };
      }

      // Sequential only (orchestration spec §5.5). The assistant message is
      // rewritten to carry ONLY this call — replaying all of them while
      // answering one leaves unmatched tool_call_ids and the next request
      // 400s.
      messages.push({ role: "assistant", content: message?.content ?? null, tool_calls: [call] });

      let args: Record<string, unknown> = {};
      let argsValid = true;
      try {
        const parsed = JSON.parse(call.function.arguments || "{}");
        // A non-object (array, string, number) would sail past validation as
        // an empty arg set and silently produce a wrong proposal.
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
          args = parsed as Record<string, unknown>;
        } else {
          argsValid = false;
        }
      } catch {
        argsValid = false;
      }

      if (!argsValid) {
        // Hand it back as a tool RESULT rather than throwing: the loop is
        // self-correcting by design, and a truncated tool call on a heavy
        // rampWeeks/dayPatches turn is exactly the case worth recovering
        // from instead of failing the whole turn.
        safeLogger.warn("OpenRouter tool call had unparseable arguments", {
          event: "openrouter_tool_args_unparseable",
          tool: call.function.name,
        });
        messages.push({
          role: "tool",
          tool_call_id: call.id,
          content: JSON.stringify({
            ok: false,
            error: "invalid_tool_arguments_json",
            hint: "Your tool arguments were not valid JSON — likely truncated. Re-send the call with compact, complete JSON.",
          }),
        });
        continue;
      }

      toolCallsMade.push({ name: call.function.name, args });
      const toolResponse = await executeTool!(call.function.name, args);
      messages.push({
        role: "tool",
        tool_call_id: call.id,
        content: JSON.stringify(toolResponse),
      });
    }

    throw new Error("OpenRouter tool loop exited without a final reply");
  }
}

// Provider selection is EXPLICIT and fails loudly. The 2026-05-11 audit found
// the opposite pattern here — a pinned provider whose key was missing would
// silently fall through to whichever key happened to be configured, with no
// log line saying so. A misconfigured pin now returns null (the orchestrator
// tells the user to try again) instead of quietly billing a different vendor.
export function selectCoachModelProvider({
  geminiApiKey,
  openRouterApiKey,
}: SelectCoachModelProviderArgs): CoachModelProvider | null {
  const pinned = process.env.IRONBOI_COACH_PROVIDER?.trim().toLowerCase();

  if (pinned === "openrouter" || pinned === "gemini") {
    const key = pinned === "openrouter" ? openRouterApiKey : geminiApiKey;
    if (!key) {
      safeLogger.error("Pinned coach provider has no API key configured", {
        event: "coach_provider_key_missing",
        modelProvider: pinned,
      });
      return null;
    }
    return pinned === "openrouter"
      ? new OpenRouterCoachProvider(key)
      : new GeminiCoachProvider(key);
  }

  if (pinned) {
    safeLogger.error("Unknown IRONBOI_COACH_PROVIDER value", {
      event: "coach_provider_unknown",
      modelProvider: pinned,
    });
    return null;
  }

  // Unpinned: prefer OpenRouter when it's configured. One balance across
  // every model beats a per-project Google quota, which is what sent us here.
  if (openRouterApiKey) {
    return new OpenRouterCoachProvider(openRouterApiKey);
  }
  if (geminiApiKey) {
    return new GeminiCoachProvider(geminiApiKey);
  }
  return null;
}
