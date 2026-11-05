# MYO ideas

Josh's running list, unordered. An idea moves out of here when it gets a plan
(see `responsive-coach-plan.md`) or a PR. Before sharing MYO with a wider
group, the interactions already discussed need to feel nailed first.

## Wearables and heart rate

- **Peloton-style auto-start.** Tap start on the phone; if an Apple Watch is
  on, the MYO Watch app opens by itself and streams heart rate and calories
  back live.
- **Other wearables.** Bluetooth heart-rate straps (Polar, Wahoo, Garmin
  broadcast) live; Whoop, Oura and Garmin via what they sync into Apple Health.
- **Live stats, out of the way.** Heart rate, calories and one more (time in
  zone during sets, recovery during rest). A small pill: swipe away, tap back.

## The screen as atmosphere

- **Colour and grain follow effort.** Calm: fine, sparse grain, soft light
  colour. Pumping: denser, faster grain, richer colour, higher contrast. Zones
  come from the user's own max heart rate; blend over ~10 seconds so a spike
  doesn't flash.
- **MYO mirrors you.** HR up: MYO is bouncing, cheering, matching your pace.
  HR down: MYO slows, breathes, stretches, waits.
- **Rest by recovery.** "Your HR's back down, let's go."
- **Works without colour.** Calm vs pumped must differ in brightness, contrast
  and grain density, not hue alone. Test in greyscale and with iOS colour
  filters. One lightweight Metal shader driven by heart rate.

## A coach that responds to everything

- Heart rate, the workout in front of you, music levels, how you like to be
  talked to, how often you've trained lately, what kinds, the weights, the reps.
- **"I'm not doing that, I'm going for a run."** The whole session changes and
  is logged as a run. Needs the coach to understand loose speech and have
  actions to take (replace the workout, log a run), not fixed phrase rules.
- **Ask lightly, once.** "Want some kettlebell work after?" based on what the
  profile says they train toward (yoga, kettlebells, powerlifting, running and
  stretching). If no, drop it.

## Memory and recall

- **Instant start.** The phone caches a small memory brief: confirmed facts,
  coach notes, the last session, this week's training. The live coach opens
  with it, no network wait.
- **Refresh in the background.** After each workout or conversation the
  server rebuilds the brief; the phone saves over the old one.
- **Stay small.** A fixed budget (~1–2k words). Safety facts and injuries
  always in; older things summarised.
- **Deep recall on demand.** "What did I bench last spring?" Look up past
  conversations and logs only when asked (vector search over history, later).

## Social

- Train with friends, opt in. One onboarding question, off by default; if you
  don't want it, it isn't there.
- Join by invite link. No feeds, no follower lists.
- The coach brings friends in: "Sam trained this morning, your turn."
- Prototype first.
