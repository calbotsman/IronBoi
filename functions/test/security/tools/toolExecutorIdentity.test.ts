import { describe, expect, it, vi } from "vitest";
import { executeTool, type ToolRegistry } from "../../../src/tools/executor.js";

function registryWithSpy(spy: ReturnType<typeof vi.fn>): ToolRegistry {
  return {
    get_recent_workouts: async (args, ctx) => spy(args, ctx),
  };
}

describe("tool executor identity hardening", () => {
  it("executor_overrides_client_userId", async () => {
    const spy = vi.fn();
    await executeTool(
      registryWithSpy(spy),
      "get_recent_workouts",
      { userId: "B", days: 7 },
      { authenticatedUserId: "A" },
    );
    expect(spy.mock.calls[0][0].userId).toBe("A");
  });

  it("executor_overrides_userId_when_absent", async () => {
    const spy = vi.fn();
    await executeTool(
      registryWithSpy(spy),
      "get_recent_workouts",
      { days: 7 },
      { authenticatedUserId: "A" },
    );
    expect(spy.mock.calls[0][0].userId).toBe("A");
  });

  it("executor_drops_userId_aliases", async () => {
    const spy = vi.fn();
    await executeTool(
      registryWithSpy(spy),
      "get_recent_workouts",
      {
        uid: "B",
        user_id: "B",
        userID: "B",
        userid: "B",
        targetUserId: "B",
        ownerId: "B",
        subjectId: "B",
      },
      { authenticatedUserId: "A" },
    );
    expect(spy.mock.calls[0][0]).toEqual({ userId: "A" });
  });

  it("executor_throws_on_missing_auth", async () => {
    await expect(
      executeTool(registryWithSpy(vi.fn()), "get_recent_workouts", {}, {
        authenticatedUserId: "",
      }),
    ).rejects.toThrow("authenticated user");
  });
});
