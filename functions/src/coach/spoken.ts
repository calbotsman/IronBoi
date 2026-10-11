/**
 * What the coach's voice actually reads out. The full reply stays on screen
 * (and in history); the spoken version is the first sentence or two, so a
 * reply the model wrote as a paragraph doesn't get read as one. The prompt
 * asks for short spoken replies already; this is the hard cap for when the
 * model ignores it.
 */

const MAX_SPOKEN_CHARS = 300;

/** Markdown the model sometimes writes, which has no spoken form. */
export function plainSpeech(text: string): string {
  let out = text;
  for (const token of ["**", "__", "`", "#"]) out = out.split(token).join("");
  out = out.replace(/^\s*[-*•]\s+/gm, "");
  out = out.replace(/^\s*\d+\.\s+/gm, "");
  out = out.replace(/\n\n+/g, " ");
  out = out.replace(/\n/g, ". ");
  out = out.replace(/\.\s*\./g, ".");
  return out.replace(/\s+/g, " ").trim();
}

function sentences(text: string): string[] {
  // Split after . ! ? followed by whitespace; keeps "5x8 @155 lb." intact.
  return text
    .split(/(?<=[.!?])\s+(?=[^a-z])/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

/**
 * The first sentences that fit in `maxChars`. Always at least one sentence
 * (cut at a word if it alone is too long). If the reply ends with a question
 * that didn't fit, it's kept too — the question is what the user needs to
 * answer — as long as the total stays under 1.5× the cap.
 */
export function spokenSummary(content: string, maxChars = MAX_SPOKEN_CHARS): string {
  const plain = plainSpeech(content);
  if (plain.length <= maxChars) return plain;
  const parts = sentences(plain);
  if (parts.length === 0) return plain.slice(0, maxChars);

  let out = "";
  for (const sentence of parts) {
    const next = out ? `${out} ${sentence}` : sentence;
    if (next.length > maxChars) break;
    out = next;
  }
  if (!out) {
    const cut = parts[0].slice(0, maxChars);
    const atWord = cut.lastIndexOf(" ");
    out = (atWord > maxChars * 0.6 ? cut.slice(0, atWord) : cut).replace(/[,;:\s]+$/, "") + ".";
  }

  const last = parts[parts.length - 1];
  if (last.endsWith("?") && !out.endsWith(last) && `${out} ${last}`.length <= maxChars * 1.5) {
    out = `${out} ${last}`;
  }
  return out;
}
