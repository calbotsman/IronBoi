---
title: MYO High-Fidelity Build Plan — Branding, UI, UX, Interactions
date: 2026-06-09
author: Claude (build audit) + studio (Zara, Felix, Declan, Deter, Pell)
inputs:
  - Full build audit (iOS, functions, rules, tests — verified this date)
  - docs/design/myo-you-tab-zara-direction.md (DIRECTION_LOCKED)
  - docs/design/myo-graphics-gameplay-zara-call.md
  - docs/strategy/myo-wedge-and-competitor-map.md
status: proposed — needs Tosh sign-off on the two flagged decisions
---

# MYO High-Fidelity Build Plan

## Part 0 — Build audit (verified 2026-06-09)

**Health: green.** All claims verified by running, not reading:

- iOS app **builds clean** for simulator (Xcode 17C52, iOS 26.2 SDK, target iOS 17).
- Functions: `tsc --noEmit` clean; `lint:security` 22/22; full emulator security suite **91/91 passing**.
- Phase plan reconciliation: Phases 0–1 fully shipped; Phase 2 shipped except the `derivedSummaries` rollup cleaner; Phase 3 has deleteAccount + audit log shipped, App Check HTTP enforcement and corpus embeddings deferred as documented. No stale Anthropic code, no leaked secrets, no rule gaps (drift test enforces allowlists).

**The real gap is the front of the app, not the back.** The backend's structural advantages (cite-or-refuse corpus, memory proposal queue, calm safety handling) are invisible in the UI, and the shipping SwiftUI app does not implement the locked Dossier design system anywhere.

### Functional gaps (audit findings)

| # | Gap | Severity |
|---|---|---|
| G1 | Progress tab is a `ContentUnavailableView` stub (placeholder copy even promises "streaks" — a refused concept) | High — a quarter of the tab bar is empty |
| G2 | Memory review UI missing — backend `confirmMemoryFact`/`deleteMemoryFact` exist, iOS never calls them. The "remembers you" wedge has no surface | High — wedge-critical |
| G3 | Citations not rendered — corpus retrieval feeds the model server-side but replies show no sources. The "explains why" wedge has no surface | High — wedge-critical |
| G4 | iOS uses a custom URLSession wrapper for ALL function calls → App Check tokens never attach; server-side `enforceAppCheck` on the 7 HTTP endpoints is blocked on this | High — security/bill protection |
| G5 | Active-workout set toggles are local-only until finish; app kill mid-session loses state | Medium |
| G6 | HealthKit client missing — `ingestHealthSamples` callable has no caller | Medium — strategy says enhance-not-depend, so scheduled but not first |
| G7 | Release build with placeholder prod plist silently falls back to staging instead of failing the build | Medium — TestFlight footgun |
| G8 | Accessibility: ~10 a11y labels app-wide, no Dynamic Type pass | Medium |
| G9 | Export-my-data callable (CCPA) + `decayProposedMemory` scheduled function + corpus embeddings — known deferred backend items | Low-Medium, tracked |
| G10 | React PWA (src/App.jsx, 1248 lines) is drifting legacy — no backend integration, predates App Check | Low — recommend explicitly freezing it as prototype |

---

## Part 1 — Creative direction (Zara, decided)

Zara **SHIPPED** the app-wide Dossier extension with one resequencing: **Coach tab moves ahead of You tab** — citation styling + visible memory is critical path for wedge visibility.

**Build order (locked by Zara):**
1. Design tokens + component kit
2. **Coach tab** rebuild — citation styling + persistent-memory note
3. **You tab** rebuild per locked layout spec
4. **Active Workout** game-feel moves
5. **Onboarding** ink-flow
6. **Progress tab** as "the training record"

**Progress tab concept:** *"This is what we did together."* Session entries as folded paper cards with ink-stamped date + lift; PRs as quiet ochre-stamped milestone cards; memory review as a cream accordion revealing coach notes in red pen.

