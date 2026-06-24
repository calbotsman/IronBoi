type GenerateCoachReplyArgs = {
  system: string;
  userContent: string;
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
};

export type CoachModelProvider = {
  provider: "gemini";
  model: string;
  generateCoachReply(args: GenerateCoachReplyArgs): Promise<GenerateCoachReplyResult>;
};

type SelectCoachModelProviderArgs = {
  geminiApiKey?: string;
};

function estimateTokens(text: string) {
  return Math.ceil(text.length / 4);
}

export class GeminiCoachProvider implements CoachModelProvider {
  provider = "gemini" as const;
  model = process.env.IRONBOI_COACH_MODEL || "gemini-2.5-flash";

  constructor(private readonly apiKey: string) {}

  async generateCoachReply({
    system,
    userContent,
    onText,
    signal,
  }: GenerateCoachReplyArgs): Promise<GenerateCoachReplyResult> {
    const callGemini = (): Promise<Response> => fetch(
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
          contents: [
            {
              role: "user",
              parts: [{ text: userContent }],
            },
          ],
          generationConfig: {
            maxOutputTokens: 900,
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

    // Gemini returns 429/500/503 when the model is momentarily overloaded.
    // Retry transient failures with backoff (within the orchestrator's 55s
    // budget) instead of failing the whole coach turn on a blip.
    const TRANSIENT_STATUS = new Set([429, 500, 503]);
    const MAX_ATTEMPTS = 3;
    let response!: Response;
    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
      response = await callGemini();
      if (response.ok || !TRANSIENT_STATUS.has(response.status) || attempt === MAX_ATTEMPTS) {
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, attempt * 1500));
    }

    if (!response.ok) {
      throw new Error(`Gemini request failed with HTTP ${response.status}`);
    }

    const payload = (await response.json()) as {
      candidates?: Array<{
        content?: {
          parts?: Array<{ text?: string }>;
        };
      }>;
      usageMetadata?: {
        promptTokenCount?: number;
        candidatesTokenCount?: number;
        totalTokenCount?: number;
      };
    };

    const parts = payload.candidates?.[0]?.content?.parts;
    const content = Array.isArray(parts)
      ? parts
          .map((part) => part.text ?? "")
          .join("")
          .trim()
      : "";

    if (!content) {
      throw new Error("Gemini returned an empty coach response");
    }

    await onText?.(content);
    return {
      content,
      usage: {
        inputTokens:
          payload.usageMetadata?.promptTokenCount ??
          estimateTokens(`${system}\n${userContent}`),
        outputTokens:
          payload.usageMetadata?.candidatesTokenCount ?? estimateTokens(content),
      },
    };
  }
}

// Gemini-only as of 2026-05-21. The selector signature stays in place so a
// second provider (OpenRouter, Claude, etc.) can slot in without touching
// callers — just add a new provider class and another branch here.
export function selectCoachModelProvider({
  geminiApiKey,
}: SelectCoachModelProviderArgs): CoachModelProvider | null {
  if (geminiApiKey) {
    return new GeminiCoachProvider(geminiApiKey);
  }
  return null;
}
