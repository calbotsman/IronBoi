# MYO User Lexicon + Classifier Layers

Status: **design note, not built.** No code changes proposed yet — this exists
to get the shape agreed before anything is implemented.

Scope note: this covers how the coach **understands the user's words**. How the
coach **speaks back** (tone, push style, detail level) is already specced in
[myo-coach-voice-and-identity.md](myo-coach-voice-and-identity.md) via
`coachPreferences/current`. They feel like one idea and are deliberately kept
apart — see "Two features, not one" below.

---

## The incident that motivated this

2026-07-27, live staging. A user says:

> "I fell off and haven't trained in about a month. Can you ease me back into my
> normal routine over the next few weeks?"

The model did everything right — it authored a clean `60 → 80 → 100%` re-entry
ramp. The server then refused it, because `classifyPlanAdjustment` read the
message as a **back injury** and the safety gate correctly blocks ramps for
pain.

Why: `"back"` is both a body part and the most natural word for *returning*. The
guard that separates the two senses stripped return idioms first, but required
the verb to sit adjacent to the word — `get back`, `ease back`. English inserts
an object pronoun constantly: **"ease *me* back."** So the strip missed, `back`
survived, and the message classified as an injury.

350 unit tests were green. They only covered the adjacent forms, because the
same person wrote the regex and the tests, and shared the same blind spot.

The narrow fix shipped in #19. The structural lesson did not.

---

## The structural problem: two jobs, one classifier

`classifyPlanAdjustment` is doing two different jobs with one keyword list, and
only one of them should ever have been keyword matching.

| | Safety floor | Routing |
|---|---|---|
| **Example** | `hasSevereMarkers` — numbness, radiating pain, recent trauma | "which category is this? which tool applies?" |
| **Question it answers** | "must a human look at this?" | "what did the user probably mean?" |
| **Failure that matters** | false NEGATIVE — a red flag slips through | false POSITIVE — a benign message gets locked, or the wrong tool fires |
| **Must be deterministic?** | **Yes.** Not model-overridable by design; no attestation can clear text that trips it | No |
| **Should personalize?** | **Never** | Yes — this is where a lexicon helps |
| **Right implementation** | keyword/regex, fail-closed, user-independent | semantic; the model already sees the full turn |

The July bug was a **routing** failure wearing the safety layer's clothes. The
severe screen behaved correctly throughout — it never fired, because there were
no severe markers. What broke was the coarse category guess feeding a gate that
assumed the guess was trustworthy.

**Direction:** keep the safety floor exactly as it is — deterministic,
absolute, user-independent. Let routing become semantic, and let the lexicon
inform routing only.

---

## The one-way rule

The invariant that makes a personalized lexicon safe:

> **A learned lexicon may only ever ADD signal, never subtract it.**

If the system notices a user says *"my back is killing me"* casually after leg
day and starts discounting that phrase, it has quietly lowered that user's
safety floor — based on a pattern, for the one person it was learned from, with
no one reviewing the change.

Personalization may **escalate**: "this user says 'tight' when they mean
something a clinician should see." It may never **de-escalate** below the
deterministic floor.

This is the same shape the codebase already uses for pain triage: the severe
screen is absolute, and a triage attestation can only clear a proposal when the
screen is *already* clean. The lexicon should inherit that discipline rather
than invent a new one.

---

## Two features, not one

They share a name ("understand the user better") and nothing else.

### A. Voice adaptation — how the coach talks
Already specced in the voice plan. Enum-based preferences, zero safety surface,
immediately noticeable, cheap. **Ship independently.**

### B. Symptom + effort vocabulary — how the user describes their body
Real value: people describe exertion and discomfort wildly differently —
*sore / wrecked / cooked / smoked / tight / dead*. A coach that knows which of
those means "I need a deload" versus "that was a good session" is materially
better.

But it touches routing, which touches the safety gate. Needs the one-way rule,
and probably a review path before any learned term influences classification.

**Bundling these means the fun half waits on the careful half.** Keep them
separate.

---

## Where it would hook in

Nothing here requires new infrastructure — the pieces exist:

- **`CoachMemoryFact`** (`functions/src/contracts/coach-agent.ts`) already has a
  category enum, a `source` enum, `confidence`, and a `proposed → confirmed`
  state machine with user inspect/edit/delete rights. A `communication_style`
  or `lexicon` category slots in beside `preference` and `safety_note`.
- The existing **fact-confirmation queue** is the natural review path: a learned
  vocabulary mapping arrives as `proposed`, and only a `confirmed` fact is
  allowed to influence routing. That reuses a flow the user already understands
  rather than adding a second, invisible one.
- **`CoachContextBundle`** already carries facts into the prompt.

---

## Open questions

1. **Cold start.** Day one there is no profile. The system must be good without
   one and better with it — never dependent on it.
2. **Who confirms a lexicon fact?** Auto-confirm is how the safety floor erodes
   quietly. Explicit confirmation may be too much friction for something this
   small. Unresolved.
3. **Is a lexicon fact evidence, or a hint?** If the coach believes "tight"
   means injury for this user, does that *classify*, or does it *prompt a
   question*? Prompting is safer and probably better coaching.
4. **Privacy.** A linguistic profile is more sensitive than it sounds. It falls
   under the same inspect/edit/delete rights as every other memory fact, and
   should never leave the user's own document.
5. **Does routing become a model call?** That's the deeper change implied here,
   with latency and cost consequences, and it needs its own decision.

---

## Testing lesson worth keeping

The regex and its tests were written by the same author in the same sitting,
and shared one blind spot. What caught it was the **live E2E**, not the unit
suite.

For any classifier over natural language:

- test the **pronoun-inserted** forms ("ease *me* back"), not just the canonical
  ones — that is how people actually talk
- generate the corpus from real user turns where possible, not from imagination
- the asymmetry is the design input: a false positive costs some unnecessary
  triage questions; a false negative puts an injured user's own aggravating
  movement back on the bar. Anything ambiguous stays flagged.
