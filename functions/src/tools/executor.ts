import { safeLogger } from "../logging/safeLogger.js";

export type ToolContext = {
  authenticatedUserId: string;
};

export type ToolHandler<TArgs extends Record<string, unknown>, TResult> = (
  args: TArgs & { userId: string },
  ctx: ToolContext,
) => Promise<TResult> | TResult;

export type ToolRegistry = Record<string, ToolHandler<Record<string, unknown>, unknown>>;

const userIdAliases = new Set([
  "userId",
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
]);

function normalizeToolArgs(
  tool: string,
  modelArgs: Record<string, unknown>,
  ctx: ToolContext,
) {
  if (!ctx.authenticatedUserId) {
    throw new Error("Tool execution requires an authenticated user.");
  }

  const attemptedImpersonation = Object.entries(modelArgs).some(
    ([key, value]) =>
      userIdAliases.has(key) &&
      typeof value === "string" &&
      value !== ctx.authenticatedUserId,
  );

  const sanitized = Object.fromEntries(
    Object.entries(modelArgs).filter(([key]) => !userIdAliases.has(key)),
  );

  if (attemptedImpersonation) {
    safeLogger.warn("Tool user identity override", {
      event: "tool_identity_override",
      userId: ctx.authenticatedUserId,
      tool,
      outcome: "overrode_model_user_id",
    });
  }

  return {
    ...sanitized,
    userId: ctx.authenticatedUserId,
  };
}

export async function executeTool(
  registry: ToolRegistry,
  tool: string,
  modelArgs: Record<string, unknown>,
  ctx: ToolContext,
) {
  const handler = registry[tool];
  if (!handler) {
    throw new Error(`Unknown tool: ${tool}`);
  }

  const args = normalizeToolArgs(tool, modelArgs, ctx);
  return handler(args, ctx);
}
