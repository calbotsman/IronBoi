type GenerateCoachReplyArgs = {
  system: string;
  userContent: string;
  onText?: (content: string) => Promise<void>;
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
  }: GenerateCoachReplyArgs): Promise<GenerateCoachReplyResult> {
    const response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${this.model}:generateContent`,
      {
        method: "POST",
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
        }),
      },
    );

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
