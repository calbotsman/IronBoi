import * as logger from "firebase-functions/logger";

type LogSeverity = "info" | "warn" | "error";
type LogValue =
  | string
  | number
  | boolean
  | null
  | undefined
  | LogValue[]
  | { [key: string]: LogValue };
type LogPayload = Record<string, LogValue>;

export const allowedLogKeys = new Set([
  "userId",
  "sessionId",
  "messageId",
  "turnId",
  "factId",
  "proposalId",
  "programId",
  "tool",
  "toolDuration",
  "toolStatus",
  "modelProvider",
  "model",
  "promptTokens",
  "completionTokens",
  "latencyMs",
  "event",
  "outcome",
  "errorCode",
  "errorDetail",
  "tokenAud",
  "tokenExp",
  "tokenIss",
  "severity",
  "memoryKind",
  "agentName",
  "trigger",
]);

const suspiciousKeyPattern =
  /(content|message|injury|weight|email|phone|address|name|note|profile|metric|diagnosis|symptom)/i;
const suspiciousStringPattern =
  /([A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,})|(\b\d{3}[-.) ]?\d{3}[-. ]?\d{4}\b)/i;

function redactValue(value: LogValue): LogValue {
  if (Array.isArray(value)) return value.map(redactValue);
  if (value && typeof value === "object") return sanitizePayload(value);
  if (typeof value === "string" && suspiciousStringPattern.test(value)) {
    return "[REDACTED]";
  }
  return value;
}

export function sanitizePayload(payload: LogPayload): LogPayload {
  return Object.fromEntries(
    Object.entries(payload).map(([key, value]) => {
      if (!allowedLogKeys.has(key) || suspiciousKeyPattern.test(key)) {
        return [key, "[REDACTED]"];
      }
      return [key, redactValue(value)];
    }),
  );
}

function write(severity: LogSeverity, message: string, payload: LogPayload = {}) {
  const sanitized = sanitizePayload({ ...payload, severity });
  logger[severity](message, sanitized);
}

export const safeLogger = {
  info(message: string, payload?: LogPayload) {
    write("info", message, payload);
  },
  warn(message: string, payload?: LogPayload) {
    write("warn", message, payload);
  },
  error(message: string, payload?: LogPayload) {
    write("error", message, payload);
  },
};
