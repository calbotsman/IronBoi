import { z } from "zod";

/**
 * Coach's spoken voice: Google Cloud Text-to-Speech, Chirp 3 HD — the same
 * natural voice family as Gemini Live. Called from the app one sentence or
 * two at a time so playback starts fast. Authenticates as the function's
 * own service account (metadata server), so there's no extra key to manage;
 * billed to the project (~$30 per million characters).
 */
/**
 * The voices a person can pick for their coach: four female, four male,
 * one per feel (warm, upbeat, firm, calm). A fixed allowlist, not a free
 * knob — every one is the same Chirp 3 HD family and price, and each is
 * also a Gemini Live voice, so live and spoken replies sound the same.
 */
export const COACH_VOICES = [
  "Sulafat", "Laomedeia", "Kore", "Achernar",
  "Achird", "Puck", "Orus", "Algieba",
] as const;

/** A voice from the allowlist; anything else is dropped, not an error. */
export const CoachVoiceChoice = z.enum(COACH_VOICES).optional().catch(undefined);

/**
 * Which engine reads the line. "chirp" (Cloud TTS) is the regular coach's
 * voice. With live voice on, the app's own lines ("Set 2 done, rest ninety
 * seconds") are read by the SAME engine the live coach talks with — Gemini
 * or OpenAI — so the voice never changes between a saved line and a reply.
 */
export const SpeechEngine = z.enum(["chirp", "gemini", "openai"]);

export const SynthesizeSpeechRequest = z.object({
  text: z.string().min(1).max(600),
  voice: CoachVoiceChoice,
  engine: SpeechEngine.optional().catch(undefined),
});

export const DEFAULT_COACH_VOICE = "Sulafat";
const VOICE_NAME = /^[A-Za-z]+$/;

/**
 * The coach's voice when the person hasn't picked one from COACH_VOICES:
 * chosen by the operator (IRONBOI_COACH_VOICE, a Chirp 3 HD voice name).
 */
export function coachVoice(env: NodeJS.ProcessEnv = process.env): string {
  const configured = env.IRONBOI_COACH_VOICE?.trim();
  return configured && VOICE_NAME.test(configured) && configured.length <= 32
    ? configured
    : DEFAULT_COACH_VOICE;
}
const TTS_URL = "https://texttospeech.googleapis.com/v1/text:synthesize";
const TOKEN_URL =
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token";

let cachedToken: { value: string; expiresAt: number } | null = null;

async function accessToken(fetchImpl: typeof fetch): Promise<string> {
  if (process.env.GOOGLE_TTS_ACCESS_TOKEN) return process.env.GOOGLE_TTS_ACCESS_TOKEN;
  if (cachedToken && cachedToken.expiresAt > Date.now() + 60_000) return cachedToken.value;
  const res = await fetchImpl(TOKEN_URL, { headers: { "Metadata-Flavor": "Google" } });
  if (!res.ok) throw new Error(`metadata token HTTP ${res.status}`);
  const body = (await res.json()) as { access_token: string; expires_in: number };
  cachedToken = { value: body.access_token, expiresAt: Date.now() + body.expires_in * 1000 };
  return body.access_token;
}

/**
 * The per-user cap bounds one account; it does not bound someone minting
 * accounts. Real users sign in with Apple, so anonymous uids (which the
 * public web API key can create freely) only get a voice where the
 * operator has said so — staging, where the simulator's DEBUG-only dev
 * sign-in is anonymous. Anywhere else they fall back to the on-device voice.
 */
export function ttsAllowedForSignInProvider(
  signInProvider: string | undefined,
  env: NodeJS.ProcessEnv = process.env,
): boolean {
  if (signInProvider !== "anonymous") return true;
  return env.IRONBOI_TTS_ALLOW_ANONYMOUS === "true";
}

/** Our voice names → OpenAI's closest (kept in step with liveOpenAI.ts). */
const OPENAI_TTS_VOICE: Record<string, string> = {
  Sulafat: "marin", Laomedeia: "coral", Kore: "sage", Achernar: "shimmer",
  Achird: "cedar", Puck: "verse", Orus: "ash", Algieba: "echo",
};

