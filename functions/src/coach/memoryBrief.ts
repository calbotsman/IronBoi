import type { DocumentData, Firestore } from "firebase-admin/firestore";
import { coachNotesPath, memoryBriefPath, userRoot } from "../paths.js";
import { safeLogger } from "../logging/safeLogger.js";
import { isConfirmedForPrompt } from "./context.js";
import {
  factRank,
  isLapsed,
  memoryFactForPrompt,
  workoutForPrompt,
} from "./contextBundle.js";

/**
 * The memory brief: one small, server-built page of what the coach knows
 * about this person — confirmed facts (safety and injuries always), the
 * coach's notes, the last session and this week's training — inside a fixed
 * word budget, older items summarised. Rebuilt whenever its inputs change
 * (a fact written, notes rewritten, a workout logged), stored at
 * users/{uid}/derivedSummaries/memory_brief (owner reads, server writes).
 *
 * The phone caches it on disk so a live voice session can open with it
 * straight away (see liveSession.ts). It is deterministic — no model call —
 * so a rebuild is cheap and the same inputs always give the same text.
 */
export const MEMORY_BRIEF_SCHEMA = "memory_brief.v1";
/** Hard budget for the whole brief, safety facts included. */
export const MEMORY_BRIEF_MAX_WORDS = 1_500;
/**
 * Safety facts are never dropped: up to this many words they're in full;
 * past it every safety fact is cut to a one-liner instead (30 one-liners
 * fit well inside the budget), so they can't crowd out the rest.
 */
const SAFETY_SHARE_WORDS = 600;
const SAFETY_FACT_MAX_WORDS = 80;
const SAFETY_COMPACT_WORDS = 16;
const SAFETY_FACT_MAX = 30;
const COMPACT_FACT_WORDS = 12;
const THIS_WEEK_DAYS = 7;
// Above the 100-live-fact cap (toolRegistry MAX_LIVE_MEMORY_FACTS) plus
// soft-deleted ones, so the injury-word check sees every live fact.
const FACTS_READ = 150;
const SAFETY_READ = 50;
const LOGS_READ = 30;

/** Categories that are always in the brief, whatever the budget. */
export const SAFETY_CATEGORIES = ["safety_note", "constraint"] as const;
// A pain or injury filed under another category still counts as safety.
const INJURY_WORDS = /\b(pain|injur\w*|hurt\w*|tweak\w*|strain\w*|sprain\w*|surgery|physio\w*|doctor|clinician|pregnan\w*|postpartum|tendon\w*|disc|hernia\w*|concussion)\b/i;

export type MemoryBrief = {
  schema: typeof MEMORY_BRIEF_SCHEMA;
  userId: string;
  builtAt: string;
  /** The user's date the brief was built for ("this week" is relative to it). */
  today: string;
  text: string;
  words: number;
  safetyFactCount: number;
  /** Facts that only made it in as a count, not as text. */
  summarisedFactCount: number;
};

export function countWords(text: string): number {
  const trimmed = text.trim();
  return trimmed ? trimmed.split(/\s+/).length : 0;
}

function clipWords(text: string, max: number): string {
  const words = text.trim().split(/\s+/);
  return words.length <= max ? words.join(" ") : `${words.slice(0, max).join(" ")}…`;
}

function oneLine(text: string): string {
  // The brief is read inside a data tag; no tags or line breaks of its own.
  return text.replace(/[<>]/g, " ").replace(/\s+/g, " ").trim();
}

export function isSafetyFact(fact: { category?: unknown; content?: unknown }): boolean {
  if ((SAFETY_CATEGORIES as readonly unknown[]).includes(fact.category)) return true;
  return typeof fact.content === "string" && INJURY_WORDS.test(fact.content);
}

