import { describe, expect, it, vi } from "vitest";
import { SynthesizeSpeechRequest, synthesizeSpeech } from "../../../src/voice/speech.js";
import { VOICE_MODE_RULES } from "../../../src/coach/orchestrate.js";

describe("synthesizeSpeech", () => {
  it("asks Cloud TTS for a Chirp 3 HD voice as 24 kHz LINEAR16", async () => {
    process.env.GOOGLE_TTS_ACCESS_TOKEN = "test-token";
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ audioContent: "UklGRg==" }) });
    const out = await synthesizeSpeech({ text: "Set two, done." }, fetchMock as unknown as typeof fetch);

    expect(out).toEqual({ audio: "UklGRg==", mimeType: "audio/wav" });
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    const body = JSON.parse(String(init.body));
    expect(body.voice.name).toBe("en-US-Chirp3-HD-Sulafat");
    expect(body.audioConfig).toEqual({ audioEncoding: "LINEAR16", sampleRateHertz: 24000 });
    expect((init.headers as Record<string, string>).Authorization).toBe("Bearer test-token");
    delete process.env.GOOGLE_TTS_ACCESS_TOKEN;
  });

  it("rejects over-long text and odd voice names", () => {
    expect(SynthesizeSpeechRequest.safeParse({ text: "x".repeat(601) }).success).toBe(false);
    expect(SynthesizeSpeechRequest.safeParse({ text: "hi", voice: "../etc" }).success).toBe(false);
  });

  it("surfaces an API error instead of returning silence", async () => {
    process.env.GOOGLE_TTS_ACCESS_TOKEN = "t";
    const fetchMock = vi.fn().mockResolvedValue({ ok: false, status: 403, text: async () => "API not enabled" });
    await expect(synthesizeSpeech({ text: "hi" }, fetchMock as unknown as typeof fetch)).rejects.toThrow("HTTP 403");
    delete process.env.GOOGLE_TTS_ACCESS_TOKEN;
  });
});

describe("voice mode prompt", () => {
  it("asks for short, list-free spoken replies", () => {
    expect(VOICE_MODE_RULES).toMatch(/1–3 short spoken sentences/);
    expect(VOICE_MODE_RULES).toMatch(/No lists/);
  });
});
