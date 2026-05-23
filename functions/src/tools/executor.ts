import { safeLogger } from "../logging/safeLogger.js";

// Phase 1 Task 1.2 — D5 locked decision.
// The tool executor MUST reject any argument that could let the model claim
// identity for the call. We do NOT silently strip + override (the old behavior),
// because silent stripping makes the threat invisible in logs and lets a
// model that's probing identity boundaries succeed often enough to be useful.
//
// Defense in depth:
//   1. The schemas in `contracts/tool-calls.ts` are `.strict()` — any unknown
//      key fails a Zod parse upstream.
//   2. At the executor we run a regex check at call time. The regex is
//      deliberately broad so that NEW field names a model invents
//      (`actingAsUser`, `byUser`, `userOverride`, etc.) also get caught.
//   3. An explicit allowlist exempts legitimate user-content fields that
//      share the "user" prefix but carry user-authored text, not identity.
//      Additions to that allowlist need a deliberate security review.
//   4. `userId` is ALWAYS injected from `ctx.authenticatedUserId` after the
//      check passes — never taken from `modelArgs`.

// Spec regex from phase-plan.md Task 1.2, plus `subject` to cover the old
// allowlist's `subjectId` / `subject_id`. Substring match is intentional —
// catches novel variants the model might invent (`byUser`, `userOverride`,
// `actingAsUser`, `accountAlias`, etc.).
const IDENTITY_FIELD_PATTERN = /user|owner|account|behalf|impersonat|subject/i;

// `uid` is a 3-letter token that's too short for safe substring matching
// (would false-positive on "guide", "fluid", etc.). Handled explicitly.
const EXPLICIT_IDENTITY_FIELDS = new Set(["uid"]);

// Fields that match the broad identity regex but carry user-authored content,
// not identity claims. Audit any addition here — a wrongly-allowlisted field
// is exactly the hole this guard is designed to close.
const SAFE_USER_PREFIXED_FIELDS = new Set([
  "userNote", // AdaptPlanRequest — free-text note from the user
  "userContext", // ExplainExerciseRequest — user's stated experience/limits
  "userText", // FlagRiskRequest — the text being flagged
]);

function isIdentityField(key: string): boolean {
  if (SAFE_USER_PREFIXED_FIELDS.has(key)) return false;
  if (EXPLICIT_IDENTITY_FIELDS.has(key.toLowerCase())) return true;
  return IDENTITY_FIELD_PATTERN.test(key);
}

export class ToolIdentityViolationError extends Error {
  constructor(
    public readonly tool: string,
    public readonly offendingKeys: string[],
  ) {
    super(
      `Tool "${tool}" call rejected: identity-shaped fields not allowed (${offendingKeys.join(", ")})`,
    );
    this.name = "ToolIdentityViolationError";
  }
}

export type ToolContext = {
  authenticatedUserId: string;
};

export type ToolHandler<TArgs extends Record<string, unknown>, TResult> = (
  args: TArgs & { userId: string },
  ctx: ToolContext,
) => Promise<TResult> | TResult;

export type ToolRegistry = Record<
  string,
  ToolHandler<Record<string, unknown>, unknown>
>;

export async function executeTool(
  registry: ToolRegistry,
  tool: string,
  modelArgs: Record<string, unknown>,
  ctx: ToolContext,
) {
  if (!ctx.authenticatedUserId) {
    throw new Error("Tool execution requires an authenticated user.");
  }

  const handler = registry[tool];
  if (!handler) {
    throw new Error(`Unknown tool: ${tool}`);
  }

  const offendingKeys = Object.keys(modelArgs).filter(isIdentityField);
  if (offendingKeys.length > 0) {
    safeLogger.warn("Tool identity violation rejected", {
      event: "tool_identity_violation",
      userId: ctx.authenticatedUserId,
      tool,
      outcome: "rejected",
      offendingKeyCount: offendingKeys.length,
    });
    throw new ToolIdentityViolationError(tool, offendingKeys);
  }

  return handler(
    { ...modelArgs, userId: ctx.authenticatedUserId },
    ctx,
  );
}
