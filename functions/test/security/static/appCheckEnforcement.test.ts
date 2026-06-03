import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { CALLABLE_OPTS } from "../../../src/index.js";

// Phase 3 Task 3.2 — guard against regressions.
//
// Every onCall in index.ts is configured via CALLABLE_OPTS. If someone
// removes enforceAppCheck or consumeAppCheckToken there (or replaces
// CALLABLE_OPTS with a bare config inline at a single call site), this
// test fails and the security suite goes red before deploy.
//
// We also assert via a substring grep that no onCall in index.ts uses
// an inline `{ region: ... }` config — that would bypass enforcement
// entirely.

describe("Phase 3.2 — App Check enforcement on callables", () => {
  it("CALLABLE_OPTS_enforces_AppCheck_and_consumes_token", () => {
    expect(CALLABLE_OPTS.enforceAppCheck).toBe(true);
    expect(CALLABLE_OPTS.consumeAppCheckToken).toBe(true);
    expect(CALLABLE_OPTS.region).toBe("us-central1");
  });

  it("no_callable_in_index_uses_a_bypass_inline_config", () => {
    // Catches the regression where someone adds a new onCall with
    // `{ region: "us-central1" }` (no App Check) instead of going
    // through CALLABLE_OPTS. Allow `onCall(CALLABLE_OPTS,` inline
    // or `onCall(\n  CALLABLE_OPTS,` multiline — reject anything else.
    const indexPath = path.resolve(process.cwd(), "src/index.ts");
    const source = fs.readFileSync(indexPath, "utf8");
    const callableSites = source.match(/onCall\s*\(\s*[^,)]+/g) ?? [];
    const offending = callableSites.filter(
      (site) => !/CALLABLE_OPTS/.test(site),
    );
    expect(offending, "every onCall must route through CALLABLE_OPTS").toEqual([]);
  });
});
