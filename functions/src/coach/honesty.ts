// The coach must not say it changed the plan when nothing did. On
// 2026-10-15 it told Josh "I've noted that you'd like to run on Monday,
// Wednesday, and Tuesday. I'll factor this into your plan" with no tool
// call, and the plan never changed. A reply like that, with no tool that
// succeeded this turn, is sent back once to be done properly or said
// honestly.

const CLAIM = new RegExp(
  [
    String.raw`\b(i've|i have|i'll|i will|i'm going to|i am going to|i just|i went ahead and|done[,—-]? i)\s+`,
    String.raw`(\w+\s+){0,2}`,
    String.raw`(added|add|updated|update|changed|change|noted|note|factored|factor|put|scheduled|schedule|adjusted|adjust|built|build|included|include|swapped|swap|moved|move|rebuilt|rebuild|set up)\b`,
    String.raw`[^.!?\n]{0,80}\b(plan|schedule|program|week|routine|workouts?)\b`,
  ].join(""),
  "i",
);

/** The reply says the plan was (or will be) changed. */
export function claimsPlanChange(reply: string): boolean {
  return CLAIM.test(reply.replace(/[’‘]/g, "'"));
}

export const HONESTY_RETRY_NOTE =
  "Your draft reply said you changed or will change their plan, but no tool ran successfully this turn, so nothing changed. Do it properly now: call the right tool if one can do it (update_training_setup for lasting changes, including their runs; adapt_plan for one-off changes), then reply. If no tool can do it, or you still need a detail, say that plainly instead. Never claim a change that didn't happen.";
