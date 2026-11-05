import { canonicalEquipment } from "../workouts/planFit.js";

type Draft = Record<string, unknown>;

const DAY_WORDS: Array<[RegExp, string]> = [
  [/\bmon(day)?s?\b/, "Mon"], [/\btue(s|sday)?s?\b/, "Tue"], [/\bwed(nesday)?s?\b/, "Wed"],
  [/\bthu(r|rs|rsday)?s?\b/, "Thu"], [/\bfri(day)?s?\b/, "Fri"], [/\bsat(urday)?s?\b/, "Sat"], [/\bsun(day)?s?\b/, "Sun"],
];
const WEEK = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

/**
 * Someone looking at their drafted week and talking about it: "can we do
 * Tuesdays instead of Mondays, I've only got 40 minutes, and my left knee
 * is bad". Reads what it can into the same draft fields the cards fill, so
 * the plan is rebuilt from it; everything said is also kept as a note the
 * coach sees once the plan is accepted. Deterministic on purpose: it has
 * to be fast (they're looking at the screen) and never invent a change.
 */
export function reviseDraftFromWords(draft: Draft, words: string): { draft: Draft; changes: string[] } {
  const text = words.toLowerCase().replace(/[’‘]/g, "'");
  const next: Draft = { ...draft };
  const changes: string[] = [];

  // Days. "Instead of Monday" / "not Fridays" removes; named days are kept.
  const current = Array.isArray(draft.preferredDays) ? (draft.preferredDays as string[]) : [];
  const named = DAY_WORDS.filter(([pattern]) => pattern.test(text)).map(([, day]) => day);
  if (named.length > 0) {
    const removed = DAY_WORDS
      .filter(([pattern]) => new RegExp(`(instead of|not|no|can't do|cannot do|skip|drop|except|off)\\s+(on\\s+)?${pattern.source.replace(/\\b/g, "")}`).test(text))
      .map(([, day]) => day);
    const swapping = removed.length > 0 || /\b(instead|swap|move|switch|change)\b/.test(text);
    const adding = /\b(add|also|plus|another|extra)\b/.test(text);
    let days: string[];
    if (swapping || adding) {
      days = [...new Set([...current.filter((day) => !removed.includes(day)), ...named.filter((day) => !removed.includes(day))])];
    } else {
      days = named;
    }
    days = WEEK.filter((day) => days.includes(day));
    if (days.length > 0 && days.join() !== current.join()) {
      next.preferredDays = days;
      next.daysPerWeek = days.length;
      changes.push(`training ${days.join(", ")}`);
    }
  } else {
    // "Only three days", "four days a week".
    const count = text.match(/\b(two|three|four|five|six|2|3|4|5|6)\s+days?\b/);
    if (count) {
      const n = ({ two: 2, three: 3, four: 4, five: 5, six: 6 } as Record<string, number>)[count[1]] ?? Number(count[1]);
      if (n !== current.length && n >= 2 && n <= 6) {
        const preferred = ["Mon", "Wed", "Fri", "Tue", "Thu", "Sat", "Sun"];
        const kept = current.slice(0, n);
        const days = WEEK.filter((day) => [...kept, ...preferred.filter((d) => !kept.includes(d))].slice(0, n).includes(day));
        next.preferredDays = days;
        next.daysPerWeek = n;
        changes.push(`${n} days a week`);
      }
    }
  }

  // Session length: "40 minutes", "an hour", "half an hour".
  let minutes: number | undefined;
  const mins = text.match(/\b(\d{2,3})\s*(min|mins|minutes)\b/);
  if (mins) minutes = Number(mins[1]);
  else if (/\bhalf an hour\b/.test(text)) minutes = 30;
  else if (/\b(an|one) hour\b/.test(text)) minutes = 60;
  if (minutes && minutes >= 15 && minutes <= 120 && minutes !== draft.sessionLengthMin) {
    next.sessionLengthMin = minutes;
    changes.push(`${minutes}-minute sessions`);
  }

  // Gear they now mention: added to what they have (or replaces it with
  // "only"/"just").
  const mentioned = canonicalEquipment([text]).filter((item) => item !== "bodyweight" && item !== "full gym");
  if (mentioned.length > 0 && /dumbbell|barbell|kettle|bench|pull[- ]?up|band|cable|machine|med(icine)? ?ball|sandbag|club|rack/.test(text)) {
    const before = Array.isArray(draft.equipment) ? (draft.equipment as string[]) : [];
    const only = /\b(only|just)\b/.test(text);
    const gear = only ? mentioned : [...new Set([...before.filter((item) => item !== "bodyweight"), ...mentioned])];
    if (gear.sort().join() !== [...before].sort().join()) {
      next.equipment = gear;
      changes.push(`gear: ${gear.join(", ")}`);
    }
  } else if (/\b(at|in) (a|the) gym\b|\bgym membership\b|\bfull gym\b/.test(text) && !/home gym/.test(text)) {
    if (!(Array.isArray(draft.equipment) && (draft.equipment as string[]).includes("full gym"))) {
      next.equipment = ["full gym"];
      changes.push("a full gym");
    }
  }

  // Structure: "full body", "a split", "more upper body".
  if (/\bfull[- ]body\b/.test(text) && draft.trainingFocus !== "full_body") {
    next.trainingFocus = "full_body";
    changes.push("full-body sessions");
  } else if (/\b(split|push pull legs|ppl|body ?part)\b/.test(text) && draft.trainingFocus !== "muscle_split") {
    next.trainingFocus = "muscle_split";
    changes.push("a split");
  }

  // Pain or an injury: it joins their limitations, in their words, so the
  // plan is built around it and the coach asks about it.
  const pain = text.match(/[^.!?]*\b(hurts?|pain|injur(y|ed)|bad (knee|back|shoulder|hip|wrist|elbow|ankle)|tweaked|surgery|torn|sprain(ed)?|herniat\w*|arthritis)\b[^.!?]*/);
  if (pain) {
    const note = pain[0].trim().replace(/^(and|but|also)\s+/, "");
    const limits = Array.isArray(draft.injuriesOrLimitations)
      ? (draft.injuriesOrLimitations as string[]).filter((item) => item !== "none") : [];
    if (note && !limits.includes(note)) {
      next.injuriesOrLimitations = [...limits, note];
      changes.push(`working around: ${note}`);
    }
  }

  // Everything they said, kept for the coach (capped).
  const notes = Array.isArray(draft.planNotes) ? (draft.planNotes as string[]) : [];
  next.planNotes = [...notes, words.trim().slice(0, 300)].slice(-8);
  return { draft: next, changes };
}

/** "Done: training Tue, Thu, Sat, and 40-minute sessions." */
export function revisionReply(changes: string[]): string {
  if (changes.length === 0) {
    return "Got it, I'll keep that in mind as we train. Anything else to change, or are you ready to start?";
  }
  const list = changes.length === 1 ? changes[0] : `${changes.slice(0, -1).join(", ")} and ${changes[changes.length - 1]}`;
  return `Done. Updated your week: ${list}. Anything else?`;
}
