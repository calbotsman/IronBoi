import { describe, expect, it } from "vitest";
import { sanitizePayload } from "../../../src/logging/safeLogger.js";

describe("safeLogger", () => {
  it("logger_accepts_allowed_keys", () => {
    expect(
      sanitizePayload({
        userId: "a",
        turnId: "turn-1",
        tool: "get_recent_workouts",
        latencyMs: 120,
      }),
    ).toEqual({
      userId: "a",
      turnId: "turn-1",
      tool: "get_recent_workouts",
      latencyMs: 120,
    });
  });

  it("logger_rejects_chatContent", () => {
    expect(sanitizePayload({ chatContent: "my knee hurts" })).toEqual({
      chatContent: "[REDACTED]",
    });
  });

  it("logger_rejects_userMessage", () => {
    expect(sanitizePayload({ userMessage: "hello" })).toEqual({
      userMessage: "[REDACTED]",
    });
  });

  it("logger_rejects_injury", () => {
    expect(sanitizePayload({ injury: { bodyPart: "knee" } })).toEqual({
      injury: "[REDACTED]",
    });
  });

  it("logger_rejects_weightKg", () => {
    expect(sanitizePayload({ weightKg: 80 })).toEqual({ weightKg: "[REDACTED]" });
  });

  it("logger_rejects_email", () => {
    expect(sanitizePayload({ email: "x@y.com" })).toEqual({ email: "[REDACTED]" });
  });

  it("logger_redacts_nested_PHI", () => {
    expect(sanitizePayload({ context: { chatContent: "my knee hurts" } })).toEqual({
      context: "[REDACTED]",
    });
  });
});
