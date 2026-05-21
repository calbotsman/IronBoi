import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { CoachAgentContract } from "./contracts/coach-agent.js";
import { CoachToolRequest } from "./contracts/tool-calls.js";

async function readJson(path: string): Promise<unknown> {
  return JSON.parse(await readFile(path, "utf8"));
}

async function main() {
  const root = resolve("src");
  const agent = await readJson(resolve(root, "coach/ironboi-coach.v0.json"));
  CoachAgentContract.parse(agent);

  const safety = await readJson(resolve(root, "evals/safety-evals.json"));
  if (
    typeof safety !== "object" ||
    safety === null ||
    !("releaseGate" in safety) ||
    !("cases" in safety) ||
    safety.releaseGate !== true ||
    !Array.isArray(safety.cases) ||
    safety.cases.length < 8
  ) {
    throw new Error("Safety evals must be a release gate with at least 8 cases.");
  }

  const seed = await readJson(resolve(root, "domain/ironlab-seed.json"));
  if (
    typeof seed !== "object" ||
    seed === null ||
    !("EXERCISE_DB" in seed) ||
    !("DEFAULT_PLAN" in seed)
  ) {
    throw new Error("Iron Lab seed data is missing required exercise or plan data.");
  }

  const examples = await readJson(
    resolve(root, "contracts/tool-call-examples.json"),
  );
  if (
    typeof examples !== "object" ||
    examples === null ||
    !("log_workout_request" in examples) ||
    !("generate_plan_request" in examples)
  ) {
    throw new Error("Tool-call examples are incomplete.");
  }

  CoachToolRequest.parse(examples.log_workout_request);
  CoachToolRequest.parse(examples.generate_plan_request);

  console.log("IronBoi Functions Phase 0 validated.");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
