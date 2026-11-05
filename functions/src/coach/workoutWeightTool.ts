import { z } from "zod";
import type { LiveWorkoutState } from "../contracts/coach-agent.js";
import { loadBasis, weightPhrase } from "../workouts/loadBasis.js";
import type { CoachToolDeclaration } from "./modelProvider.js";

/**
 * Changing the weight of the lift in progress. The workout lives on the
 * phone, so this tool changes nothing here: it checks the call, works out
 * what the weight becomes (so the reply says the right number), and hands
 * the phone a `clientActions` entry on the coach's message (the channel
 * replace_session uses, sessionSwitch.ts), which the
 * phone applies with the same rules (ios Models/WeightLoad.swift resolve).
 * Live voice declares the same tool and the phone runs it directly.
 *
 * Why: 2026-11-05, "I'm increasing the weight" mid-workout changed nothing —
 * the phone's quick rule needs a number, and the coach had no way to touch
 * the workout.
 */
export const SET_WORKOUT_WEIGHT: CoachToolDeclaration = {
  name: "set_workout_weight",
  description:
    "During a workout: change the weight for the remaining sets of an exercise in today's session, right now (no review card). " +
    "Use it whenever they say they're going up, down, heavier, lighter or to a number, however they phrase it. " +
    "Send `weight` for a new number (\"bump it to 40\") or `change` for a difference (\"add 5 pounds\" = 5, \"drop 10\" = -10). " +
    "If they gave no number (\"I'm going up\", \"going heavier on this one\"), call it with no weight and no change — the app then listens for the number — and ask \"Up to what?\". " +
    "For lifts done with two dumbbells or kettlebells the app counts the weight of ONE of them; send basis \"each\" or \"total\" when they said which, and if it's genuinely unclear ask \"35 each hand?\" before calling.",
  parameters: {
    type: "object",
    properties: {
      exerciseName: { type: "string", description: "As named in today's workout. Omit for the one they're on." },
      weight: { type: "number", description: "The new weight, in `unit`." },
      change: { type: "number", description: "How much heavier (positive) or lighter (negative), in `unit`." },
      unit: { type: "string", enum: ["lb", "kg"], description: "lb unless they said kilos." },
      basis: {
        type: "string",
        enum: ["each", "total"],
        description: "For two-dumbbell or two-kettlebell lifts: whether their number is per hand (each) or both together (total). Omit if they didn't say.",
      },
    },
  },
};

export const SetWorkoutWeightArgs = z.object({
  exerciseName: z.string().trim().min(1).max(80).optional(),
  weight: z.number().min(0).max(2000).optional(),
  change: z.number().min(-500).max(500).refine((n) => n !== 0).optional(),
  unit: z.enum(["lb", "kg"]).default("lb"),
  basis: z.enum(["each", "total"]).optional(),
}).strict().refine((a) => a.weight === undefined || a.change === undefined, {
  message: "weight_or_change_not_both",
});

/** What the phone does with it, saved on the coach's message. */
export type WorkoutAction =
  | { type: "set_weight"; exerciseName: string; toLb?: number; byLb?: number; basis?: "each" | "total" }
  | { type: "ask_weight"; exerciseName: string };

/** kg → lb on the 2.5 lb grid, the same as the phone's own parser. */
function toPounds(value: number, unit: "lb" | "kg"): number {
  return unit === "kg" ? Math.round((value * 2.20462) / 2.5) * 2.5 : value;
}

function sameName(a: string, b: string): boolean {
  const key = (s: string) => s.toLowerCase().replace(/[^a-z]/g, "");
  return key(a) === key(b);
}

export function runSetWorkoutWeight(
  rawArgs: unknown,
  live: LiveWorkoutState | undefined,
): { result: Record<string, unknown>; action?: WorkoutAction } {
  if (!live) return { result: { ok: false, error: "no_workout_in_progress" } };
  const parsed = SetWorkoutWeightArgs.safeParse(rawArgs ?? {});
  if (!parsed.success) return { result: { ok: false, error: "invalid_set_workout_weight_args" } };
  const args = parsed.data;
  const named = args.exerciseName
    ? live.exercises.find((name) => sameName(name, args.exerciseName!))
    : live.exercise;
  if (!named) return { result: { ok: false, error: "exercise_not_in_workout", exercises: live.exercises } };

  if (args.weight === undefined && args.change === undefined) {
    return {
      result: { ok: true, waitingForNumber: true, say: "Ask how heavy, briefly: \"Up to what?\"" },
      action: { type: "ask_weight", exerciseName: named },
    };
  }

  const basis = loadBasis(named);
  const halve = basis === "each" && args.basis === "total";
  const toLb = args.weight === undefined ? undefined : toPounds(args.weight, args.unit);
  const byLb = args.change === undefined ? undefined : toPounds(args.change, args.unit);
  // Only the lift they're on has a known current weight here; the phone
  // works out the rest itself.
  const current = sameName(named, live.exercise) ? (live.weightLb ?? 0) : undefined;
  const raw = toLb !== undefined
    ? (halve ? toLb / 2 : toLb)
    : current !== undefined ? current + (halve ? byLb! / 2 : byLb!) : undefined;
  const resulting = raw === undefined ? undefined : Math.min(Math.max(raw, 0), 2000);
  return {
    result: {
      ok: true,
      exercise: named,
      ...(resulting !== undefined
        ? { nowLb: resulting, say: `Confirm in one short sentence: ${named} at ${weightPhrase(resulting, named)}.` }
        : { say: "Confirm the change in one short sentence." }),
    },
    action: {
      type: "set_weight",
      exerciseName: named,
      ...(toLb !== undefined ? { toLb } : {}),
      ...(byLb !== undefined ? { byLb } : {}),
      ...(args.basis ? { basis: args.basis } : {}),
    },
  };
}
