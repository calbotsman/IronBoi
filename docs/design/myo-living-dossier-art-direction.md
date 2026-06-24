---
title: MYO — "The Living Dossier" Art Direction (Style System v2)
date: 2026-06-22
status: proposed — studio-authored, pending Tosh sign-off on 3 flagged decisions
authors: Zara (art direction), Pell (material), Felix (architecture), Declan (typographic voice)
supersedes: the thin MyoTheme v1 token bag (6 flat colors, 1 font role)
---

# The Living Dossier — Art Direction

## 0. The big idea (Zara)

**The Living Dossier.** MYO is a coach's private notebook on you — cream paper, ink,
and the red pen of correction — but *alive with your progress*. Every surface should feel
like Coach is actively working on you, not displaying a database. The screenshot moment —
the thing one user shows another — is the **rubber-stamp milestone**: brick ink on cream
next to a handwritten progress note. Warm, exact, unmistakably *yours*.

This replaces "cream paper settings screen." The difference is **authored vs. templated**:
hand-quality marks, a real typographic voice, and paper that has material.

---

## 1. Color as a system (not swatches)

Views never touch a hex again. They ask for a **role**. Primitives are private.

### Primitives (private)
| Name | Hex |
|---|---|
| cream | `#FCF4E8` |
| creamElevated | `#F7ECDA` (one step warmer/darker for raised surfaces) |
| ink | `#1A1410` |
| ochre | `#C4892A` |
| ochreLight | `#E8B858` |
| brick | `#A04030` |
| brickLight | `#C06040` |
| sage | `#5A8C6E` |

### Semantic roles (public — what views use)
| Role | Maps to | Meaning |
|---|---|---|
| `surface.base` | cream | the paper, default |
| `surface.elevated` | creamElevated | a sheet sitting on the paper (cards over the base) |
| `surface.pressed` | ochre @ 10% | momentary press feedback |
| `surface.selected` | ochreLight | a chosen chip/row — "Coach acting on you" |
| `text.primary` | ink | all primary text |
| `text.secondary` | ink @ 0.7 | supporting text (kills the inline 0.65 drift) |
| `text.tertiary` | ink @ 0.5 | hints, footnotes |
| `text.disabled` | ink @ 0.35 | disabled |
| `action.primary` | ochre | primary buttons, steppers, active controls |
| `action.critical` | brick | destructive/irreversible CTAs (delete, rebuild) |
| `state.success` | sage | completion, saved, PRs |
| `state.warning` | brickLight | caution, reversible alerts |
| `state.danger` | brick | hard errors, irreversible |
| `redPen` | brick | the correction-mark color (marks, citations) |
| `hairline` | ink @ 0.06 | borders, dividers |

### Collisions resolved
- **Primary vs. danger** (both were brick before): primary actions are now **ochre**;
  brick is reserved for **critical/destructive** only. A brick button now *means* "this
  is irreversible," which is information, not decoration.
- **Accent vs. success** (both were ochre before): ochre = "Coach acting on you" (selection,
  primary). Success is **sage `#5A8C6E`** — a muted, on-paper green, never iOS system green.
- **Warning** is **brickLight `#C06040`** (terracotta), kept inside the red-pen family so
  "caution" reads as the pen, not a traffic light. ⚠️ Note: Zara floated an amber `#D08C30`
  for warning; I dropped it — it sits too close to ochre `#C4892A` and would muddy the
  "ochre = action" signal. **Flag D-1 below.**

---

## 2. Type as voice (Zara + Declan)

Two voices, strictly separated.

- **General Sans** — the human voice. Titles, body, everything a person reads as prose.
- **SF Mono** — the *coach's annotation* voice. Section labels, numerics, marginalia.
  **Mono is a detail voice — banned from body text.**

