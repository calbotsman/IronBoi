import { liveToolDeclarations } from "./liveSession.js";

/**
 * Live voice on OpenAI's Realtime API, for an A/B against Gemini Live: the
 * same coach brain (instruction), the same tools, the same phone-side
 * plumbing — only the voice model differs.
 *
 * The phone gets a short-lived client secret (`ek_…`) minted here with the
 * session config attached. Unlike Gemini's constrained tokens, a Realtime
 * client can still send `session.update` and change its own instructions,
 * so this provider is opt-in per environment (IRONBOI_LIVE_OPENAI_ENABLED)
 * and meant for testing, not as the default.
 */
export const OPENAI_REALTIME_MODEL_DEFAULT = "gpt-realtime";
const SECRET_SECONDS = 600;

/** Our eight Chirp/Gemini voices → the closest OpenAI voice by sex and feel. */
export const OPENAI_VOICE_FOR: Record<string, string> = {
  Sulafat: "marin", // female, warm
  Laomedeia: "coral", // female, upbeat
  Kore: "sage", // female, firm
  Achernar: "shimmer", // female, calm
  Achird: "cedar", // male, warm
  Puck: "verse", // male, upbeat
  Orus: "ash", // male, firm
  Algieba: "echo", // male, calm
};

export function liveOpenAIEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.IRONBOI_LIVE_OPENAI_ENABLED === "true";
}

/** Gemini-style declarations → Realtime function tools. */
export function openAITools() {
  return liveToolDeclarations().map((tool) => {
    const parameters = (tool as { parameters?: Record<string, unknown> }).parameters;
    return {
      type: "function" as const,
      name: tool.name,
      description: tool.description,
      parameters: parameters ?? { type: "object", properties: {} },
    };
  });
}

export function openAISessionConfig(args: { model: string; voice: string; instruction: string }) {
  return {
    type: "realtime",
    model: args.model,
    instructions: args.instruction,
    output_modalities: ["audio"],
    audio: {
      input: {
        format: { type: "audio/pcm", rate: 24000 },
        transcription: { model: "gpt-4o-mini-transcribe" },
        // Waits for the end of a thought, not just a pause — closer to
        // how Gemini's low-sensitivity detection behaves in a gym.
        turn_detection: { type: "semantic_vad", eagerness: "low", interrupt_response: true, create_response: true },
        noise_reduction: { type: "far_field" },
      },
      output: {
        format: { type: "audio/pcm", rate: 24000 },
        voice: OPENAI_VOICE_FOR[args.voice] ?? "marin",
      },
    },
    tools: openAITools(),
    tool_choice: "auto",
  };
}

export async function mintOpenAIRealtimeSecret(args: {
  apiKey: string;
  session: ReturnType<typeof openAISessionConfig>;
  fetchImpl?: typeof fetch;
}): Promise<{ token: string; expiresAt: string }> {
  const response = await (args.fetchImpl ?? fetch)("https://api.openai.com/v1/realtime/client_secrets", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${args.apiKey}` },
    body: JSON.stringify({
      expires_after: { anchor: "created_at", seconds: SECRET_SECONDS },
      session: args.session,
    }),
  });
  const body = (await response.json().catch(() => ({}))) as {
    value?: string;
    expires_at?: number;
    error?: { type?: string; code?: string };
  };
  if (!response.ok || !body.value) {
    throw new Error(`openai_realtime_mint_failed:${response.status}:${body.error?.code ?? body.error?.type ?? "unknown"}`);
  }
  const expiresAt = new Date((body.expires_at ?? Date.now() / 1000 + SECRET_SECONDS) * 1000).toISOString();
  return { token: body.value, expiresAt };
}
