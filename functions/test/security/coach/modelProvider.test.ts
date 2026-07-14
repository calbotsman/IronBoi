import { afterEach, describe, expect, it, vi } from "vitest";
import { GeminiCoachProvider } from "../../../src/coach/modelProvider.js";

describe("GeminiCoachProvider", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("gemini_api_key_is_sent_in_header_not_url", async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        candidates: [{ content: { parts: [{ text: "Coach reply." }] } }],
        usageMetadata: {
          promptTokenCount: 11,
          candidatesTokenCount: 7,
        },
      }),
    });
    vi.stubGlobal("fetch", fetchMock);

    const provider = new GeminiCoachProvider("fake-gemini-key");
    const result = await provider.generateCoachReply({
      system: "system",
      userContent: "hello",
    });

    expect(result).toEqual({
      content: "Coach reply.",
      usage: { inputTokens: 11, outputTokens: 7 },
      toolCalls: [],
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe(
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
    );
    expect(url).not.toContain("?key=");
    expect(init.headers).toMatchObject({
      "Content-Type": "application/json",
      "x-goog-api-key": "fake-gemini-key",
    });
  });

  it("gemini_request_includes_explicit_safetySettings_for_all_four_categories", async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        candidates: [{ content: { parts: [{ text: "ok" }] } }],
        usageMetadata: { promptTokenCount: 1, candidatesTokenCount: 1 },
      }),
    });
    vi.stubGlobal("fetch", fetchMock);

    const provider = new GeminiCoachProvider("fake-gemini-key");
    await provider.generateCoachReply({ system: "system", userContent: "hi" });

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    const body = JSON.parse(init.body as string) as {
      safetySettings?: Array<{ category: string; threshold: string }>;
    };

    expect(body.safetySettings).toBeDefined();
    expect(body.safetySettings).toHaveLength(4);

    const byCategory = new Map(
      (body.safetySettings ?? []).map((s) => [s.category, s.threshold]),
    );
    expect(byCategory.get("HARM_CATEGORY_DANGEROUS_CONTENT")).toBe(
      "BLOCK_MEDIUM_AND_ABOVE",
    );
    expect(byCategory.get("HARM_CATEGORY_SEXUALLY_EXPLICIT")).toBe(
      "BLOCK_LOW_AND_ABOVE",
    );
    expect(byCategory.get("HARM_CATEGORY_HARASSMENT")).toBe(
      "BLOCK_MEDIUM_AND_ABOVE",
    );
    expect(byCategory.get("HARM_CATEGORY_HATE_SPEECH")).toBe(
      "BLOCK_MEDIUM_AND_ABOVE",
    );
  });

  it("gemini_request_threads_abort_signal_to_fetch", async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        candidates: [{ content: { parts: [{ text: "ok" }] } }],
        usageMetadata: { promptTokenCount: 1, candidatesTokenCount: 1 },
      }),
    });
    vi.stubGlobal("fetch", fetchMock);

    const controller = new AbortController();
    const provider = new GeminiCoachProvider("fake-gemini-key");
    await provider.generateCoachReply({
      system: "s",
      userContent: "u",
      signal: controller.signal,
    });

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(init.signal).toBe(controller.signal);
  });

  it("gemini_request_rejects_when_signal_aborts_mid_flight", async () => {
    const fetchMock = vi.fn().mockImplementation((_url, init: RequestInit) => {
      return new Promise((_, reject) => {
        // Honor abort even though we never resolve normally.
        init.signal?.addEventListener("abort", () => {
          const err = new Error("The operation was aborted.");
          err.name = "AbortError";
          reject(err);
        });
      });
    });
    vi.stubGlobal("fetch", fetchMock);

    const controller = new AbortController();
    const provider = new GeminiCoachProvider("fake-gemini-key");
    const pending = provider.generateCoachReply({
      system: "s",
      userContent: "u",
      signal: controller.signal,
    });

    controller.abort();

    await expect(pending).rejects.toThrowError(/abort/i);
  });

  it("gemini_tool_loop_executes_a_function_call_then_returns_the_final_text", async () => {
    const fetchMock = vi
      .fn()
      // First round: model asks to call a tool.
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          candidates: [
            {
              content: {
                parts: [{ functionCall: { name: "adapt_plan", args: { reason: "time_constraint" } } }],
              },
            },
          ],
          usageMetadata: { promptTokenCount: 20, candidatesTokenCount: 5 },
        }),
      })
      // Second round: model replies with final text after seeing the tool result.
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          candidates: [{ content: { parts: [{ text: "Want that just for today, or going forward?" }] } }],
          usageMetadata: { promptTokenCount: 30, candidatesTokenCount: 10 },
        }),
      });
    vi.stubGlobal("fetch", fetchMock);

    const executeTool = vi.fn().mockResolvedValue({ ok: true, needsScopeConfirmation: true });
    const provider = new GeminiCoachProvider("fake-gemini-key");
    const result = await provider.generateCoachReply({
      system: "system",
      userContent: "I only have 15 minutes today",
      tools: [{ name: "adapt_plan", description: "d", parameters: { type: "object", properties: {} } }],
      executeTool,
    });

    expect(result.content).toBe("Want that just for today, or going forward?");
    expect(result.toolCalls).toEqual([{ name: "adapt_plan", args: { reason: "time_constraint" } }]);
    expect(result.usage).toEqual({ inputTokens: 50, outputTokens: 15 });
    expect(executeTool).toHaveBeenCalledWith("adapt_plan", { reason: "time_constraint" });
    expect(fetchMock).toHaveBeenCalledTimes(2);

    // Second request must include the model's functionCall turn and the
    // tool's functionResponse turn so the model has the result in context.
    const secondBody = JSON.parse((fetchMock.mock.calls[1] as [string, RequestInit])[1].body as string);
    expect(secondBody.contents).toContainEqual({
      role: "model",
      parts: [{ functionCall: { name: "adapt_plan", args: { reason: "time_constraint" } } }],
    });
    expect(secondBody.contents).toContainEqual({
      role: "function",
      parts: [{ functionResponse: { name: "adapt_plan", response: { ok: true, needsScopeConfirmation: true } } }],
    });
  });

  it("gemini_tool_loop_forces_a_text_finish_after_max_tool_calls", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    // On the forced final round (no tools offered), the model has nothing
    // to call and must answer with text instead.
    fetchMock.mockImplementation((_url: string, init: RequestInit) => {
      const body = JSON.parse(init.body as string);
      if (!body.tools) {
        return Promise.resolve({
          ok: true,
          json: async () => ({
            candidates: [{ content: { parts: [{ text: "Here's what I can tell you without changing anything yet." }] } }],
            usageMetadata: { promptTokenCount: 1, candidatesTokenCount: 1 },
          }),
        });
      }
      return Promise.resolve({
        ok: true,
        json: async () => ({
          candidates: [{ content: { parts: [{ functionCall: { name: "adapt_plan", args: {} } }] } }],
          usageMetadata: { promptTokenCount: 1, candidatesTokenCount: 1 },
        }),
      });
    });

    const executeTool = vi.fn().mockResolvedValue({ ok: true });
    const provider = new GeminiCoachProvider("fake-gemini-key");
    const result = await provider.generateCoachReply({
      system: "system",
      userContent: "keep adjusting",
      tools: [{ name: "adapt_plan", description: "d", parameters: { type: "object", properties: {} } }],
      executeTool,
      maxToolCalls: 2,
    });

    expect(result.content).toBe("Here's what I can tell you without changing anything yet.");
    expect(result.toolCalls).toHaveLength(2);
    expect(executeTool).toHaveBeenCalledTimes(2);
    // 2 tool rounds + 1 forced text-only round.
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });

  it("gemini_parser_rejects_malformed_parts_without_type_error", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          candidates: [{ content: { parts: { text: "not-array" } } }],
        }),
      }),
    );

    const provider = new GeminiCoachProvider("fake-gemini-key");
    await expect(
      provider.generateCoachReply({ system: "system", userContent: "hello" }),
    ).rejects.toThrow("Gemini returned an empty coach response");
  });
});