### Ramp
| Role | Font | Size | Weight | Use |
|---|---|---|---|---|
| `display` | General Sans | 32 | Bold | hero / screen title ("This is how I see you, today.") |
| `title` | General Sans | 24 | Medium | section/card titles |
| `body` | General Sans | 16 | Regular | main text, chat |
| `detail` | General Sans | 12 | Light | captions, hints |
| `numeric` | SF Mono | 14 | Regular | reps, sets, weight, days, PRs |
| `label` | SF Mono | 12 | Medium | UPPERCASE section dividers, marginalia |

All sizes ship `relativeTo:` a system text style so Dynamic Type scales them.

### Section-label voice (Declan)
Uppercase mono reads as a **coach's typewritten index**, not shouting — it's *indexing*,
the clinical order a coach imposes on the chaos of performance. **Keep uppercase mono.**

Declan also proposed renaming the You-tab sections to a consistent possessive index:
`YOUR PROFILE · YOUR GOALS · YOUR PROGRAM · YOUR COACH · YOUR NON-NEGOTIABLES · YOUR HISTORY`
(vs. today's "Who you are / What you're after / Your setup / Your coach / Limits + avoids").
The "YOUR ___" pattern is tighter and more dossier-like. **Flag D-2 below.**

### Numeric / unit style (Declan — locked canonical forms)
Mono numerics = ledger precision (objective, not cold). Canonical:
`225 LB` · `3X5` · `60 MIN` · `3 DAYS/WK`. Stat tiles use these verbatim.

---

## 3. Depth & surface — paper, not chrome

No drop shadows, ever. Dimension comes from **layered paper + ink lines**.

- **Base → elevated**: a card is `surface.elevated` over `surface.base`, separated by the
  hairline. Stacked cards read as sheets, not floating panels.
- **Pressed**: `surface.pressed` (ochre @ 10%).
- **Selected**: `surface.selected` (ochreLight) + a 1px ink outline.
- **Grain** (Pell): the cream is **not flat** — it carries a fiber tooth at **8% opacity**.
  ⚠️ Pell speced a live per-surface Canvas grain; Felix (correctly, for a scrolling list)
  says render grain **once** as a cached tiling image and `.multiply` it, not per-surface
  Canvas. **Resolution: one cached grain image, multiply @ 8%, via a `PaperBackground`
  modifier.** Uniform across tiers — texture is identity, not a tier signal.

---

## 4. Signature marks (Zara + Pell) — what makes it authored

Each mark is **procedural** (SwiftUI `Shape`/`Canvas`), drawn with hand-quality imperfection,
not an icon set. Strict placement rules — these are seasoning, not wallpaper.

| Mark | Quality (Pell) | Lives on | Banned on |
|---|---|---|---|
| Red-pen underline | brick, 1.5pt, slight taper, ±0.3pt wobble, round caps | emphasis under a coached phrase, citations | interactive controls |
| Red-pen circle | brick, 1.2pt, uneven closure | a corrected/highlighted value | buttons, nav |
| Rubber stamp | brick, uneven ink coverage + edge fade | **milestones only** | any UI element |
| Corner tab | folded ink corner | active/incomplete task cards | static content |
| Kettlebell ink | the existing line-drawing | completed sets, marginalia | as a mascot/decoration |
| Paper tear | 0.5pt hairline, ±0.5pt jaggedness | irreversible-action edges | reversible actions |
| Fold crease | 0.5pt, opacity gradient 0→100→0 | paper-fold transitions (completed sets) | static UI |

**First three stamps to ship:** `12 WEEKS` · `100 REPS` · `FORM CHECK`
(Pell replaced the gamified "FORM MASTER" with the factual "FORM CHECK").

---

## 5. Buildable architecture (Felix)

`MyoTheme` v2 = semantic namespaces over private primitives, so views call roles:

- `MyoColor.Surface.base/.elevated/.pressed/.selected`, `.Text.primary/.secondary/.tertiary/.disabled`,
  `.Action.primary/.critical`, `.State.success/.warning/.danger`, plus `.hairline`, `.redPen`.
- `MyoFont` enum (`.display/.title/.body/.detail/.numeric/.label`) → `Text(...).myoStyle(.title)`,
  each `.custom(... relativeTo:)` for Dynamic Type.
- Colors ship as **asset-catalog color sets** (one source of truth, previewable).
- Material: `PaperBackground` modifier (cached grain image, multiply @ 8%); red-pen marks as
  reusable `Shape`s; `MyoCard(tier:)`, `MyoButtonStyle(role:)` component tokens.

### Migration (v1 → v2), ordered so the working app never breaks
1. **Add primitives + semantic layer** alongside v1 (v1 stays valid during migration).
2. **Mechanical sweep:** `ink.opacity(0.65)`→`Text.secondary`, `0.5`→`.tertiary`, `0.45/0.4`→`.tertiary/.disabled`;
   `MyoTheme.Colors.cream`→`Surface.base`; brick-as-primary buttons→`Action.primary` (ochre) unless destructive.
3. **Type sweep:** raw `.largeTitle/.body/.caption` → `.myoStyle(...)`. Per-view judgment.
4. **Net-new (last):** `PaperBackground` grain on cards; red-pen marks; stamps in the Record tab.

### General Sans bundling
General Sans is free for commercial embedding (Fontshare / Indian Type Foundry). Bundle the
4 weights (.otf) via `project.yml` → `UIAppFonts`. **If we don't bundle in time, the system
falls back to SF Pro** (the ramp/sizes still hold; only the face changes). **Flag D-3 below.**

---

## 6. The line in the sand (refusals, beyond the existing ones)

- No drop shadows. Depth is paper + ink only.
- No iOS **system** state colors (system green/red). Success is sage, danger is brick.
- Mono is never body text.
- Marks are seasoned, not wallpapered — every mark obeys its placement table or it's a bug.
- Grain is felt, not seen (8%); if a user notices "texture," it's too much.
- (Still in force: no confetti, badges, points, streaks, neon, flame emojis, mascot energy.)

---

## Flagged decisions for Tosh

- **D-1 — Warning color.** Recommend **brickLight `#C06040`** (red-pen family) over amber
  `#D08C30` (collides with ochre). Easy to flip if you want warmer warnings.
- **D-2 — Section-label rename.** Adopt Declan's `YOUR PROFILE / YOUR GOALS / YOUR PROGRAM /
  YOUR COACH / YOUR NON-NEGOTIABLES / YOUR HISTORY`? Or keep the current human labels? (Affects
  the You-tab copy already shipped.)
- **D-3 — General Sans.** Bundle it now (download 4 weights, ~30 min + project.yml), or ship
  v2 on the system font and add the face later? The whole system works either way.

Everything else is locked and ready for Felix to build.

---

## Build status (2026-06-22)

Decisions locked by Tosh: **D-1** brickLight warning · **D-2** Declan's `YOUR …` section
labels · **D-3** ship on system font, bundle General Sans later.

**Shipped into the app (builds green, verified in simulator):**
- `MyoTheme.swift` v2 — primitives + semantic `MyoColor` roles (Surface/Text/Action/State) +
  `MyoFont` ramp via `.myoStyle`. `MyoCardModifier` for elevated sheets.
- `DossierComponents.swift` migrated to semantic roles.
- You tab: section rename (`YOUR PROFILE / YOUR GOALS / YOUR PROGRAM / YOUR COACH /
  YOUR NON-NEGOTIABLES`), sage success on the save bar, elevated-sheet depth.
- **Button doctrine sweep** (Coach / Train / Onboarding): every primary CTA flipped
  brick→ochre (ink text); brick now reserved for destructive (system `.destructive` role).
  `riskColor` → semantic `State` roles.
- **Paper grain** — `PaperBackground.swift`: one cached noise tile (Felix's perf call, not
  live Canvas), multiplied @ ~8%, applied to all four tab screens + onboarding.

**Remaining for full v2:**
- Mechanical text-opacity → `Text.*` role conversion across Coach/Train/Onboarding (~130
  invisible references; low-risk follow-up).
- Red-pen marks + milestone stamps — land where a surface holds them (Record tab, coach
  citations).
- General Sans bundling (D-3 follow-up).