function factDates(fact: { createdAt?: string; happenedOn?: string; until?: string }): string {
  const parts = [
    fact.happenedOn ? `happened ${fact.happenedOn}` : fact.createdAt ? `noted ${fact.createdAt.slice(0, 10)}` : "",
    fact.until ? `until ${fact.until}` : "",
  ].filter(Boolean);
  return parts.length ? ` (${parts.join(", ")})` : "";
}

/** Dates plus the factId, so forget_user_fact works from the brief alone. */
function factTail(fact: { createdAt?: string; happenedOn?: string; until?: string; factId?: string }): string {
  return `${factDates(fact)}${fact.factId ? ` [id ${oneLine(fact.factId)}]` : ""}`;
}

function daysBetween(fromIso: string, toIso: string): number {
  const from = Date.parse(`${fromIso.slice(0, 10)}T00:00:00Z`);
  const to = Date.parse(`${toIso.slice(0, 10)}T00:00:00Z`);
  if (Number.isNaN(from) || Number.isNaN(to)) return Number.POSITIVE_INFINITY;
  return Math.round((to - from) / 86_400_000);
}

/**
 * Builds the brief's text from already-loaded inputs. Order of priority when
 * the budget is tight: safety facts (never cut) → last session → coach notes
 * → this week → older training as one line → other facts in full, newest
 * first → the rest of the facts as one-line summaries → a count of the rest.
 */
