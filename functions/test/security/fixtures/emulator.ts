import fs from "node:fs";
import path from "node:path";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
  type RulesTestEnvironment,
} from "@firebase/rules-unit-testing";

let testEnv: RulesTestEnvironment | undefined;

export async function getTestEnv() {
  if (!testEnv) {
    const rulesPath = path.resolve(process.cwd(), "../firestore.rules");
    testEnv = await initializeTestEnvironment({
      projectId: "demo-ironboi-security",
      firestore: {
        rules: fs.readFileSync(rulesPath, "utf8"),
      },
    });
  }
  return testEnv;
}

export async function clearFirestore() {
  const env = await getTestEnv();
  await env.clearFirestore();
}

export async function cleanupTestEnv() {
  if (!testEnv) return;
  await testEnv.cleanup();
  testEnv = undefined;
}

export async function authedDb(uid: string) {
  const env = await getTestEnv();
  return env.authenticatedContext(uid).firestore();
}

export async function unauthedDb() {
  const env = await getTestEnv();
  return env.unauthenticatedContext().firestore();
}

export async function withAdminDb<T>(
  callback: (db: ReturnType<RulesTestEnvironment["unauthenticatedContext"]>["firestore"]) => Promise<T>,
) {
  const env = await getTestEnv();
  return env.withSecurityRulesDisabled(async (context) => callback(context.firestore()));
}

export { assertFails, assertSucceeds };
