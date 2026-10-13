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

export const SynthesizeSpeechRequest = z.object({
  text: z.string().min(1).max(600),
  voice: CoachVoiceChoice,
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

/** Returns base64 WAV (LINEAR16, 24 kHz mono). */
export async function synthesizeSpeech(
  request: z.infer<typeof SynthesizeSpeechRequest>,
  fetchImpl: typeof fetch = fetch,
): Promise<{ audio: string; mimeType: "audio/wav" }> {
  const voice = request.voice ?? coachVoice();
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
  return { audio: body.audioContent, mimeType: "audio/wav" };
}
