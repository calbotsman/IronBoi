import { describe, expect, it } from "vitest";
import {
  OPENAI_VOICE_FOR,
  liveOpenAIEnabled,
  mintOpenAIRealtimeSecret,
  openAISessionConfig,
  openAITools,
} from "../../../src/coach/liveOpenAI.js";
import { StartLiveCoachSessionRequest } from "../../../src/coach/liveSession.js";
import { COACH_VOICES } from "../../../src/voice/speech.js";

describe("live voice on OpenAI Realtime (A/B)", () => {
  it("is off unless the environment turns it on", () => {
    expect(liveOpenAIEnabled({})).toBe(false);
    expect(liveOpenAIEnabled({ IRONBOI_LIVE_OPENAI_ENABLED: "true" })).toBe(true);
  });

  it("maps every coach voice to an OpenAI voice", () => {
    for (const voice of COACH_VOICES) expect(OPENAI_VOICE_FOR[voice]).toBeTruthy();
  });

  it("locks the brain, voice, audio format and tools into the session", () => {
    const session = openAISessionConfig({ model: "gpt-realtime", voice: "Orus", instruction: "You are MYO." });
    expect(session.instructions).toBe("You are MYO.");
    expect(session.audio.output.voice).toBe("ash");
    expect(session.audio.input.format).toEqual({ type: "audio/pcm", rate: 24000 });
    expect(session.audio.output.format).toEqual({ type: "audio/pcm", rate: 24000 });
    expect(session.tools.length).toBeGreaterThan(0);
  });

  it("gives every tool an object schema, as Realtime requires", () => {
    for (const tool of openAITools()) {
      expect(tool.type).toBe("function");
      expect((tool.parameters as { type?: string }).type).toBe("object");
    }
  });

  it("accepts a provider on the mint request and rejects unknown ones", () => {
    expect(StartLiveCoachSessionRequest.parse({ provider: "openai" }).provider).toBe("openai");
    expect(() => StartLiveCoachSessionRequest.parse({ provider: "other" })).toThrow();
  });

  it("mints a client secret with the session attached, never sending the key to the phone", async () => {
    let sent: { url?: string; body?: Record<string, unknown>; auth?: string } = {};
    const fetchImpl = (async (url: string, init: RequestInit) => {
      sent = { url, body: JSON.parse(String(init.body)), auth: (init.headers as Record<string, string>).authorization };
      return new Response(JSON.stringify({ value: "ek_test", expires_at: 1_900_000_000 }), { status: 200 });
    }) as unknown as typeof fetch;
    const session = openAISessionConfig({ model: "gpt-realtime", voice: "Sulafat", instruction: "x" });
    const minted = await mintOpenAIRealtimeSecret({ apiKey: "sk-secret", session, fetchImpl });
    expect(minted.token).toBe("ek_test");
    expect(sent.url).toBe("https://api.openai.com/v1/realtime/client_secrets");
    expect(sent.auth).toBe("Bearer sk-secret");
    expect(sent.body?.session).toEqual(session);
    expect(JSON.stringify(minted)).not.toContain("sk-secret");
  });

  it("throws on a failed mint", async () => {
    const fetchImpl = (async () => new Response(JSON.stringify({ error: { code: "invalid_api_key" } }), { status: 401 })) as unknown as typeof fetch;
    await expect(
      mintOpenAIRealtimeSecret({ apiKey: "k", session: openAISessionConfig({ model: "m", voice: "Kore", instruction: "x" }), fetchImpl }),
    ).rejects.toThrow(/401:invalid_api_key/);
  });
});
