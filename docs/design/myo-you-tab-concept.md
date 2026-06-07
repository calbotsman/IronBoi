# MYO — "You" Tab Concept Direction

*From: Iris*
*Date: 2026-06-06*
*Status: concept direction for layout-systems + frontend-engineer*

---

## 1. The feel: a coach's notebook, opened to your page

Settings-screen energy is wrong because settings screens are *the user configuring the app*. The You tab is the opposite — it's *the app showing the user how it sees them*. That asymmetry is the whole pitch.

The right metaphor is **a coach's notebook, opened to your page.** Not a form. Not a profile card. A page MYO has been keeping on you — written in MYO's voice, with you allowed to amend it.

Concretely: the tab opens with a short, plain-language paragraph that reads you back to yourself. *"Josh, 37. Intermediate. Three days a week, 45 minutes. We're building toward a 2x-bodyweight squat, working around the left knee."* That's the hero. Everything below is the underlying fields, but reframed as *"things MYO is keeping track of for you"* — not *"forms you must fill out."*

This lands the wedge's literal sentence — **"a coach that explains the why, remembers them, and never makes them feel stupid"** — on the one screen in the app where it can actually be felt. Workout shows you the plan. Coach shows you the conversation. **You shows you the relationship.**

---

## 2. The one thing the Form doesn't communicate

That you are *known*, not *categorized*.

A Form says: "fill these in so the algorithm has inputs." A notebook says: "here's what I remember about you — correct me if I'm wrong." Same data, opposite contract. The Form treats the user as a row in a database. The notebook treats them as a person someone has been paying attention to.

This is also where the **memory + cite-or-refuse** architecture finally becomes visible to the user. Today it's invisible plumbing. Surface it: every section should subtly carry *"MYO remembers this"* as an emotional throughline — not a literal label, but the implicit promise of every layout choice.

---

## 3. Visual cues

**Yes, own the visual system. No, don't invent a new one.** `Color.myoIllustrationPaper` is the brand's calmest asset and the You tab is the calmest surface — they belong together. The Form fights the cream because grouped iOS forms force a stack of system-gray cards on top of it. Strip the Form chrome, let the paper breathe edge-to-edge.

**Typography as voice.** The hero paragraph reads in body-weight serif-ish system type *(or whatever's already approved — keep it consistent with Workout's `largeTitle.bold` rhythm)*. Section labels stay quiet — uppercase caption-weight, like the `DetailSection` headers in Workout. The labels are not the point. The values are. Invert the usual settings-screen hierarchy: **fields read as sentences, labels as marginalia.**

**Kettlebell illustrations: use sparingly, not decoratively.** One illustration anchors the top of the page — a single static frame, not a sequence. Maybe a figure mid-rest, mid-thought. Not a logo. Not a mascot. A *companion mark*. The sequences belong in Workout where movement is the subject. Here, stillness is the subject.

**Yellow as accent, not chrome.** Yellow already means "MYO is acting on you" — start button, applied plan, accepted proposal. On the You tab, yellow gets used once: on the single inline edit affordance the user is most likely to touch. Everything else is paper, ink, and the existing 6% black hairline.

**Motion: a held breath.** When a value updates, it should feel like a pen mark drying, not a database write. A 200ms tonal fade on the row, no bounce, no chime. The screen should never feel busy.

---

## 4. What gets cut from the top, what gets celebrated

The Form leads with **age, sex, height, weight.** That's MyFitnessPal's opening move and it teaches the user that this app is about measuring them. Cut it from the top.

Lead with what makes the relationship real: **the goal, the constraint, and the why.** Specifically, the hero paragraph plus the one-line *"What we're working on"* — the goal-notes field where Josh wrote "squat 2x bodyweight." That sentence is the most personal thing in the data model, and it's currently buried at the bottom of the Goals section behind seven toggles.

Promote: **the goal note, the injuries, the disliked exercises.** These are the fields that *only matter because MYO remembers them.* They are the wedge made tangible.

Demote: **age, height, weight, sex/gender.** Fold them into a collapsed "Body basics" group below the fold. They matter, they get used, they don't lead.

Cut entirely from v1: **dietary constraints.** Per the wedge doc — nutrition is Welling's lane, "a distraction unless it's a deliberate later expansion." Keep the field in the data model, drop it from the surface until nutrition is in scope.

---

## 5. Anti-patterns to refuse

1. **Grouped-form cards on top of cream.** The default `Form { Section { } }` produces a stack of rounded white-ish cards floating on the paper. That's iOS Settings energy and it kills the warmth instantly. Build with plain `ScrollView` + custom rows on `myoIllustrationPaper`, same vocabulary as Workout.

2. **Body metrics as the hero.** Lead with weight-and-height and the screen reads as a tracker, not a coach. MyFitnessPal opens with a weigh-in. We don't. The body lives below the fold.

3. **Toggle walls and pickers everywhere.** Six toggles for goals, a picker for tone, a picker for methodology, steppers for days and minutes — read in sequence, it's a configuration wizard. Refuse the pattern. Render multi-select goals as **selectable chips inline in a sentence** *("I want to: [get stronger] [build muscle] [+ add]")*. Render schedule as **one editable sentence** *("3 days a week, about 45 minutes, usually in the [morning]")*. Make the data read as language.

---

## TL;DR for the brief

Open the page like MYO is reading you back to yourself. Paper background, no form chrome, one kettlebell illustration as a quiet companion, yellow used once, sentences instead of fields. Lead with what's personal — the goal note, the why, the constraint. Demote the body metrics. Cut dietary. The whole tab should feel like the line in the wedge doc made literal: *"It remembers you. It explains everything. It never makes you feel stupid."*
