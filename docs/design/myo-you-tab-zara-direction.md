# DESIGN DOCTRINE: MYO "You" Tab

- **ID:** `myo-you-tab-zara-direction-v1`
- **Author:** Zara (Art Director)
- **Date:** 2026-06-07
- **Status:** `DIRECTION_LOCKED`

---

## 1. The Metaphor: The Training Dossier

The "Settings" screen is where you configure a tool. The "You" tab is where you brief your coach. The metaphor is not a form, a profile, or a settings panel.

**The metaphor is a Training Dossier.**

A dossier is a living document. It's curated. It contains the essential intelligence for a mission. It's personal, respected, and frequently referenced. It's what a dedicated coach would keep in a manila folder with your name on it. It's the opposite of a database record.

This metaphor directly serves the strategy: "remembered, not categorized." A dossier remembers. A form categorizes.

Every decision below flows from this metaphor. If a proposed feature doesn't feel like it belongs in a coach's private, focused dossier on their most important client, we kill it.

## 2. Information Architecture: From Interrogation to Conversation

The current nine sections are an interrogation. A dossier tells a story. We will re-sequence and re-frame the existing data points into a clear narrative.

**KILL** the flat list of nine sections.
**REVISE** to a structure with four thematic groups, presented as a single, scrolling document:

1.  **The Baseline:** *Who you are today.*
    -   `About You` (Age, Height, etc.)
    -   `Experience Level`
    -   `Injuries & Limitations`
    This is the "medical history" portion of the dossier. It establishes facts.

2.  **The Ambition:** *Where you want to go.*
    -   `Goals`
    This is the most important section. It's the "mission objective." It gets visual prominence.

3.  **The Protocol:** *How we'll work together.*
    -   `Schedule`
    -   `Equipment`
    -   `Coaching Style`
    This is the "rules of engagement" section. It sets expectations for the AI.

4.  **The Boundaries:** *What we'll avoid.*
    -   `Dietary Notes`
    -   `Disliked Exercises`
    These are footnotes and addenda. Important, but secondary to the main narrative. Presented as such.

This structure turns a checklist into a conversation. It respects the user's journey.

## 3. The Hero Region: The Dossier Summary

The first thing the user sees is not a form field. It is proof of being seen.

When the "You" tab is opened, the hero region is a non-editable **Dossier Summary** block. It looks like a typewritten index card or a stamped label affixed to the top of the dossier. It synthesizes the user's core identity back to them.

**Content:**
> **[User Name]**
> **Focus:** Building Muscle, Mobility
> **Experience:** Intermediate
> **Protocol:** 4 sessions/week, Direct Coaching

This is dynamic. It pulls from the user's own inputs. It is the first and most powerful expression of "we remember you." It makes the entire page feel like a review of a known quantity, not a creation of a new one. Visually, it should be inset, perhaps with a subtle border or a slightly different background tint, distinct from the editable content below.

## 4. Concrete Visual Moves

The default SwiftUI `Form` is dead. We build a custom view that embodies the Dossier.

**1. Move: Typographic System as Annotation**
The visual identity will be carried by typography, not chrome.
-   **Headings & Labels:** Use a characterful, slightly condensed monospace font (e.g., **IBM Plex Mono** or **Atlas Typewriter**). This evokes the "typewritten report" feel of the dossier. It is precise, legible, and devoid of SaaS gloss.
-   **Body & Input Text:** Use a clean, humanist sans-serif (e.g., **General Sans**). This is for readability and warmth. The contrast between the mechanical labels and the humane inputs is the core typographic tension.
-   **Color:** `#1C1C1A` (a near-black) for all type on the `#FCF4E8` cream paper. No gray-for-secondary-text. We create emphasis through weight and font choice, not by reducing contrast.

**2. Move: Interaction as Ink**
We banish the generic toggle. Interactions feel physical, like a coach marking up a document.
-   **Selection:** For multi-select lists like `Goals` or `Schedule`, tapping an option doesn't flip a switch. It changes the text style of the item itself. Unselected items are plain `General Sans`. Selected items become **bold**, and a single, sharp accent color is applied.
-   **Accent Color:** A single accent: a deep, desaturated red like a grading pen (`#B94A48`). This is the "coach's ink." It's used *only* for indicating selection and for the primary "Update" button, if one is needed. It is a tool for focus, not decoration.
-   **Free-Tag Fields:** These should look like underlined blank spaces in a printed form. When the user taps, the line becomes the active input field. `[Tap to list equipment]_______`

**3. Move: Illustration as Marginalia**
The existing kettlebell illustrations are too loud for this context. We demote them.
-   **Role:** Illustrations will be used as small, pencil-sketch-style icons or "marginalia." A tiny, rough sketch of a calendar next to "Schedule," a small dumbbell next to "Equipment." They should feel like a quick note jotted in the margin, not a primary visual element.
-   **Execution:** These must be redrawn or filtered to look like single-color line art sketches. They should have a slightly imperfect, hand-drawn quality. They provide personality and visual landmarks without shouting.

## 5. Anti-Patterns to Refuse

Our goal is to create a space of quiet confidence. We will explicitly reject patterns that create anxiety or feel transactional.

1.  **The Gamified Profile.** We will not use progress bars for "profile completion." We will not award badges for filling out sections. The motivation to complete the dossier is intrinsic: a better-briefed coach provides a better workout. The UI must respect this.
2.  **The Data-Entry Dashboard.** We will not use a grid of generic icons to navigate to each section. This is the hallmark of MyFitnessPal and every other calorie tracker. It turns a person into a collection of metrics. The interface is the single, scrolling dossier. Navigation is scrolling.

## 6. Verdicts

-   **(a) Using SwiftUI `Form`:** **KILL.** It is the source of the conceptual error. It enforces a visual and interactive language that is antithetical to the "Dossier" metaphor. We must build a custom view.
-   **(b) Section count of 9:** **REVISE.** The nine data points are kept, but their presentation as a flat list is killed. Re-group into the four-part narrative structure defined in section 2.
-   **(c) Toggle-list pattern for Goals:** **KILL.** Toggles are for machine settings. Goals are human ambitions. The interaction must reflect this. Use the "Interaction as Ink" pattern.
-   **(d) Save-button-in-navbar:** **REVISE.** A dossier is a living document. An explicit save is friction. The best experience is no save button; changes are saved on edit. This reinforces the "living" nature of the document. If technically unfeasible for v1, the button moves to the bottom of the scroll, styled as a primary action, and is labeled "Update Dossier," not "Save."

This is the direction. It is a complete system. Ship it.
