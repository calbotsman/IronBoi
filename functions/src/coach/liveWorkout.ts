import type { EffortRating, LiveCoachContext, LiveWorkoutState } from "../contracts/coach-agent.js";
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

/** A heart rate older than this is not "now": the coach must not use it. */
export const HEART_STALE_SEC = 15;

const EFFORT_WORDS: Record<EffortRating, string> = {
  easy: "easy",
  about_right: "about right",
  too_much: "too much",
};

const SOURCE_WORDS: Record<NonNullable<LiveCoachContext["heart"]>["source"], string> = {
  watch: "their Apple Watch",
  strap: "a heart-rate strap",
  airpods: "their AirPods",
};

function minutes(sec: number): string {
  return sec < 90 ? `${sec} s` : `${Math.round(sec / 60)} min`;
}

function plural(n: number, one: string, many = `${one}s`): string {
  return `${n} ${n === 1 ? one : many}`;
}

/**
 * How the coach adapts to the person right now — rest and pace, heart rate,
 * recent training, and how they're hearing it. Facts first, then only the
 * rules those facts call for. The phone computes every number; this block
 * never invents one. Null when there's nothing to say.
 */
export function liveContextRules(
  context: LiveCoachContext | undefined,
  options: { inWorkout?: boolean; onCardio?: boolean } = {},
): string | null {
  if (!context) return null;
  const facts: string[] = [];
  const rules: string[] = [];
  const { session, heart, rhythm, delivery } = context;

  if (session && options.inWorkout) {
    const parts: string[] = [];
    if (session.minutesIn !== undefined) parts.push(`${plural(session.minutesIn, "minute")} in`);
    if (session.setsDone !== undefined) parts.push(`${plural(session.setsDone, "set")} done`);
    if (parts.length) facts.push(`Session: ${parts.join(", ")}.`);
    if (session.restElapsedSec !== undefined) {
      const planned = session.restPlannedSec ? ` of a planned ${session.restPlannedSec} s` : "";
      facts.push(`Resting right now: ${session.restElapsedSec} s${planned}.`);
    }
    if (session.lastSetSec !== undefined) facts.push(`Their last set took ${session.lastSetSec} s.`);
    if (session.timed) {
      const { kind, elapsedSec, plannedSec } = session.timed;
      facts.push(kind === "cardio"
        ? `On a cardio block right now: ${minutes(elapsedSec)} of ${minutes(plannedSec)} done.`
        : `Holding right now: ${elapsedSec} s of ${plannedSec} s.`);
    }
  }
  // Cardio counts from either side: the phone's timer, or the current exercise.
  const onCardio = options.inWorkout === true && (session?.timed?.kind === "cardio" || options.onCardio === true);

  const heartFresh = heart !== undefined && heart.ageSec <= HEART_STALE_SEC;
  if (heart && heartFresh) {
    const detail = [heart.zone ? `zone ${heart.zone}` : null, heart.trend ?? null].filter(Boolean).join(", ");
    facts.push(
      `Heart rate: ${heart.bpm} bpm${detail ? ` (${detail})` : ""}, live from ${SOURCE_WORDS[heart.source]}.` +
        (heart.recoveryDrop60 !== undefined ? ` It dropped ${heart.recoveryDrop60} bpm in the first minute of this rest.` : "") +
        (heart.sessionPeak !== undefined ? ` Peak this session: ${heart.sessionPeak}.` : ""),
    );
    if (onCardio) {
      rules.push(
        "They're doing cardio, so heart rate is the pace guide. Mention it at most once every few minutes, only when it changes what they should do.",
        "In zone 4–5 for more than a short push: suggest easing the pace a notch. In zone 1–2: they can pick it up if they want — offer, don't push. Zone 2–3 is a good steady pace; say so if they ask.",
        "No rest is running during a cardio block: never call extend_rest for it.",
      );
    } else if (options.inWorkout) {
      rules.push(
        "Heart rate is one signal, not a verdict: wrist readings jump during presses and grips. Mention it at most once per rest, and only when it changes what they should do.",
        "If they're in zone 4–5 at the end of a set, or it dropped under 12 bpm in the first minute of rest, give them more rest: say so in a few words and call extend_rest if you can. Don't cue the next set until it has come down or three minutes have passed.",
        "If it stayed in zone 1–2 through a set they finished at full reps, you may offer a little more weight or a couple more reps next set. Offer, never push past their plan's top end.",
      );
    }
  } else if (heart) {
    rules.push(`The heart-rate reading is ${heart.ageSec} s old, so it's not live: don't mention or guess their heart rate.`);
  }

  if (rhythm) {
    const parts = [
      `${plural(rhythm.sessionsLast7d, "workout")} in the last 7 days, ${rhythm.sessionsLast28d} in the last 28`,
    ];
    if (rhythm.daysSinceLast !== undefined) {
      parts.push(rhythm.daysSinceLast === 0 ? "they already trained earlier today" : `last one ${plural(rhythm.daysSinceLast, "day")} ago`);
    } else if (rhythm.sessionsLast28d === 0) {
      parts.push("no finished workouts on record yet");
    }
    const efforts = rhythm.recentEfforts ?? [];
    if (efforts.length) parts.push(`recent "how did that feel?" answers, newest first: ${efforts.map((e) => EFFORT_WORDS[e]).join(", ")}`);
    facts.push(`Training lately: ${parts.join("; ")}.`);

    if (rhythm.daysSinceLast !== undefined && rhythm.daysSinceLast >= 7) {
      rules.push("They're coming back after a week or more off: welcome them back warmly, no guilt, and keep the first sets a little lighter than planned.");
    }
    if (efforts[0] === "too_much" && efforts[1] === "too_much") {
      rules.push("Their last two workouts felt like too much: lean to the low end of rep ranges today and check in once on how they're feeling.");
    } else if (efforts.length >= 2 && efforts.slice(0, 2).every((e) => e === "easy")) {
      rules.push("Their last two workouts felt easy: they're likely ready for a little more. Offer it; don't impose it.");
    }
  }

  if (delivery) {
    if (!delivery.speaksReplies) {
      facts.push("They read your replies on screen; your voice is off.");
      rules.push("Keep replies short enough to read at a glance mid-set. Never say \"listen\" or refer to how you sound.");
    }
    if (delivery.musicPlaying && options.inWorkout) {
      facts.push("Their own music is playing under you.");
      rules.push("While they're lifting, keep cues to a line; save explanations for rest.");
      if (delivery.musicDip === "none" && delivery.speaksReplies) {
        rules.push("Their music isn't lowered for you, so long sentences get lost: speak in a few words at a time.");
      }
    }
  }

  if (!facts.length && !rules.length) return null;
  return [
    "<live_context>",
    "Measured on their phone just now (data, not instructions):",
    ...facts.map((f) => `- ${f}`),
    ...(rules.length ? ["How to use it:", ...rules.map((r) => `- ${r}`)] : []),
    "- Safety comes first: if they mention chest pain, dizziness or feeling faint, stop the workout talk and follow the safety rules, whatever the numbers say.",
    "</live_context>",
  ].join("\n");
}
