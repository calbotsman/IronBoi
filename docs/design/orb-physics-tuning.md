---
title: Orb physics — tuning log
date: 2026-10-07
status: live — one row per round
---

# Orb physics — tuning log

The blob's physics lives in `ios/IronBoi/IronBoi/Features/Coach/Orb/OrbPhysics.swift`
(the knobs and their defaults) and `OrbView.swift` (`OrbModel`, the springs).
Tuning happens in the simulator, one piece of physics per round.

## How to run a round

1. In Xcode pick the **IronBoi Reel** scheme and Run on an iPhone simulator.
   It opens straight into the preview session (no backend, no mic) with the
   stunt reel on loop and the **Physics** pill top-right.
   Same thing from a shell:
   ```
   SIMCTL_CHILD_MYO_PREVIEW=1 SIMCTL_CHILD_MYO_REEL=1 SIMCTL_CHILD_MYO_NO_MIC=1 \
   SIMCTL_CHILD_MYO_TUNER=1 xcrun simctl launch --terminate-running-process booted \
   com.thecombinationrule.ironboi
   ```
2. The reel, in order, forever: walk left → **dive** → blob → walk right →
   **cannonball** → blob → two jumps → **somersault** → blob → shadow-box →
   **melt** → blob. A burst of seven fake syllables (bloops) lands every
   nine seconds on top of that, so the lean gets exercised too.
3. Tap **Physics**, move sliders, watch the next landing. **Copy** puts the
   values on the clipboard as JSON. Paste them to Claude; they get baked in
   as the new defaults and a row is added below.
4. **Reset** returns to the baked defaults.

All of this is `#if DEBUG`; nothing ships.

## The knobs (round 1 — mass)

| Knob | What it does |
|---|---|
| `squashStiffness` | How fast the blob springs back to round (rad/s). |
| `squashDamping` | 0 rings forever, 1 no wobble. ~0.35 is two or three wobbles. |
| `stretchGain` | How much the blob elongates along its direction of travel, per unit speed. |
| `stretchMax` | The longest it can get while moving (1 = round). |
| `landKick` | Flatten on arrival when the person folds into the blob, before speed counts. |
| `landKickPerSpeed` | Extra flatten per unit of arrival speed. |
| `arrivalMemory` | How fast the remembered arrival speed fades; exits ease to a stop before the gather-in, so the landing answers to the fastest recent moment, not the instant of contact. |
| `restSpeed` | Below this the blob counts as still: the squash axis holds, no stretch. |
| `axisFollow` | How quickly the squash axis turns to follow a new direction. |
| `gatherStiffness` | How fast the person contracts into the blob (critically damped, every joint together). |

What changed under the hood: squash now acts along an axis (the shader takes
`squashAxis`), not only vertically. Moving, the blob stretches along its
velocity; landing, it flattens along the direction it arrived from, harder the
faster it came. Before this round the only impulse was a fixed vertical kick
when the person folded in.

## Rounds

| Round | Date | Piece | Values | Verdict |
|---|---|---|---|---|
| 1a | 2026-10-07 | mass: directional squash, arrival kick | stiffness 13 · damping 0.35 · stretchGain 0.12 · stretchMax 1.35 · landKick 1.6 · perSpeed 1.2 · restSpeed 0.05 · axisFollow 10 | Claude, from 20 fps frame sheets: axis follows the dive correctly, but the kick is faint because the sampled speed at the fold was ~0 (exits ease to a stop). |
| 1b | 2026-10-07 | mass: peak arrival speed | as 1a but landKick 2.4 · perSpeed 1.5 · arrivalMemory 4 | Landing reads at 2 fps now. Josh: "diving into a ball isn't super fluid at all" — the dive arrived as a rod and each joint sprang to the centre on its own weight (rod → lumps → ring → ball). |
| 1c | 2026-10-07 | gather-in | as 1b + gatherStiffness 16; dive tucks over its second half; arm shading cut during the gather | 20 fps: rod tilts, curls into a tuck, contracts into the ball in ~0.3 s with no ring; then the directional flatten and one rebound. Awaiting Josh. |
