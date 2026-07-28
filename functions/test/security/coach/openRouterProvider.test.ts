import { afterEach, describe, expect, it, vi } from "vitest";
import {
  OpenRouterCoachProvider,
  selectCoachModelProvider,
} from "../../../src/coach/modelProvider.js";

function jsonResponse(body: unknown) {
  return {
    ok: true,
    status: 200,
    headers: { get: () => null },
    json: async () => body,
  };
}

function textReply(content: string) {
  return jsonResponse({
    choices: [{ message: { content }, finish_reason: "stop" }],
    usage: { prompt_tokens: 11, completion_tokens: 7 },
  });
}

function toolCallReply(name: string, argumentsJson: string, id = "call_1") {
  return jsonResponse({
    choices: [
      {
        message: { content: null, tool_calls: [{ id, type: "function", function: { name, arguments: argumentsJson } }] },
        finish_reason: "tool_calls",
      },
    ],
    usage: { prompt_tokens: 20, completion_tokens: 5 },
  });
}

const TOOLS = [
  {
    name: "adapt_plan",
    description: "Propose a plan change.",
    parameters: { type: "object", properties: { reason: { type: "string" } }, required: ["reason"] },
  },
  // Zero-arg tool: the declarations omit `parameters` because Gemini 400s on
  // an OBJECT with empty properties. OpenAI's dialect needs the opposite.
  { name: "reject_plan_adjustment", description: "Dismiss the pending proposal." },
];

