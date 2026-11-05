import type { LiveWorkoutState } from "../contracts/coach-agent.js";
import { isCardioExercise, isTimedExercise } from "../workouts/exerciseCatalog.js";

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
  // Holds and cardio are done for time; the app clips targetReps to 200,
  // so a 20-minute bike (1200 s) isn't worth quoting as a number.
  const target = isCardioExercise(state.exercise)
    ? "a cardio block done for time (the app runs the timer)"
    : isTimedExercise(state.exercise)
      ? `${state.targetReps} seconds`
      : `${state.targetReps} reps`;
  const order = state.exercises.map((name, i) => `${i + 1}. ${clean(name)}`).join("; ");
  return [
    "<live_workout>",
    `The user is in the middle of a workout right now${state.workoutName ? ` (${clean(state.workoutName)})` : ""}.`,
    `Current exercise: ${exercise} — exercise ${state.exerciseNumber} of ${state.exercises.length}, set ${state.setNumber} of ${state.totalSets}, ${target}${weight}.${counted}`,
    `Today's exercises in order: ${order}.`,
    `"This", "this one", "it", "these" and "the exercise" mean ${exercise} unless they name another one. Never ask which exercise they mean when they could mean the current one.`,
    "If they ask to change how they do it (seated instead of standing, kneeling, incline, dumbbells instead of a barbell, a lighter weight), answer for the current exercise by name in one or two sentences, and name the changed version in full (for example \"Seated Dumbbell Shoulder Press\") so the app can show and log it.",
    "Adding to today's session — cardio (indoor cycling, a run, the rower) or another exercise — is done by the app the moment they say it (\"I'm adding 20 minutes on the bike\"); it adds the block and runs a timer for cardio. If such a request reaches you, never call adapt_plan or propose a plan change: say it's added if a [app] line says so, otherwise tell them to say it like \"add 20 minutes of indoor cycling\".",
    "</live_workout>",
  ].join("\n");
}
