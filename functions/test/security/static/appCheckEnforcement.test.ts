import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { CALLABLE_OPTS, callableOpts } from "../../../src/index.js";

// Phase 3 Task 3.2 — App Check enforcement contract (env-gated).
//
// Enforcement is driven by IRONBOI_ENFORCE_APP_CHECK (see the comment on
// callableOpts in src/index.ts and docs/operations/appcheck-enable-runbook.md).
// This suite pins the REAL contract both ways:
//   - flag set to "true"  → enforceAppCheck + consumeAppCheckToken are true
//   - flag absent / other → both are false (the safe default)
// and guards against the regression where a new onCall bypasses
// CALLABLE_OPTS with an inline `{ region: ... }` config.

describe("Phase 3.2 — App Check enforcement on callables (env-gated)", () => {
  it("enforces_AppCheck_and_consumes_token_when_flag_is_true", () => {
    const opts = callableOpts({ IRONBOI_ENFORCE_APP_CHECK: "true" });
    expect(opts.enforceAppCheck).toBe(true);
    expect(opts.consumeAppCheckToken).toBe(true);
    expect(opts.region).toBe("us-central1");
  });

  it("defaults_OFF_when_flag_is_absent", () => {
    const opts = callableOpts({});
    expect(opts.enforceAppCheck).toBe(false);
    expect(opts.consumeAppCheckToken).toBe(false);
    expect(opts.region).toBe("us-central1");
  });

  it("treats_anything_but_the_string_true_as_OFF", () => {
    for (const value of ["1", "TRUE", "yes", "false", ""]) {
      const opts = callableOpts({ IRONBOI_ENFORCE_APP_CHECK: value });
      expect(opts.enforceAppCheck, `IRONBOI_ENFORCE_APP_CHECK=${JSON.stringify(value)}`).toBe(false);
      expect(opts.consumeAppCheckToken).toBe(false);
    }
  });

  it("CALLABLE_OPTS_is_derived_from_the_process_environment", () => {
    // The module resolves CALLABLE_OPTS from process.env at import time.
    // Assert it matches callableOpts(process.env) so the test is correct
    // whether or not the flag happens to be set in the test environment.
    expect(CALLABLE_OPTS).toEqual(callableOpts(process.env));
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
