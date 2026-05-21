import { describe, expect, it } from "vitest";
import {
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
  };

  it("usage_cap_allows_under_cap", () => {
    expect(
      evaluateUsageCap(
        { messageCount: 1, inputTokens: 20, outputTokens: 10, capReached: false },
        "2026-05-11",
        caps,
      ),
    ).toEqual({
      allowed: true,
      usage: { messageCount: 1, inputTokens: 20, outputTokens: 10, capReached: false },
      dateKey: "2026-05-11",
    });
  });

  it("usage_cap_blocks_at_message_cap", () => {
    expect(
      evaluateUsageCap(
        { messageCount: 2, inputTokens: 20, outputTokens: 10, capReached: false },
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
      capReached: false,
    });
  });
});