**Brand board locks:**
- App icon: cream paper with ink kettlebell stamp (Pell's direction 1: ink kettlebell + brick pen circle).
- Type ramp v1: system fonts — SF Pro body + SF Mono labels (General Sans deferred).
- **Hardcoded yellow dies.** Ochre accents + brick CTAs everywhere. System black → ink. Radius → 14 everywhere.

**App Store hero shot:** the Coach tab — cream paper bubble, ink reply, small brick citation line below ("Source: …"), and a visible red-pen memory note ("Last session: 3×5 @ 225 lb"). All three wedge promises on one screen.

---

## Part 2 — Engineering plan (Felix, sequenced)

### Week 1 — Foundation
- **`MyoTheme` token layer (S):** static struct — `MyoTheme.Color` (cream/ink/ochre/ochreLight/brick/hairline via asset catalog), `Spacing` (xs4/sm8/md16/lg24/xl32/xxl48), `Radius.card = 14`, `Typography` (body, caption, `monospaceLabel`, `sectionHeader`). Static enum consumption, no environment plumbing for v1. Kill `Color.myoIllustrationPaper` (currently defined inside WorkoutView.swift:935).
- **AppModel split, plumbing first (M):** extract `NetworkService` (custom URLSession wrapper + 7 HTTP endpoints) and **attach App Check tokens** (`AppCheck.appCheck().token(forcingRefresh:)` → header) — this unblocks server-side `enforceAppCheck` on the HTTP surface (G4). Then `AuthService`, `CallableService`, `FirestoreService` (listeners as streams); AppModel becomes orchestrator.
- **Haptics + audio (S, high impact):** `UIImpactFeedbackGenerator.light` per rep, crisp ≤200ms audio on set completion.

### Week 2 — Coach tab (wedge surface) + component extraction
- Restyle Coach chat on tokens: cream paper, ink bubbles, brick citation line, red-pen memory note. **Requires small backend task:** persist structured `citations: [{entryId, source}]` on assistant message docs (corpus entries are already retrieved server-side; today they vanish into the prompt).
- Extract WorkoutView's 13 structs into Components/ (FlowLayout → shared, per layout spec), applying tokens as they move.
- **Mid-session persistence (M):** persist active-workout toggle state (scenePhase-driven local persistence; revisit server sync later) (G5).

### Week 3–4 — You tab rebuild (L)
- Kill the stock Form: ScrollView + custom card rows on cream, 88pt dossier header with hero line, monospace section labels, brick-ink selection (no toggles), sticky save bar via `safeAreaInset` with Saved/Failed states, FlowLayout chips for goals/tags.
- Known traps Felix flagged: keyboard/focus management leaving `Form` (ScrollViewReader + FocusState), dictation + save bar interplay.
- Game-feel: rep-counter pulse (Canvas + TimelineView, M) and matchedGeometryEffect card→session (M) land here, after components stabilize.

### Week 4–5 — Progress ("Record") tab v1 + remaining game-feel
- Cheapest honest v1: session list from `workoutLogs` (date, duration, effort) + one per-exercise trend in **Swift Charts** (custom Canvas only if Charts fights the aesthetic). Stamped PR milestone cards.
- Breathing day cards (M), paper-fold completed sets (L), ink-flow onboarding (L) — in that order, cut from the back if time presses.

### Scheduled alongside (backend, small)
- Citations on message docs (enables Week 2).
- `decayProposedMemory` scheduled function + composite index.
- Export-my-data callable (CCPA).
- Fail the Release build loudly when the prod plist is a placeholder (G7).
- After App Check tokens attach client-side: flip `enforceAppCheck` on the HTTP endpoints.

### New screen — Memory review (wedge-critical, G2)
Slot into Week 3 alongside the You tab (same visual kit): list confirmed facts, approve/reject proposed facts (`confirmMemoryFact`/`deleteMemoryFact` already exist). Zara places its visual as the cream accordion w/ red-pen notes; Declan's copy below.

---

## Part 3 — Copy kit (Declan, strings ready to wire)

- **Naming:** app name `MYO` everywhere user-facing (never IronBoi). App Store title: `MYO Coach`. ⚠️ **FLAGGED DECISION D-A below** on coach-entity naming.
- **Tab bar:** `Coach` / `Train` (was Workout) / `Record` (was Progress) / `Dossier` (was You).
- **Empty/error states:**
  - Record empty: "No sessions recorded yet. Start a workout in Train to begin building your record." (kills the "streaks" promise)
  - No plan today: "No plan for today. Ask Coach to build one, or start a custom workout in Train."
  - Timeout: keep "That reply took longer than I have to think…"
  - Network: "Connection lost. Check your network and try again."
  - Cap reached: "You've reached your daily message limit. Coach will be ready again tomorrow."
- **Memory review:** explainer "This is what MYO remembers about you. Review and refine it." Sections: Confirmed Facts / Proposed Facts. Verbs: `Confirm` / `Discard` (and `Remove` for confirmed). Empty: "No new facts proposed."
- **Active workout:** `Begin Workout` / `Set Complete` / `Rest` / `End Workout` → `Workout Complete`. Post-workout line: **"Good work."**
- **Citations:** brief parenthetical author attribution inline — "…progressive overload and sufficient protein intake (Schoenfeld)." Deep-dive lives elsewhere, never inline.

---

## Part 4 — QA checklist (Deter, gates for the sprint)

**BLOCKERS:** system `.yellow` accent anywhere (→ ochre/brick); system `.black` text (→ ink); tokens not centralized; stock Form chrome on You tab; "streaks" copy; tappable elements without a11y labels.
**MAJORS:** radius ≠ 14; off-palette `.blue` muscle chips; plain blue YouTube link (→ brick); no 200ms-fade motion standard; default SF Symbol tab icons untreated; app icon unreviewed; missing dossier header/hero; monospace-uppercase labels untested at XL Dynamic Type.
**Doctrine made testable:** "held breath" → all transitions are 200ms tonal fades, no spring/bounce curves; "no form chrome" → cream bg + brick selection + monospace labels + sticky save bar, each independently checkable.
**Deter's ruling needed-then-given on dark mode:** forced-light/cream-always is the intent, not a violation — enforce it deliberately and document it.

---

## Part 5 — Material kit (Pell, production-scoped)

- **Exercise marks, 3 tiers:** Tier 1: 6-frame ink sequences for the 8 core compounds (needs drawing time). Tier 2: one static "form mark" per movement family — hinge/squat/push/pull/carry/core (SVG/PDF now). Tier 3: monospace typographic fallback (SQ/HN/PS/PL/CR/CO) (free).
- **Marginalia kit (8 marks, each with allowed/banned placements):** brick underline, brick circle (form cues only), ink corner tab (section headers), paper-tear edge (modal edges), brick stamp (completed sets), paper-fold crease (transitions), hole-punch bullets, staple dividers. Banned on interactive elements across the board.
- **Milestone stamps:** rubber-stamp brick on embossed cream, typewriter label — first three: `12 WEEKS`, `100 REPS`, `FORM MASTER`. ⚠️ "FORM MASTER" reads gamified — recommend swapping for a factual stamp (e.g., `FIRST PR`) per the no-badges refusal.
- **Procedural vs assets:** paper folds/tears, pen underlines/circles, monospace labels → SwiftUI Canvas. Static marks, marginalia, stamps → SVG/PDF assets now. Sequences → drawing time.

---

## Decisions (locked by Tosh, 2026-06-09)

**D-A — Coach naming: LOCKED.** Declan's rule stands: app name is `MYO`, the entity is `Coach`. UI strings like "Ask MYO" become "Ask Coach". Onboarding opens "Hello. I'm Coach."

**D-B — Tab labels: LOCKED.** `Coach` / `Train` / `Record` / `You`. ("Dossier" stays the internal metaphor, not the tab label.)

Week 1 started 2026-06-09.

## Coaching protocols — a marquee hook (2026-06-23)

The coach-protocol feature (formerly "explanation lens") is being elevated to one of MYO's
headline hooks. The user picks a protocol; the coach reasons and explains through it.

**Roster (4):** Recovery & nervous system (Huberman) · Hypertrophy science (Schoenfeld) ·
Female physiology (Sims) · Longevity & measurement (Blueprint / Bryan Johnson — added 2026-06-23).

**Studio positioning (Rowan, reaffirmed + sharpened):** protocols are a real wedge *only* as
**explanatory authority, not mimicry** — "understand the why," never "train like X." Anchor the
UI on the **approach** (primary) with the person as a quieter **credibility cite** (subordinate),
which also de-risks trademark/endorsement and future-proofs against a named figure becoming
controversial. Keep the word **"Protocol"** (signals rigor). Cap at 3–4.

**Implementation (shipped, builds green, 91/91 backend tests):**
- Backend: `CoachingLens` enum gains `blueprint`; prompt's protocol rule carries each protocol's
  emphasis + a guardrail (protocol shapes emphasis, never safety/medical/corpus). Blueprint-specific
  guardrail bars supplement/dosage/brand prescription, age-reversal / "measured age" claims, and
  implying the user should replicate a biomarker-testing regimen (per Mercer's accuracy dossier).
- iOS: `CoachingLens` gains `.blueprint` + `attribution` (approach-primary, person-as-cite display);
  You-tab section relabeled "Coaching protocol"; new **protocol bar** on the Coach screen
  (`PROTOCOL · {approach} · {cite}`, tappable → You) surfaces it as a hook.
- Internal storage field stays `coachingLens` (no migration); all user-facing copy says "protocol."

**Onboarding step — SHIPPED (2026-06-23):** `coachingLens` added to the onboarding
`REQUIRED_FIELDS` (after `trainingFocus`), with a warm question, a `normalizeCoachingLens`
parser, and flow into the program proposal. iOS: 5 tap choices on the protocol step
("Coach's default" first so beginners aren't forced to have an opinion), step count 12→13.
Backend 91/91. (Couldn't screenshot — live onboarding needs the staging anonymous-auth toggle;
verified by tests + clean build, and it's a direct clone of the working trainingFocus step.)

**Corpus grounding — SHIPPED (2026-06-23):** four protocol evidence entries added to
`researchCorpus.ts` (`protocol_huberman_recovery_v1`, `protocol_schoenfeld_hypertrophy_v1`,
`protocol_sims_female_physiology_v1`, `protocol_blueprint_longevity_v1`), honestly sourced as
MYO-curated syntheses of each authority's published work (real sourceUrls; `expert_reviewed_note`),
each with claims + safety boundaries (Blueprint entry explicitly bars age-reversal / "measured age"
claims and supplement/biomarker-regimen prescription). Retrieval now feeds `preferences.coachingLens`
into the query so the active protocol's entry surfaces and the coach's "from a longevity-first
view…" framing hits the existing cite-or-refuse path. New `protocolRetrieval.test.ts` (+4): active
protocol surfaces, unchosen protocols don't, "none" forces nothing, topic keywords still match.
Suite 91→95.

**Coach citation surface — SHIPPED (2026-06-23):** the orchestrator persists the top reviewed
sources that grounded each turn onto the assistant message doc (`sources: [{entryId, label, title,
sourceUrl?}]`, top 2, complete replies only). iOS `CoachMessage` gains `sources`; the coach bubble
renders an **"INFORMED BY · {names}"** line with a hand-drawn red-pen underline (the first mark
shipped from Pell's kit), tappable to the source URL. Framing is "informed by" (honest: these
reviewed sources were in context) rather than a parsed quote. Verified in preview (screenshot).
Backend 95/95, iOS builds clean.

**Open (not yet done):** App Store one-liner leaning on protocols ("understand the why behind every
workout — protocols from Huberman to Bryan Johnson"); parsed/quote-level citations (which entry the
model actually leaned on) if we later move the provider to structured output.

## Simulator testing unblock (2026-06-12)

Three compounding causes made simulator testing painful; client side is fixed, two server toggles remain:

1. ✅ Custom HTTP wrapper never attached App Check tokens → every `enforceAppCheck` callable failed from the sim. Fixed: `X-Firebase-AppCheck` header in `AppModel.callFunction`.
2. ✅ App Check debug token rotated per install. Fixed: pinned `FIRAAppCheckDebugToken=7B49E8DA-2CDA-4A4C-8C9E-93D1C5A40F11` as a scheme env var in project.yml (staging-only credential; rotate in console if leaked). **One-time toggle:** register that token in Firebase Console → App Check → IronBoi (iOS) → Manage debug tokens.
3. ✅ Apple Sign-In flaky on simulator. Fixed: DEBUG-only "Dev sign-in (simulator)" button (anonymous auth) on Coach + Train signed-out views; compiled out of Release. **One-time toggle:** enable Anonymous provider in Firebase Console → Authentication → Sign-in method (verified currently DISABLED on ironboi-staging via REST probe — `ADMIN_ONLY_OPERATION`).

Automating the two toggles via API was attempted but blocked: gcloud + firebase CLI credentials both require interactive reauth (`invalid_rapt` — Workspace session policy).

## You tab rebuild — SHIPPED (2026-06-12)

The biggest visible Deter BLOCKER is cleared: `PreferencesView` no longer uses a stock SwiftUI `Form`. Full rebuild to the locked layout spec.

- `FlowLayout` extracted from WorkoutView → `Theme/FlowLayout.swift` (shared, the one structural change the spec required).
- New `Theme/DossierComponents.swift`: `MyoSectionLabel` (typewriter mono), `MyoGroupCard`, `MyoHairline`, `MyoSelectChip` (ochre selection, no toggles), `MyoTagChip` (removable, 44pt target), `MyoValueRow`.
- `PreferencesView` rewritten: `ScrollView` + `LazyVStack(spacing: xl)` on cream; non-scrolling header (hero line "This is how I see you, today." + completion pill + coach note); 5 grouped cards (Who you are / What you're after / Your setup / Your coach / Limits + avoids) per the IA collapse; sticky save bar via `safeAreaInset` with idle/saving/Saved(ochre,1.5s)/Failed(brick) states; ochre unsaved-edit dot on the pill; 200ms fade-in.
- Goals + experience as ochre select-chips (experience uses chips not a system segmented control — deliberate, to hold the cream palette). Equipment/injuries/dietary/disliked as removable tag chips with "Bodyweight"/"None right now" sentinels.
- Verified in simulator: empty state (0 of 4, dimmed Save) and filled state (Profile-complete ink pill, ochre unsaved dot, selected ochre chip, enabled ink Save). Builds clean.

**Deferred (per spec §7, unchanged):** profile photo, per-section completion indicators, inline coach ack on save.
