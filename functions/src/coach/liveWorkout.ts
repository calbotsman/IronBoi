import type { LiveWorkoutState } from "../contracts/coach-agent.js";

/** One line of plan text, safe to put in the prompt. */
function clean(text: string): string {
  return text.replace(/[\r\n<>]+/g, " ").replace(/\s+/g, " ").trim().slice(0, 80);
}

/**
 * The system-prompt block for a user who is mid-workout. Without it the
 * coach had no idea which exercise "this one" was (2026-10-12: "can I do
 * these seated?" got "which exercise?" while the user was on the shoulder
 * press).
 */
export function liveWorkoutRules(state: LiveWorkoutState | undefined): string | null {
  if (!state) return null;
  const exercise = clean(state.exercise);
  const weight = state.weightLb && state.weightLb > 0 ? ` at ${Math.round(state.weightLb)} lb` : "";
  const counted = state.repsCountedThisSet && state.repsCountedThisSet > 0
    ? ` They have counted ${state.repsCountedThisSet} reps of this set so far.`
    : "";
  const order = state.exercises.map((name, i) => `${i + 1}. ${clean(name)}`).join("; ");
  return [
    "<live_workout>",
    `The user is in the middle of a workout right now${state.workoutName ? ` (${clean(state.workoutName)})` : ""}.`,
    `Current exercise: ${exercise} — exercise ${state.exerciseNumber} of ${state.exercises.length}, set ${state.setNumber} of ${state.totalSets}, ${state.targetReps} reps${weight}.${counted}`,
    `Today's exercises in order: ${order}.`,
    `"This", "this one", "it", "these" and "the exercise" mean ${exercise} unless they name another one. Never ask which exercise they mean when they could mean the current one.`,
    "If they ask to change how they do it (seated instead of standing, kneeling, incline, dumbbells instead of a barbell, a lighter weight), answer for the current exercise by name in one or two sentences, and name the changed version in full (for example \"Seated Dumbbell Shoulder Press\") so the app can show and log it.",
    "</live_workout>",
  ].join("\n");
}