export function buildMemoryBriefText(input: {
  today: string;
  facts: DocumentData[];
  coachNotes: string | null;
  logs: DocumentData[];
  maxWords?: number;
}): { text: string; words: number; safetyFactCount: number; summarisedFactCount: number } {
  const budget = input.maxWords ?? MEMORY_BRIEF_MAX_WORDS;
  const seen = new Set<string>();
  const facts = input.facts
    .filter((fact) => !fact.userDeletedAt && isConfirmedForPrompt(fact))
    .filter((fact) => !isLapsed(fact.until, input.today))
    .filter((fact) => {
      const key = String(fact.factId ?? fact.content ?? "");
      if (!key || seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .map(memoryFactForPrompt)
    .filter((fact) => fact.content.trim().length > 0)
    .sort((a, b) => factRank(a.category) - factRank(b.category) || String(b.createdAt ?? "").localeCompare(String(a.createdAt ?? "")));

  const safety = facts.filter(isSafetyFact).slice(0, SAFETY_FACT_MAX);
  const others = facts.filter((fact) => !isSafetyFact(fact));

  const fullSafety = safety.map((fact) => `- ${clipWords(oneLine(fact.content), SAFETY_FACT_MAX_WORDS)}${factTail(fact)}`);
  const safetyLines = countWords(fullSafety.join(" ")) <= SAFETY_SHARE_WORDS
    ? fullSafety
    : safety.map((fact) => `- ${clipWords(oneLine(fact.content), SAFETY_COMPACT_WORDS)}${factTail(fact)}`);

  const logs = input.logs
    .filter((log) => typeof log.date === "string")
    .sort((a, b) => String(b.date).localeCompare(String(a.date)));
  const last = logs[0];
  const lastLine = last ? `${String(last.date)}: ${oneLine(workoutForPrompt(last).summary)}` : null;
  const thisWeek = logs.slice(1).filter((log) => daysBetween(String(log.date), input.today) < THIS_WEEK_DAYS);
  const older = logs.slice(1).filter((log) => daysBetween(String(log.date), input.today) >= THIS_WEEK_DAYS);

  // Section headings and their "nothing yet" placeholders count too.
  const headingWords = countWords(
    `Safety and injuries (always included): What they've told you: - nothing else yet Your notes: Last session: none logged yet This week (the 7 days to ${input.today}): - no other sessions Earlier training:`,
  );
  let used = headingWords + countWords(safetyLines.join(" "));
  const fits = (text: string) => used + countWords(text) <= budget;
  const take = (text: string) => {
    used += countWords(text);
    return text;
  };

  const lastSession = lastLine ? take(fits(lastLine) ? lastLine : clipWords(lastLine, Math.max(COMPACT_FACT_WORDS, budget - used))) : null;
  const notes = input.coachNotes ? oneLine(input.coachNotes) : "";
  const notesLine = notes && fits(notes) ? take(notes) : null;

  const weekLines: string[] = [];
  for (const log of thisWeek) {
    const line = `- ${String(log.date)}: ${oneLine(workoutForPrompt(log).summary)}`;
    if (fits(line)) weekLines.push(take(line));
    else {
      const compact = `- ${String(log.date)}: ${clipWords(oneLine(workoutForPrompt(log).summary), COMPACT_FACT_WORDS)}`;
      if (fits(compact)) weekLines.push(take(compact));
    }
  }

  let olderLine: string | null = null;
  if (older.length > 0) {
    const byExercise = new Map<string, number>();
    for (const log of older) {
      for (const exercise of Array.isArray(log.exercises) ? log.exercises : []) {
        const name = typeof exercise?.name === "string" ? oneLine(exercise.name) : "";
        if (name) byExercise.set(name, (byExercise.get(name) ?? 0) + 1);
      }
    }
    const top = [...byExercise].sort((a, b) => b[1] - a[1]).slice(0, 6).map(([name, n]) => `${name} ×${n}`);
    const line = `${older.length} sessions from ${String(older[older.length - 1].date)} to ${String(older[0].date)}${top.length ? `; most trained: ${top.join(", ")}` : ""}.`;
    olderLine = fits(line) ? take(line) : null;
  }

  const factLines: string[] = [];
  const summarised: typeof others = [];
  let full = true;
  // Leave room for the "N older facts not shown" line.
  const COUNT_LINE_WORDS = 16;
  const factFits = (text: string) => used + countWords(text) + COUNT_LINE_WORDS <= budget;
  for (const fact of others) {
    const line = `- ${oneLine(fact.content)}${factTail(fact)}`;
    if (full && factFits(line)) {
      factLines.push(take(line));
      continue;
    }
    full = false;
    const compact = `- ${clipWords(oneLine(fact.content), COMPACT_FACT_WORDS)}${factTail(fact)}`;
    if (factFits(compact)) factLines.push(take(compact));
    else summarised.push(fact);
  }
  if (summarised.length > 0) {
    const counts = new Map<string, number>();
    for (const fact of summarised) {
      counts.set(fact.category ?? "other", (counts.get(fact.category ?? "other") ?? 0) + 1);
    }
    const line = `- ${summarised.length} older facts not shown (${[...counts].map(([k, v]) => `${k} ${v}`).join(", ")}).`;
    if (fits(line)) factLines.push(take(line));
  }

  const sections = [
    `Safety and injuries (always included):\n${safetyLines.length ? safetyLines.join("\n") : "- none recorded"}`,
    `What they've told you:\n${factLines.length ? factLines.join("\n") : "- nothing else yet"}`,
    notesLine ? `Your notes:\n${notesLine}` : null,
    `Last session:\n${lastSession ?? "none logged yet"}`,
    `This week (the 7 days to ${input.today}):\n${weekLines.length ? weekLines.join("\n") : "- no other sessions"}`,
    olderLine ? `Earlier training:\n${olderLine}` : null,
  ].filter((section): section is string => section !== null);
  const text = sections.join("\n\n");
  return { text, words: countWords(text), safetyFactCount: safetyLines.length, summarisedFactCount: summarised.length };
}

/** Reads the brief's inputs. Safety facts get their own query so fifty newer preferences can never push an injury out. */
export async function loadMemoryBriefInputs(db: Firestore, userId: string) {
  const facts = db.collection(`${userRoot(userId)}/memoryFacts`);
  const [recent, safety, notes, logs] = await Promise.all([
    facts.orderBy("createdAt", "desc").limit(FACTS_READ).get(),
    facts.where("category", "in", [...SAFETY_CATEGORIES]).limit(SAFETY_READ).get(),
    db.doc(coachNotesPath(userId)).get(),
    db.collection(`${userRoot(userId)}/workoutLogs`).orderBy("date", "desc").limit(LOGS_READ).get(),
  ]);
  const content = notes.exists ? notes.get("content") : null;
  return {
    facts: [...safety.docs, ...recent.docs].map((doc) => doc.data()),
    coachNotes: typeof content === "string" ? content : null,
    logs: logs.docs.map((doc) => doc.data()),
  };
}

export async function buildMemoryBrief(db: Firestore, userId: string, now = new Date(), today?: string): Promise<MemoryBrief> {
  const day = today ?? now.toISOString().slice(0, 10);
  const inputs = await loadMemoryBriefInputs(db, userId);
  const built = buildMemoryBriefText({ today: day, ...inputs });
  return { schema: MEMORY_BRIEF_SCHEMA, userId, builtAt: now.toISOString(), today: day, ...built };
}

/**
 * Rebuilds and stores the brief. Never throws: the brief is advisory and the
 * next trigger heals it. `updateOnly` (used for deletes) never creates the
 * doc: "Reset my data" deletes facts and the brief together, and a delete
 * trigger must not bring the brief back. update() fails atomically if the
 * reset got there first.
 */
export async function rebuildMemoryBrief(
  db: Firestore,
  userId: string,
  reason: string,
  now = new Date(),
  options: { updateOnly?: boolean } = {},
): Promise<MemoryBrief | null> {
  try {
    const brief = await buildMemoryBrief(db, userId, now);
    const ref = db.doc(memoryBriefPath(userId));
    if (options.updateOnly) {
      const updated = await ref.update(brief).then(() => true, (error: { code?: number }) => {
        if (error?.code === 5) return false; // NOT_FOUND: reset already removed it.
        throw error;
      });
      return updated ? brief : null;
    }
    await ref.set(brief);
    return brief;
  } catch (error) {
    safeLogger.warn("Memory brief rebuild failed", {
      event: "memory_brief_rebuild_failed",
      userId,
      trigger: reason,
      errorDetail: error instanceof Error ? error.message.slice(0, 180) : "unknown_error",
    });
    return null;
  }
}

/** Live voice has no end-of-conversation hook: rebuild after a spoken turn when the brief is older than this. */
export const LIVE_REBUILD_AFTER_MINUTES = 10;

export async function rebuildMemoryBriefIfOlder(db: Firestore, userId: string, minutes: number, reason: string, now = new Date()) {
  const current = parseMemoryBrief((await db.doc(memoryBriefPath(userId)).get().catch(() => null))?.data());
  if (current && now.getTime() - Date.parse(current.builtAt) < minutes * 60_000) return null;
  return rebuildMemoryBrief(db, userId, reason, now);
}

export function parseMemoryBrief(data: DocumentData | undefined | null): MemoryBrief | null {
  if (!data || data.schema !== MEMORY_BRIEF_SCHEMA) return null;
  if (typeof data.text !== "string" || typeof data.builtAt !== "string" || Number.isNaN(Date.parse(data.builtAt))) return null;
  return data as MemoryBrief;
}

/** "built 2026-11-03, 2 days ago" — the model is always told how old the brief is. */
export function memoryBriefAge(builtAt: string, now = new Date()): string {
  const ms = now.getTime() - Date.parse(builtAt);
  const minutes = Math.max(0, Math.round(ms / 60_000));
  const ago =
    minutes < 2 ? "just now"
      : minutes < 90 ? `${minutes} minutes ago`
        : minutes < 48 * 60 ? `${Math.round(minutes / 60)} hours ago`
          : `${Math.round(minutes / 1440)} days ago`;
  return `built ${builtAt.slice(0, 16).replace("T", " ")} UTC, ${ago}`;
}
