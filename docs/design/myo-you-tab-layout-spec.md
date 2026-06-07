# MYO Coach — "You" Tab Layout Spec
**Version:** 1.0
**Date:** 2026-06-06
**Surface:** iOS, native SwiftUI

---

## 1. Information Architecture

### Collapse from 9 to 5 visible groups

The current nine sections are functionally correct but architecturally flat. A coach onboarding a real athlete would front-load context that changes the workout immediately, then ask about preferences and constraints second. The alphabetical-ish order does the opposite.

**Proposed top-level groups (visible on scroll):**

| # | Group label | Sections inside | Why grouped |
|---|---|---|---|
| 1 | Who you are | About you (age, sex, height, weight) + Experience | These two define the athlete's starting envelope together. Experience without biometrics is half the picture. |
| 2 | What you're after | Goals | High-signal and motivating — deserves its own block. Putting goals second keeps the screen from opening on anthropometrics. |
| 3 | Your setup | Schedule + Equipment / gear | Both answer "what's actually possible." Coach needs this before generating any plan. |
| 4 | Your coach | Coaching style (tone + methodology) | Personality/preference layer. Lower stakes than the three above, but worth its own header so users don't miss it. |
| 5 | Limits + avoids | Injuries / limitations + Dietary + Disliked exercises | All three are negative-space inputs. Grouped under one header with short dividers between sub-sections. |

Groups 1–3 are required for "good first save." Groups 4–5 are optional for first save but should carry a nudge once groups 1–3 are filled. There is no separate completion gate; the profile completeness indicator in the header (see Section 2) does that work passively.

### Required vs optional vs deferrable

**Required (gating "good first save"):**
- Age
- Training experience
- Days per week
- Session length

**Strongly encouraged (surface incomplete state if missing after first save):**
- Goals (at least one)
- Equipment (at least one item, or explicit "None / bodyweight")
- Injuries (explicit confirmation that the list is intentionally empty — one-tap "None right now" button)

**Optional / deferrable:**
- Height, weight
- Sex / gender
- Preferred workout time
- Coaching tone + methodology
- Dietary, disliked exercises

### Suggested order

1. Who you are (age first, then experience, then optional biometrics)
2. What you're after (goals)
3. Your setup (schedule, then equipment)
4. Your coach (tone, methodology)
5. Limits + avoids (injuries, dietary, disliked exercises)

---

## 2. Page Structure

### Hero / header block

No generic avatar. The header block carries three things:

1. **User's preferred address name** (from `coachPreferences.preferredAddressName`, fallback to first name from Apple ID) — rendered as `largeTitle.bold()`, left-aligned, 28pt.
2. **A single completion pill** — shows "Profile complete" (black fill, white text) or "X of 4 required fields" (yellow fill, black text). This replaces the generic `Form` title "You."
3. **A one-line coach framing** — rendered as `subheadline`, secondary color. Reads: "MYO uses this to write your plan. Keep it honest." This is static copy, not dynamic. It sets stakes without being chatty.

The header block sits above the scroll area and does not scroll away. It occupies a fixed region of approximately 88pt height (name 34pt + pill 28pt + note 20pt + 6pt gap), flush left with 16pt horizontal inset.

Background: `Color.myoIllustrationPaper` — match CoachView, not the system grouped-form gray.

### Section header pattern

- **Label:** `.caption.weight(.bold)`, `.textCase(.uppercase)`, secondary foreground color
- **Spacing above:** 32pt from the bottom of the previous section's last row (xl token)
- **Spacing below:** 8pt between header label and first row (xs*2 = 8pt)
- No decorative divider above section headers. Whitespace alone signals the break.

This is the same `DetailSection` header pattern already established in WorkoutView — reuse it for consistency.

### Card vs grouped-list

Use cards with the established card chrome, not SwiftUI's default grouped form inset treatment. The grouped form gives a system gray background that breaks the paper palette. The card pattern from `PlannedWorkoutDayCard` is the right template:

```
.background(Color.myoIllustrationPaper)
.overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.black.opacity(0.06), lineWidth: 1) }
.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
```

Each of the five groups becomes one card. Within a card, sections are separated by a hairline divider (1pt, `Color.black.opacity(0.08)`), not by system section separators. This keeps the paper surface intact and the hierarchy readable.

The outermost container is a `ScrollView` + `LazyVStack(spacing: 16)`, not `Form`. This is the correct structural call — `Form` forces system styling that cannot be overridden cleanly without fighting the framework.

### Bottom action region

Sticky save button, not toolbar. The current navbar "Save" button is too easy to miss and does not accommodate the in-flight/error states well. Replace with:

- A `safeAreaInset(edge: .bottom)` region, always visible.
- Contents: a full-width `.borderedProminent` button, `.tint(.black)`, `.foregroundStyle(.white)`, `.controlSize(.large)`.
- Label states: "Save" (idle), "Saving..." + `ProgressView` (in-flight), "Saved" (success, 1.5s then resets).
- The button is disabled and visually dimmed when `draft == appModel.profile`.
- An edited-but-unsaved dot indicator appears in the completion pill (see Section 5).

