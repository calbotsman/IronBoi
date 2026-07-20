import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { CALLABLE_OPTS, callableOpts } from "../../../src/index.js";

// Phase 3 Task 3.2 — App Check enforcement contract (env-gated).
//
// Enforcement is driven by IRONBOI_ENFORCE_APP_CHECK (see the comment on
// callableOpts in src/index.ts and docs/operations/appcheck-enable-runbook.md).
// This suite pins the REAL contract:
//   - IRONBOI_ENFORCE_APP_CHECK="true" → enforceAppCheck true
//   - consumeAppCheckToken additionally requires IRONBOI_CONSUME_APP_CHECK
//     ="true" (one-shot tokens replay-reject cached-token reuse; the client
//     must adopt limited-use tokens before consumption is safe — the
//     callable migration made callables the high-frequency path)
//   - flags absent / other values → everything false (the safe default)
// and guards against the regression where a new onCall bypasses
// CALLABLE_OPTS with an inline `{ region: ... }` config.

describe("Phase 3.2 — App Check enforcement on callables (env-gated)", () => {
  it("enforces_AppCheck_when_flag_is_true_without_consuming_tokens", () => {
    const opts = callableOpts({ IRONBOI_ENFORCE_APP_CHECK: "true" });
    expect(opts.enforceAppCheck).toBe(true);
    // Consumption stays OFF until its own flag opts in — cached-token reuse
    // would replay-reject high-frequency callable traffic otherwise.
    expect(opts.consumeAppCheckToken).toBe(false);
    expect(opts.region).toBe("us-central1");
  });

  it("consumes_tokens_only_when_BOTH_flags_are_true", () => {
    const both = callableOpts({
      IRONBOI_ENFORCE_APP_CHECK: "true",
      IRONBOI_CONSUME_APP_CHECK: "true",
    });
    expect(both.enforceAppCheck).toBe(true);
    expect(both.consumeAppCheckToken).toBe(true);

    // Consume without enforce is meaningless — stays off.
    const consumeOnly = callableOpts({ IRONBOI_CONSUME_APP_CHECK: "true" });
    expect(consumeOnly.enforceAppCheck).toBe(false);
    expect(consumeOnly.consumeAppCheckToken).toBe(false);
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