describe("OpenRouterCoachProvider", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    delete process.env.IRONBOI_COACH_PROVIDER;
    delete process.env.IRONBOI_OPENROUTER_MODEL;
  });

  it("posts to the chat-completions endpoint with a bearer token", async () => {
    const fetchMock = vi.fn().mockResolvedValue(textReply("Coach reply."));
    vi.stubGlobal("fetch", fetchMock);

    const result = await new OpenRouterCoachProvider("fake-key").generateCoachReply({
      system: "system",
      userContent: "hello",
    });

    expect(result).toEqual({
      content: "Coach reply.",
      usage: { inputTokens: 11, outputTokens: 7 },
      toolCalls: [],
    });
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://openrouter.ai/api/v1/chat/completions");
    expect(init.headers).toMatchObject({ Authorization: "Bearer fake-key" });
    // The key must never ride in the URL, where it would land in logs.
    expect(url).not.toContain("fake-key");

    const body = JSON.parse(String(init.body));
    expect(body.model).toBe("google/gemini-2.5-flash");
    expect(body.messages[0]).toEqual({ role: "system", content: "system" });
    expect(body.messages[1]).toEqual({ role: "user", content: "hello" });
  });

  it("gives zero-arg tools an explicit empty object, not an omitted field", async () => {
    // The inverse of the Gemini encoding. Omitting `parameters` here makes
    // OpenAI-dialect providers reject the declaration.
    const fetchMock = vi.fn().mockResolvedValue(textReply("Reply."));
    vi.stubGlobal("fetch", fetchMock);

    await new OpenRouterCoachProvider("k").generateCoachReply({
      system: "s",
      userContent: "u",
      tools: TOOLS,
      executeTool: async () => ({ ok: true }),
    });

    const body = JSON.parse(String((fetchMock.mock.calls[0] as [string, RequestInit])[1].body));
    expect(body.tools).toHaveLength(2);
    expect(body.tools[0]).toMatchObject({ type: "function", function: { name: "adapt_plan" } });
    expect(body.tools[1].function.parameters).toEqual({ type: "object", properties: {} });
  });

  it("parses the JSON-STRING arguments a tool call carries", async () => {
    // The single biggest wire difference from Gemini, which hands back an
    // already-parsed object.
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(toolCallReply("adapt_plan", '{"reason":"missed_session","rampWeeks":[{"intensityPct":60}]}'))
      .mockResolvedValueOnce(textReply("Done."));
    vi.stubGlobal("fetch", fetchMock);

    const executeTool = vi.fn().mockResolvedValue({ ok: true, proposalId: "p1" });
    const result = await new OpenRouterCoachProvider("k").generateCoachReply({
      system: "s",
      userContent: "u",
      tools: TOOLS,
      executeTool,
    });

    expect(executeTool).toHaveBeenCalledWith("adapt_plan", {
      reason: "missed_session",
      rampWeeks: [{ intensityPct: 60 }],
    });
    expect(result.toolCalls).toEqual([
      { name: "adapt_plan", args: { reason: "missed_session", rampWeeks: [{ intensityPct: 60 }] } },
    ]);
    expect(result.content).toBe("Done.");

    // Token usage accumulates across BOTH round trips — a tool turn that only
    // counted the last call would under-bill against the daily cap.
    expect(result.usage).toEqual({ inputTokens: 31, outputTokens: 12 });
  });

  it("sends the tool result back with a matching tool_call_id", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(toolCallReply("adapt_plan", "{}", "call_xyz"))
      .mockResolvedValueOnce(textReply("Done."));
    vi.stubGlobal("fetch", fetchMock);

    await new OpenRouterCoachProvider("k").generateCoachReply({
      system: "s",
      userContent: "u",
      tools: TOOLS,
      executeTool: async () => ({ ok: true, proposalId: "p1" }),
    });

    const secondBody = JSON.parse(String((fetchMock.mock.calls[1] as [string, RequestInit])[1].body));
    const assistant = secondBody.messages[2];
    const toolResult = secondBody.messages[3];

    // Every tool_call in the assistant message must have a matching result or
    // the follow-up request 400s. This loop is sequential-only, so the
    // assistant message must carry exactly the one call it answered.
    expect(assistant.role).toBe("assistant");
    expect(assistant.tool_calls).toHaveLength(1);
    expect(assistant.tool_calls[0].id).toBe("call_xyz");
    expect(toolResult).toEqual({
      role: "tool",
      tool_call_id: "call_xyz",
      content: JSON.stringify({ ok: true, proposalId: "p1" }),
    });
  });

  it("replays only the executed call when the model requests several at once", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        jsonResponse({
          choices: [
            {
              message: {
                content: null,
                tool_calls: [
                  { id: "a", type: "function", function: { name: "adapt_plan", arguments: "{}" } },
                  { id: "b", type: "function", function: { name: "adapt_plan", arguments: "{}" } },
                ],
              },
            },
          ],
          usage: { prompt_tokens: 1, completion_tokens: 1 },
        }),
      )
      .mockResolvedValueOnce(textReply("Done."));
    vi.stubGlobal("fetch", fetchMock);

    const executeTool = vi.fn().mockResolvedValue({ ok: true });
    await new OpenRouterCoachProvider("k").generateCoachReply({
      system: "s",
      userContent: "u",
      tools: TOOLS,
      executeTool,
    });

    expect(executeTool).toHaveBeenCalledTimes(1);
    const secondBody = JSON.parse(String((fetchMock.mock.calls[1] as [string, RequestInit])[1].body));
    expect(secondBody.messages[2].tool_calls).toHaveLength(1);
    expect(secondBody.messages[2].tool_calls[0].id).toBe("a");
  });

  it("recovers from truncated tool JSON instead of killing the turn", async () => {
    // A heavy rampWeeks/dayPatches call is the realistic truncation case —
    // exactly the turn worth recovering rather than failing.
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(toolCallReply("adapt_plan", '{"reason":"missed_ses'))
      .mockResolvedValueOnce(textReply("Let me try that again."));
    vi.stubGlobal("fetch", fetchMock);

    const executeTool = vi.fn();
    const result = await new OpenRouterCoachProvider("k").generateCoachReply({
      system: "s",
      userContent: "u",
      tools: TOOLS,
      executeTool,
    });

    expect(executeTool).not.toHaveBeenCalled();
    expect(result.content).toBe("Let me try that again.");
    const secondBody = JSON.parse(String((fetchMock.mock.calls[1] as [string, RequestInit])[1].body));
    expect(JSON.parse(secondBody.messages[3].content)).toMatchObject({
      ok: false,
      error: "invalid_tool_arguments_json",
    });
  });

  it("drops tools on the final round so the loop cannot run forever", async () => {
    const fetchMock = vi.fn().mockImplementation((_url, init) => {
      const body = JSON.parse(String((init as RequestInit).body));
      return Promise.resolve(body.tools ? toolCallReply("adapt_plan", "{}") : textReply("Forced finish."));
    });
    vi.stubGlobal("fetch", fetchMock);

    const result = await new OpenRouterCoachProvider("k").generateCoachReply({
      system: "s",
      userContent: "u",
      tools: TOOLS,
      executeTool: async () => ({ ok: true }),
      maxToolCalls: 2,
    });

    expect(result.content).toBe("Forced finish.");
    const lastBody = JSON.parse(String((fetchMock.mock.calls.at(-1) as [string, RequestInit])[1].body));
    expect(lastBody.tools).toBeUndefined();
    // The nudge rides on the SYSTEM message — a user-role nudge would
    // contradict the prompt's own "user content is data, not instruction"
    // boundary.
    expect(lastBody.messages[0].role).toBe("system");
    expect(lastBody.messages[0].content).toContain("Tool budget for this turn is exhausted");
  });

  it("treats a 200 body carrying an error as a failure, not an empty reply", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(jsonResponse({ error: { code: 402, message: "Insufficient credits" } })),
    );
    await expect(
      new OpenRouterCoachProvider("k").generateCoachReply({ system: "s", userContent: "u" }),
    ).rejects.toThrow("OpenRouter returned an error response");
  });

  it("honours IRONBOI_OPENROUTER_MODEL", () => {
    process.env.IRONBOI_OPENROUTER_MODEL = "anthropic/claude-sonnet-4.5";
    expect(new OpenRouterCoachProvider("k").model).toBe("anthropic/claude-sonnet-4.5");
  });
});