/** 16-bit mono PCM → a WAV file (the app plays WAV). */
export function wavFromPcm16(pcm: Buffer, sampleRate = 24000): Buffer {
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(sampleRate * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}

export const GEMINI_TTS_MODEL_DEFAULT = "gemini-2.5-flash-preview-tts";
export const OPENAI_TTS_MODEL_DEFAULT = "gpt-4o-mini-tts";

async function synthesizeWithGemini(text: string, voice: string, apiKey: string, fetchImpl: typeof fetch): Promise<string> {
  const model = process.env.IRONBOI_GEMINI_TTS_MODEL || GEMINI_TTS_MODEL_DEFAULT;
  const res = await fetchImpl(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-goog-api-key": apiKey },
    body: JSON.stringify({
      contents: [{ parts: [{ text }] }],
      generationConfig: {
        responseModalities: ["AUDIO"],
        speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: voice } } },
      },
    }),
  });
  if (!res.ok) throw new Error(`gemini-tts HTTP ${res.status}`);
  const body = (await res.json()) as {
    candidates?: Array<{ content?: { parts?: Array<{ inlineData?: { data?: string } }> } }>;
  };
  const data = body.candidates?.[0]?.content?.parts?.find((part) => part.inlineData?.data)?.inlineData?.data;
  if (!data) throw new Error("gemini-tts returned no audio");
  return wavFromPcm16(Buffer.from(data, "base64")).toString("base64");
}

async function synthesizeWithOpenAI(text: string, voice: string, apiKey: string, fetchImpl: typeof fetch): Promise<string> {
  const res = await fetchImpl("https://api.openai.com/v1/audio/speech", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${apiKey}` },
    body: JSON.stringify({
      model: process.env.IRONBOI_OPENAI_TTS_MODEL || OPENAI_TTS_MODEL_DEFAULT,
      voice: OPENAI_TTS_VOICE[voice] ?? "marin",
      input: text,
      response_format: "pcm",
      instructions: "A personal trainer talking to their client in the gym: warm, natural, conversational pace.",
    }),
  });
  if (!res.ok) throw new Error(`openai-tts HTTP ${res.status}`);
  return wavFromPcm16(Buffer.from(await res.arrayBuffer())).toString("base64");
}

/**
 * Returns base64 WAV (LINEAR16, 24 kHz mono). With an engine and its key,
 * that engine reads it; if it fails, Cloud TTS does — a slightly different
 * voice beats silence.
 */
export async function synthesizeSpeech(
  request: z.infer<typeof SynthesizeSpeechRequest>,
  fetchImpl: typeof fetch = fetch,
  keys: { gemini?: string; openai?: string } = {},
): Promise<{ audio: string; mimeType: "audio/wav"; engine: z.infer<typeof SpeechEngine> }> {
  const voice = request.voice ?? coachVoice();
  try {
    if (request.engine === "gemini" && keys.gemini) {
      return { audio: await synthesizeWithGemini(request.text, voice, keys.gemini, fetchImpl), mimeType: "audio/wav", engine: "gemini" };
    }
    if (request.engine === "openai" && keys.openai) {
      return { audio: await synthesizeWithOpenAI(request.text, voice, keys.openai, fetchImpl), mimeType: "audio/wav", engine: "openai" };
    }
  } catch {
    // Fall through to Cloud TTS.
  }
  const res = await fetchImpl(TTS_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${await accessToken(fetchImpl)}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      input: { text: request.text },
      voice: { languageCode: "en-US", name: `en-US-Chirp3-HD-${voice}` },
      audioConfig: { audioEncoding: "LINEAR16", sampleRateHertz: 24000 },
    }),
  });
  if (!res.ok) {
    throw new Error(`text-to-speech HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
  }
  const body = (await res.json()) as { audioContent?: string };
  if (!body.audioContent) throw new Error("text-to-speech returned no audio");
  return { audio: body.audioContent, mimeType: "audio/wav", engine: "chirp" };
}
