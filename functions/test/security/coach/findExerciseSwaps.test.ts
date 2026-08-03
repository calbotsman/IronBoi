import { describe, expect, it } from "vitest";
import { getFirestore } from "firebase-admin/firestore";
import { getApps, initializeApp } from "firebase-admin/app";
import {
  COACH_TOOL_DECLARATIONS,
  buildCoachToolRegistry,
} from "../../../src/coach/toolRegistry.js";

// find_exercise_swaps is READ-ONLY and takes no Firestore reads, but
// buildCoachToolRegistry needs a db handle for its other handlers.
const app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
const db = getFirestore(app);
const registry = buildCoachToolRegistry(db, { latestPendingProposalId: null });

const USER_ID = "coach-swap-tool-user";

async function call(args: Record<string, unknown>) {
  return (await registry.find_exercise_swaps({ userId: USER_ID, ...args })) as {
    ok: boolean;
    options?: Array<{ name: string; primary: string[]; equipment: string[]; reason: string }>;
    hint?: string;
    error?: string;
  };
}

describe("find_exercise_swaps coach tool", () => {
  it("is declared to the model", () => {
    const declaration = COACH_TOOL_DECLARATIONS.find(
      (tool) => tool.name === "find_exercise_swaps",
    );
    expect(declaration).toBeDefined();
    expect(declaration?.parameters.required).toEqual(["exerciseName"]);
  });

  it("returns catalog-grounded options the app can actually render", async () => {
    const result = await call({ exerciseName: "Barbell Bench Press" });
    expect(result.ok).toBe(true);
    expect(result.options?.length).toBeGreaterThan(0);
    for (const option of result.options ?? []) {
      expect(option.name.length).toBeGreaterThan(0);
      expect(option.reason.length).toBeGreaterThan(0);
    }
  });

  it("resolves the shorthand a plan actually uses", async () => {
    const result = await call({ exerciseName: "Bench Press" });
    expect(result.options?.length).toBeGreaterThan(0);
  });

  it("returns bodyweight-only options for an empty equipment array", async () => {
    const result = await call({ exerciseName: "Barbell Back Squat", availableEquipment: [] });
    expect(result.options?.length).toBeGreaterThan(0);
    for (const option of result.options ?? []) {
      expect(option.equipment.every((item) => item === "none")).toBe(true);
    }
  });

  it("ignores equipment strings outside the catalog vocabulary", async () => {
    // A model sending "resistance_bands" should still get useful options —
    // an unknown filter can only widen the result set, never fabricate one.
    const result = await call({
      exerciseName: "Barbell Bench Press",
      availableEquipment: ["resistance_bands", "dumbbell", "bench"],
    });
    expect(result.ok).toBe(true);
    expect(result.options?.map((option) => option.name)).toContain("Dumbbell Bench Press");
  });

  it("tells the model NOT to invent a substitute when nothing matches", async () => {
    const result = await call({ exerciseName: "Underwater Basket Weaving" });
    expect(result.ok).toBe(true);
    expect(result.options).toEqual([]);
    expect(result.hint).toContain("Do not invent");
  });

  it("rejects malformed args", async () => {
    const result = await call({ exerciseName: "" });
    expect(result.ok).toBe(false);
    expect(result.error).toBe("invalid_find_exercise_swaps_args");
  });

  it("rejects identity-shaped args at the schema layer", async () => {
    // The request schema is .strict(); an unknown key fails the parse rather
    // than being silently dropped.
    const result = await call({ exerciseName: "Push-ups", onBehalfOf: "someone-else" });
    expect(result.ok).toBe(false);
  });
});
