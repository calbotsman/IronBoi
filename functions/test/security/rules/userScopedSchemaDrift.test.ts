import fs from "node:fs";
import path from "node:path";
import { doc, setDoc } from "firebase/firestore";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import {
  clientOwnerWriteKeys,
  listClientWritableCollections,
} from "../../../src/access/userScopedSchema.js";
import {
  assertFails,
  assertSucceeds,
  authedDb,
  cleanupTestEnv,
  clearFirestore,
} from "../fixtures/emulator.js";
import { USER_A } from "../fixtures/users.js";

// Phase 2 Task 2.1 + 2.2 — drift detection.
//
// The Zod schemas in contracts/ are the source of truth for which fields
// each client-writable collection allows. firestore.rules' hasOnly() lists
// must match. This test catches drift in either direction:
//
//   - You added a field to a Zod schema but forgot to update firestore.rules
//     → the rules' allowlist is missing the new key → drift test fails.
//   - You added a key to firestore.rules' allowlist without a schema change
//     → the schema-derived list doesn't include the new key → drift test fails.
//
// The test parses firestore.rules as text. Fragile, but the rule files are
// short, hand-edited, and the alternative (a TS-to-rules compiler) is multi-
// day work. Parser is intentionally strict — any rule-file formatting
// change near `onlyKeys([...])` will fail loudly so it gets reviewed.

const RULES_PATH = path.resolve(process.cwd(), "../firestore.rules");

function readRulesText(): string {
  return fs.readFileSync(RULES_PATH, "utf8");
}

// Given a Firestore rules collection name (e.g. "workoutLogs"), find the
// `match /workoutLogs/{...}` block and extract the keys array passed to
// `onlyKeys([...])` inside it. Returns null if no `onlyKeys()` call is
// present (server-only collections, etc.).
function extractOnlyKeysFromRules(
  rulesText: string,
  collectionName: string,
): string[] | null {
  // Match the match block — collectionName followed by /{...} then everything
  // up to the closing brace of that match block. Non-greedy on inner braces.
  const matchBlockPattern = new RegExp(
    `match\\s+/${collectionName}/\\{[^}]+\\}\\s*\\{([\\s\\S]*?)\\n      \\}`,
    "m",
  );
  const matchBlock = rulesText.match(matchBlockPattern);
  if (!matchBlock) {
    throw new Error(
      `Could not find match block for "${collectionName}" in firestore.rules — drift parser is out of date`,
    );
  }
  const onlyKeysPattern = /onlyKeys\(\[([^\]]+)\]\)/;
  const onlyKeysMatch = matchBlock[1].match(onlyKeysPattern);
  if (!onlyKeysMatch) {
    return null;
  }
  return onlyKeysMatch[1]
    .split(",")
    .map((entry) => entry.trim().replace(/^"|"$/g, ""))
    .filter((entry) => entry.length > 0);
}

describe("userScopedSchema ↔ firestore.rules drift", () => {
  it("every client-writable collection in the schema has matching onlyKeys() in firestore.rules", () => {
    const rulesText = readRulesText();

    for (const key of listClientWritableCollections()) {
      const schemaKeys = [...clientOwnerWriteKeys(key)].sort();
      const rulesKeys = extractOnlyKeysFromRules(rulesText, key);

      if (rulesKeys === null) {
        throw new Error(
          `firestore.rules has no onlyKeys() call for "${key}", but the schema marks it client_owner. ` +
            `Either add the onlyKeys allowlist to firestore.rules or change the write tier in userScopedSchema.ts.`,
        );
      }

      const sortedRules = [...rulesKeys].sort();
      expect(sortedRules, `firestore.rules onlyKeys for "${key}" must match schema`).toEqual(
        schemaKeys,
      );
    }
  });
});

describe("Firestore rules enforce client-writable allowlists", () => {
  const ISO = "2026-05-22T00:00:00.000Z";

  function validWorkoutLog(extra: Record<string, unknown> = {}) {
    return {
      userId: USER_A,
      sessionId: "sess-1",
      date: "2026-05-22",
      source: "manual",
      exercises: [],
      createdAt: ISO,
      ...extra,
    };
  }

  beforeEach(async () => {
    await clearFirestore();
  });

  afterAll(async () => {
    await cleanupTestEnv();
  });

  it("workoutLog with only allowed keys succeeds", async () => {
    const db = await authedDb(USER_A);
    await assertSucceeds(
      setDoc(doc(db, `users/${USER_A}/workoutLogs/log-1`), validWorkoutLog()),
    );
  });

  it("workoutLog with an unknown extra field fails", async () => {
    const db = await authedDb(USER_A);
    await assertFails(
      setDoc(
        doc(db, `users/${USER_A}/workoutLogs/log-1`),
        validWorkoutLog({ injectedField: "should_be_rejected" }),
      ),
    );
  });

  it("workoutLog with a mismatched userId fails", async () => {
    // Owner is USER_A but the document carries USER_B's id — used to be
    // accepted (rules only checked path ownership). Now blocked at write.
    const db = await authedDb(USER_A);
    await assertFails(
      setDoc(
        doc(db, `users/${USER_A}/workoutLogs/log-1`),
        validWorkoutLog({ userId: "USER_B" }),
      ),
    );
  });
});
