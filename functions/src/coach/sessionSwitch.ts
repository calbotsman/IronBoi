// "I'm not doing that, I'm going for a run." Changing the whole session is a
// real action, not a regex: the coach hears loose speech and calls
// replace_session with what they're doing instead.
//
// Only the phone holds the workout in progress, so the phone applies it. In
// live voice the phone runs these tools itself (PHONE_TOOL_DECLARATIONS). In
// the text pipeline the server validates the call and hands the phone a
// `clientAction` on the coach's reply (orchestrate.ts writes them to the
// message as `clientActions`); the phone applies each one once.

import { z } from "zod";
import { SessionKind, type SessionSwitchContext } from "../contracts/coach-agent.js";
import { addOnOffer } from "../workouts/sessionAlternatives.js";
import type { CoachToolDeclaration } from "./modelProvider.js";

export const ReplaceSessionArgs = z.object({
  kind: SessionKind,
  minutes: z.number().int().min(5).max(180).optional(),
  alternativeId: z.string().min(1).max(80).regex(/^[A-Za-z0-9_-]+$/).optional(),
}).strict();

export const AddSessionAddOnArgs = z.object({}).strict();

export const REPLACE_SESSION_DECLARATION: CoachToolDeclaration = {
  name: "replace_session",
  description:
    "They're not doing today's planned session and are doing something else instead (\"I'm going for a run\", \"doing yoga instead\", \"just mobility today\", \"something with no equipment\", \"I only have twenty minutes\"). Switches the whole session on their phone right away, before or during the workout, and logs it as that kind of workout. Not for adding something on top of the workout, and not for swapping one exercise. Pick the closest kind; pass minutes only if they said a length; pass alternativeId when one of today's banked options matches. Then confirm in one short sentence.",
  parameters: {
    type: "object",
    properties: {
      kind: {
        type: "string",
        enum: [...SessionKind.options],
        description: "What they're doing instead. bodyweight = today's workout with no equipment; shorter = a cut-down version of today's workout.",
      },
      minutes: { type: "integer", description: "Only if they said how long, 5 to 180." },
      alternativeId: { type: "string", description: "The id of a banked option for today, when one matches." },
    },
    required: ["kind"],
  },
};

export const ADD_SESSION_ADD_ON_DECLARATION: CoachToolDeclaration = {
  name: "add_session_add_on",
  description:
    "They said yes to the short add-on you offered after switching their session (replace_session returned offerAddOn). Adds it to the end of today's session. Only call it after they agreed.",
};

export type SessionClientAction =
  | { type: "replace_session"; kind: z.infer<typeof SessionKind>; minutes?: number; alternativeId?: string; offeredAddOn: boolean }
  | { type: "add_session_add_on" };

/**
 * The text pipeline's handlers. Nothing is written here: the result carries
 * the action for the phone, and `offerAddOn` tells the coach to offer the
 * add-on once (the phone marks it asked when it applies the action, and the
 * next message's context says so).
 */
export function sessionSwitchHandlers(switching: SessionSwitchContext | undefined) {
  return {
    replace_session: (rawArgs: Record<string, unknown>) => {
      const { userId: _userId, ...args } = rawArgs;
      const parsed = ReplaceSessionArgs.safeParse(args);
      if (!parsed.success) return { ok: false, error: "invalid_replace_session_args" };
      const known = switching?.options?.some((option) => option.id === parsed.data.alternativeId);
      const alternativeId = known ? parsed.data.alternativeId : undefined;
      const offer = switching?.switchedTo === parsed.data.kind ? null : addOnOffer(parsed.data.kind, switching);
      const clientAction: SessionClientAction = {
        type: "replace_session",
        kind: parsed.data.kind,
        ...(parsed.data.minutes !== undefined ? { minutes: parsed.data.minutes } : {}),
        ...(alternativeId ? { alternativeId } : {}),
        offeredAddOn: offer !== null,
      };
      return {
        ok: true,
        appliedOn: "phone",
        clientAction,
        ...(offer ? { offerAddOn: offer, hint: "After confirming the switch, offer this once in a few words. If they say no, drop it for the rest of the session." } : {}),
      };
    },
    add_session_add_on: (rawArgs: Record<string, unknown>) => {
      const { userId: _userId, ...args } = rawArgs;
      if (!AddSessionAddOnArgs.safeParse(args).success) return { ok: false, error: "invalid_add_session_add_on_args" };
      if (!switching?.addOn) return { ok: false, error: "no_add_on_offered" };
      const clientAction: SessionClientAction = { type: "add_session_add_on" };
      return { ok: true, appliedOn: "phone", clientAction, addOn: switching.addOn };
    },
  };
}