The safeAreaInset region has a `.bar` background material to match the composer in CoachView. Height: 64pt (button 50pt + 14pt vertical padding split).

---

## 3. Spacing + Typography Scale

### Spacing tokens

| Token | Value | Usage |
|---|---|---|
| xs | 4pt | Icon-to-label gap, tight chip padding |
| sm | 8pt | Row internal padding, section header to first row |
| md | 16pt | Card horizontal inset, between rows within a card |
| lg | 24pt | Between sub-sections within a card (above hairline divider) |
| xl | 32pt | Between cards in the scroll stack |
| 2xl | 48pt | Below header block before first card |

The `LazyVStack(spacing:)` value is `xl` (32pt). Card internal `VStack(spacing:)` is `md` (16pt). Sub-section separation within "Limits + avoids" uses `lg` (24pt) above the divider.

### Type scale

| Role | SwiftUI font | Size | Weight |
|---|---|---|---|
| Screen title (name) | `.largeTitle` | ~34pt | Bold |
| Completion pill | `.footnote` | ~13pt | Semibold |
| Coach note | `.subheadline` | ~15pt | Regular |
| Section header | `.caption` + `.textCase(.uppercase)` | ~12pt | Bold |
| Row label | `.body` | ~17pt | Regular |
| Row value / secondary | `.body` | ~17pt | Regular, `.secondary` |
| Tag chip | `.subheadline` | ~15pt | Semibold |
| Footer / hint | `.caption` | ~12pt | Regular, `.secondary` |

All sizes use Dynamic Type — no hardcoded `size:` overrides. The `minimumScaleFactor` pattern from the exercise detail screen (0.72) applies only to the hero name if it overflows.

### Touch targets

All tappable rows: minimum 44pt height enforced via `.frame(minHeight: 44)` on the row HStack. Stepper rows already meet this through default `Stepper` sizing. Tag delete buttons: `Image(systemName: "xmark.circle.fill")` wrapped in a 44x44 tap region using `.contentShape(Rectangle())`.

---

## 4. Section-Specific Layouts

### Group 1: Who you are

**About you (age, sex/gender, height, weight)**

- Age: `HStack` — label left, numeric `TextField` right, `.frame(maxWidth: 64)`. Age is required; show a yellow border `RoundedRectangle` overlay if empty on save attempt.
- Sex / gender: `Picker` using `.menu` style. Self-described expansion stays inline with `withAnimation`.
- Height, weight: same pattern as age. Marked "(optional)" in the placeholder. No validation gate.

Empty state: age field shows placeholder "e.g. 32" — warmer than "years." Filled state: value right-aligned in `.monospacedDigit()` for visual stability.

Edit affordance: fully inline. No sheet needed for scalar fields.

Visual move: no illustration here. The section is data-heavy; keep it clean.

**Experience**

Immediately below "About you" within the same card, separated by a `md`-padded hairline.

- Control: segmented or inline picker. Use `.pickerStyle(.segmented)` if 4 or fewer options; fall back to `.menu` if options expand. Segmented looks intentional here — it communicates mutual exclusivity without a dropdown.
- Empty state: no option selected, pill border highlighted yellow.

### Group 2: What you're after (Goals)

- Control: chip multi-select using `FlowLayout` — the implementation already exists in WorkoutView. Each goal is a capsule chip: selected = yellow fill + black text; unselected = `Color.black.opacity(0.06)` fill + primary text.
- Remove the `Toggle` list. Toggles imply binary on/off switches; chips communicate selection from a menu more naturally for goals.
- Goal notes `TextField` stays below the chips, full-width, `axis: .vertical`, `.lineLimit(2...4)`. Placeholder: "Any specific target? e.g. squat 2× bodyweight"
- Empty state: all chips unselected, a subtle "Pick at least one" `.caption` note below in yellow.
- Filled state: selected chips visually pop; note disappears.

### Group 3: Your setup

**Schedule**

- `Stepper` rows stay. Both already have correct label+value `HStack` pattern.
- Add monospaced digit formatting to the live value (`Text("\(value)").monospacedDigit()`) so the number doesn't shift layout when it increments.
- Preferred workout time: `.pickerStyle(.segmented)` if 4 or fewer values, otherwise `.menu`.

**Equipment / gear**

- Tag chips, flow-wrapped, using same `FlowLayout`. Chips are removable (tap chip to enter "edit mode" showing ×, or long-press).
- Add row below chips: `HStack` with a `RoundedRectangle`-bordered `TextField` + a trailing "Add" `Button` — current pattern is fine, but style the text field with `.textFieldStyle(.roundedBorder)` and a `.controlSize(.small)` "Add" button to reduce visual weight.
- Empty state: show a "None / bodyweight only" chip pre-rendered but not selected. Tapping it adds "Bodyweight" to the list and communicates intent to the coach explicitly.
- Footer: "What you have access to. MYO picks exercises you can actually do." — keep current copy.

### Group 4: Your coach