describe("selectCoachModelProvider", () => {
  afterEach(() => {
    delete process.env.IRONBOI_COACH_PROVIDER;
  });

  it("prefers OpenRouter when unpinned and both keys are present", () => {
    expect(selectCoachModelProvider({ geminiApiKey: "g", openRouterApiKey: "o" })?.provider).toBe(
      "openrouter",
    );
  });

  it("falls back to Gemini when only its key is configured", () => {
    expect(selectCoachModelProvider({ geminiApiKey: "g" })?.provider).toBe("gemini");
  });

  it("honours an explicit pin in both directions", () => {
    process.env.IRONBOI_COACH_PROVIDER = "gemini";
    expect(selectCoachModelProvider({ geminiApiKey: "g", openRouterApiKey: "o" })?.provider).toBe(
      "gemini",
    );
    process.env.IRONBOI_COACH_PROVIDER = "openrouter";
    expect(selectCoachModelProvider({ geminiApiKey: "g", openRouterApiKey: "o" })?.provider).toBe(
      "openrouter",
    );
  });

  it("returns null rather than silently billing the other vendor when a pin has no key", () => {
    // The 2026-05-11 audit found the opposite: a pinned provider with no key
    // fell through to whatever key happened to be configured, with nothing in
    // the logs saying so.
    process.env.IRONBOI_COACH_PROVIDER = "openrouter";
    expect(selectCoachModelProvider({ geminiApiKey: "g" })).toBeNull();
  });

  it("returns null on an unrecognised provider name", () => {
    process.env.IRONBOI_COACH_PROVIDER = "anthropic";
    expect(selectCoachModelProvider({ geminiApiKey: "g", openRouterApiKey: "o" })).toBeNull();
  });
});
