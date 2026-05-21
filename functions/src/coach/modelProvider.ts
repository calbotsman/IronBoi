import Anthropic from "@anthropic-ai/sdk";

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
  provider: "anthropic" | "gemini";
  model: string;
  generateCoachReply(args: GenerateCoachReplyArgs): Promise<GenerateCoachReplyResult>;
};

type SelectCoachModelProviderArgs = {
  anthropicApiKey?: string;
  geminiApiKey?: string;
};

const STREAM_WRITE_INTERVAL_MS = 1_500;

function estimateTokens(text: string) {
  return Math.ceil(text.length / 4);
}

export class AnthropicCoachProvider implements CoachModelProvider {
  provider = "anthropic" as const;
  model = process.env.IRONBOI_COACH_MODEL || "claude-sonnet-4-5-20250929";

  constructor(private readonly apiKey: string) {}

  async generateCoachReply({
    system,
    userContent,
    onText,
  }: GenerateCoachReplyArgs): Promise<GenerateCoachReplyResult> {
    const anthropic = new Anthropic({ apiKey: this.apiKey });
    const stream = anthropic.messages.stream({
      model: this.model,
      max_tokens: 900,
      system,
      messages: [{ role: "user", content: userContent }],
    });

    let content = "";
    let lastWriteAt = 0;
    stream.on("text", async (text: string) => {
      content += text;
      const now = Date.now();
      if (!onText || now - lastWriteAt < STREAM_WRITE_INTERVAL_MS) {
        return;
      }
      lastWriteAt = now;
      await onText(content);
    });

    const finalMessage = await stream.finalMessage();
    await onText?.(content);
    return {
      content,
      usage: {
        inputTokens:
          finalMessage.usage?.input_tokens ?? estimateTokens(`${system}\n${userContent}`),
        outputTokens: finalMessage.usage?.output_tokens ?? estimateTokens(content),
      },
    };
  }
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

export function selectCoachModelProvider({
  anthropicApiKey,
  geminiApiKey,
}: SelectCoachModelProviderArgs): CoachModelProvider | null {
  const preferredProvider = process.env.IRONBOI_COACH_PROVIDER || "gemini";

  if (preferredProvider === "anthropic" && anthropicApiKey) {
    return new AnthropicCoachProvider(anthropicApiKey);
  }

  if (geminiApiKey) {
    return new GeminiCoachProvider(geminiApiKey);
  }

  if (anthropicApiKey) {
    return new AnthropicCoachProvider(anthropicApiKey);
  }

  return null;
}