- Two pickers: Tone and Methodology.
- Use `.pickerStyle(.menu)` for both — these are low-frequency settings, a dropdown is fine.
- Lay them as standard `HStack` label + value rows (same as current), but add a one-line description below each picker value in `.caption` secondary color. E.g., for tone "Balanced": "Practical answers with a light hand." This makes the setting legible without opening a sheet.
- No empty state issue — both have sensible defaults.

### Group 5: Limits + avoids

All three sub-sections (injuries, dietary, disliked exercises) live in one card. They are separated by labeled hairline dividers — not section headers — to avoid header nesting that inflates vertical height.

**Injuries / limitations**

- Tag chips (flow-wrapped), removable.
- "None right now" is an explicit first chip — tapping it adds a `none` sentinel and collapses the add-field. This prevents the common UX ambiguity of "empty = forgot to fill in vs. empty = no injuries."
- Add field: same `TextField` + "Add" button pattern.
- Footer: current copy is correct — "MYO avoids exercises that aggravate these."

**Dietary**

- Same tag chip + add field pattern.
- No sentinel chip needed here — empty dietary is genuinely optional and unambiguous.

**Disliked exercises**

- Same pattern.
- Footer: "MYO will try to avoid these unless you opt in." — keep current copy.

---

## 5. Motion + State

### First load

No dramatic entrance. The scroll content fades in at 0→1 opacity over 200ms (`easeOut`) after the view appears. No stagger — staggered section entrances feel like performance anxiety for a settings screen.

### Edited-but-unsaved indicator

The completion pill gains a filled circle dot (SF Symbol `circle.fill`, 6pt, yellow) at its trailing edge when `hasLocalEdits == true`. This is the single indicator. No toast, no navigation bar badge. The dot disappears on successful save.

Implementation: a `ZStack` overlay on the pill view, conditional on `hasLocalEdits`.

### Save success / error states

**Success:** the save button label transitions to "Saved" with a `checkmark.circle.fill` icon, `.tint(.green)`. After 1.5 seconds, it snaps back to "Save" in black. No modal, no toast. The unsaved dot disappears simultaneously.

Use `withAnimation(.snappy)` for all button state transitions.

**Error:** the save button label becomes "Failed — tap to retry" in red tint. The `appModel.errorMessage` alert fires as today, but additionally the button reflects the error state. Reset to "Save" on next tap.

### Network in-flight

- Save button shows `ProgressView()` (current behavior — correct).
- The entire scroll content is not blocked. Users can read while saving.
- Stepper and picker inputs are not `.disabled` during save — lock only the save button itself.

---

## 6. SwiftUI Mapping

| Design element | SwiftUI API | Custom? |
|---|---|---|
| Outer scroll container | `ScrollView` + `LazyVStack(spacing: 32)` | No |
| Card chrome | `.background` + `.overlay(RoundedRectangle)` + `.clipShape` | No — identical to WorkoutView |
| Header block | `VStack` in `safeAreaInset(edge: .top, alignment: .leading)` | No |
| Completion pill | `HStack` + `Capsule()` fill | No |
| Section header label | `.caption.weight(.bold).textCase(.uppercase)` | No |
| Goal chips / tag chips | `FlowLayout` (already exists in WorkoutView — move to shared) | Shared existing |
| Chip selection | `ForEach` + `Button` + conditional `.background` | No |
| Stepper rows | `Stepper` | No |
| Pickers | `.pickerStyle(.menu)` or `.pickerStyle(.segmented)` | No |
| Add-tag row | `HStack` + `TextField(.roundedBorder)` + `Button` | No |
| Hairline divider | `Divider()` or `Rectangle().frame(height: 1)` | No |
| Sticky save bar | `.safeAreaInset(edge: .bottom)` | No |
| Unsaved dot indicator | `ZStack` overlay + `Circle().fill(.yellow)` | No |
| "None right now" sentinel | Manual sentinel chip — toggle adds/removes a `"none"` string | Minimal logic |

**Flag: one custom view required.** The chip multi-select for Goals (and the removable tag chips for the free-text sections) both need `FlowLayout`. This already exists in `WorkoutView`. It must be extracted to a shared file (e.g., `Shared/FlowLayout.swift`) rather than duplicated. That extraction is the only structural change the spec requires beyond the view rewrite.

No custom drawing, no `Canvas`, no `UIViewRepresentable` needed for any element in this spec.

---

## 7. What to Defer

**1. Profile photo / avatar.** A monogram or photo in the header would add visual warmth. But it requires photo picker permission handling, storage, and a CDN-backed URL — none of which exist in the data model today. The name + completion pill is sufficient for v1.

**2. Section-level completion indicators.** Showing a green checkmark or yellow dot per-section (like a form wizard) would help users understand what's filled. This requires computing per-section completeness state, which adds view-model complexity. The single header-level pill is the right scope for v1.

**3. Inline coach response on save.** After saving, MYO could push a short "Got it — I'll adjust your next plan" acknowledgment in the coach thread. This would make the You tab feel reactive rather than passive. However, it requires a backend trigger on profile write, which is a non-trivial addition. Defer until after the profile save → plan regeneration loop is stable.
