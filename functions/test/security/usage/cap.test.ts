import { describe, expect, it } from "vitest";
import {
  capFromEnv,
  evaluateTtsCap,
  evaluateUsageCap,
  normalizeDailyUsage,
  todayUtcDateKey,
  usagePath,
} from "../../../src/usage/cap.js";

describe("daily usage cap", () => {
  const caps = {
    messagesPerDay: 2,
    inputTokensPerDay: 100,
    outputTokensPerDay: 50,
    ttsCharsPerDay: 1000,
  };

  it("usage_cap_allows_under_cap", () => {
    expect(
      evaluateUsageCap(
        { messageCount: 1, inputTokens: 20, outputTokens: 10, ttsChars: 0, capReached: false },
        "2026-05-11",
        caps,
      ),
    ).toEqual({
      allowed: true,
      usage: { messageCount: 1, inputTokens: 20, outputTokens: 10, ttsChars: 0, capReached: false },
      dateKey: "2026-05-11",
    });
  });

  it("usage_cap_blocks_at_message_cap", () => {
    expect(
      evaluateUsageCap(
        { messageCount: 2, inputTokens: 20, outputTokens: 10, ttsChars: 0, capReached: false },
        "2026-05-11",
        caps,
      ),
    ).toMatchObject({
      allowed: false,
      reason: "daily_message_cap",
      dateKey: "2026-05-11",
    });
  });

  it("usage_doc_path_is_user_scoped", () => {
    expect(usagePath("user-a", "2026-05-11")).toBe("users/user-a/usage/2026-05-11");
  });

  it("usage_date_key_uses_utc_day", () => {
    expect(todayUtcDateKey(new Date("2026-05-11T23:59:59.000Z"))).toBe("2026-05-11");
  });

  it("usage_normalizer_defaults_missing_values_to_zero", () => {
    expect(normalizeDailyUsage(undefined)).toEqual({
      messageCount: 0,
      inputTokens: 0,
      outputTokens: 0,
      ttsChars: 0,
      capReached: false,
    });
  });

  describe("caps read from the environment", () => {
    it("cap_env_typo_falls_back_instead_of_disabling_the_cap", () => {
      expect(capFromEnv("abc", 60_000)).toBe(60_000);
      expect(capFromEnv("", 60_000)).toBe(60_000);
      expect(capFromEnv("0", 60_000)).toBe(60_000);
      expect(capFromEnv("-5", 60_000)).toBe(60_000);
    });

    it("cap_env_value_is_used_when_valid", () => {
      expect(capFromEnv("1500", 60_000)).toBe(1500);
      expect(capFromEnv(" 1500 ", 60_000)).toBe(1500);
      expect(capFromEnv(undefined, 60_000)).toBe(60_000);
    });
  });

  describe("spoken-reply (TTS) cap", () => {
    const usage = { messageCount: 0, inputTokens: 0, outputTokens: 0, ttsChars: 900, capReached: false };

    it("tts_cap_allows_a_request_that_fits", () => {
      expect(evaluateTtsCap(usage, 100, "2026-10-07", caps)).toEqual({
        allowed: true,
        usage,
        dateKey: "2026-10-07",
      });
    });

    it("tts_cap_blocks_a_request_that_would_cross_the_line", () => {
      expect(evaluateTtsCap(usage, 101, "2026-10-07", caps)).toMatchObject({
        allowed: false,
        reason: "daily_tts_char_cap",
      });
    });

    it("tts_cap_is_independent_of_the_message_and_token_caps", () => {
      // A user who has used every message still gets audio for what was
      // already written, and a spent voice budget never blocks a text turn.
      const chatty = { ...usage, messageCount: 2, inputTokens: 100, outputTokens: 50, ttsChars: 0 };
      expect(evaluateTtsCap(chatty, 500, "2026-10-07", caps).allowed).toBe(true);
      const talkedOut = { ...usage, ttsChars: 1000 };
      expect(evaluateUsageCap(talkedOut, "2026-10-07", caps).allowed).toBe(true);
    });
  });
});
