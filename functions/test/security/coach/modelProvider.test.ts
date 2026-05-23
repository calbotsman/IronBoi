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
