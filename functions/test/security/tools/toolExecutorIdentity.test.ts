import { describe, expect, it, vi } from "vitest";
import {
  executeTool,
  ToolIdentityViolationError,
  type ToolRegistry,
} from "../../../src/tools/executor.js";

function registryWithSpy(spy: ReturnType<typeof vi.fn>): ToolRegistry {
  return {
    get_recent_workouts: async (args, ctx) => spy(args, ctx),
    adapt_plan: async (args, ctx) => spy(args, ctx),
  };
}

describe("tool executor identity hardening (Phase 1.2)", () => {
  it("executor_rejects_userId_field", async () => {
    const spy = vi.fn();
    await expect(
      executeTool(
        registryWithSpy(spy),
        "get_recent_workouts",
        { userId: "B", days: 7 },
        { authenticatedUserId: "A" },
      ),
    ).rejects.toBeInstanceOf(ToolIdentityViolationError);
    expect(spy).not.toHaveBeenCalled();
  });

  it("executor_injects_userId_from_ctx_when_absent", async () => {
    const spy = vi.fn();
    await executeTool(
      registryWithSpy(spy),
      "get_recent_workouts",
      { days: 7 },
      { authenticatedUserId: "A" },
    );
    expect(spy.mock.calls[0][0]).toEqual({ days: 7, userId: "A" });
  });

  it("executor_rejects_all_known_identity_aliases", async () => {
    const aliases = [
      "uid",
      "user_id",
      "userID",
      "userid",
      "targetUserId",
      "target_user_id",
      "ownerId",
      "owner_id",
      "subjectId",
      "subject_id",
      "accountId",
      "account_id",
      "on_behalf_of",
      "onBehalfOf",
      "impersonate",
      "impersonator",
      "impersonateAs",
    ];

    for (const key of aliases) {
      const spy = vi.fn();
      await expect(
        executeTool(
          registryWithSpy(spy),
          "get_recent_workouts",
          { [key]: "B" },
          { authenticatedUserId: "A" },
        ),
        // The point of using a regex (not a fixed list) is that variant
        // names the model invents also get caught. This loop guards the
        // common variants — the regex covers the novel ones.
      ).rejects.toBeInstanceOf(ToolIdentityViolationError);
      expect(spy).not.toHaveBeenCalled();
    }
  });

  it("executor_rejects_novel_identity_variants_from_regex", async () => {
    // Names the original allowlist would have missed.
    const novelVariants = ["byUser", "userOverride", "actingAsUser", "accountAlias"];
    for (const key of novelVariants) {
      const spy = vi.fn();
      await expect(
        executeTool(
          registryWithSpy(spy),
          "get_recent_workouts",
          { [key]: "B" },
          { authenticatedUserId: "A" },
        ),
      ).rejects.toBeInstanceOf(ToolIdentityViolationError);
    }
  });

  it("executor_allows_safe_user_prefixed_content_fields", async () => {
    const spy = vi.fn();
    await executeTool(
      registryWithSpy(spy),
      "adapt_plan",
      { planId: "p1", reason: "too_hard", userNote: "shoulder pain today" },
      { authenticatedUserId: "A" },
    );
    expect(spy.mock.calls[0][0]).toEqual({
      planId: "p1",
      reason: "too_hard",
      userNote: "shoulder pain today",
      userId: "A",
    });
  });

  it("executor_collects_all_offending_keys_in_one_error", async () => {
    const spy = vi.fn();
    try {
      await executeTool(
        registryWithSpy(spy),
        "get_recent_workouts",
        { userId: "B", targetUserId: "C", days: 7 },
        { authenticatedUserId: "A" },
      );
      throw new Error("expected rejection");
    } catch (err) {
      expect(err).toBeInstanceOf(ToolIdentityViolationError);
      const violation = err as ToolIdentityViolationError;
      expect(violation.offendingKeys).toEqual(
        expect.arrayContaining(["userId", "targetUserId"]),
      );
      expect(violation.offendingKeys).not.toContain("days");
      expect(violation.tool).toBe("get_recent_workouts");
    }
    expect(spy).not.toHaveBeenCalled();
  });

  it("executor_throws_on_missing_auth", async () => {
    await expect(
      executeTool(registryWithSpy(vi.fn()), "get_recent_workouts", {}, {
        authenticatedUserId: "",
      }),
    ).rejects.toThrow("authenticated user");
  });

  it("executor_throws_on_unknown_tool", async () => {
    await expect(
      executeTool(registryWithSpy(vi.fn()), "nonexistent_tool", {}, {
        authenticatedUserId: "A",
      }),
    ).rejects.toThrow("Unknown tool");
  });
});
