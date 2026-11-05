# Social prototype — "Train with friends"

Prototype of the Social section of [ideas.md](ideas.md). **Off by default**:
merging changes nothing for anyone until both flags are turned on.

## Turning it on

| Where | Flag | Default |
|---|---|---|
| Server (`functions/.env.<project>`) | `IRONBOI_SOCIAL_ENABLED=true`, then a full `firebase deploy --only functions` | off: every social callable returns `failed-precondition: social_disabled`, the coach never sees a friend line, no activity is published |
| App (`Services/SocialModel.swift`) | `SocialFeature.enabledInBuild = true` | off: nothing social is drawn, asked or called; `myo://join` links are ignored |
| App, Debug only | launch argument `-MYOSocialPrototype YES` | — |

Also deploy `firestore.rules` (new `socialActivity`, `socialConnections`, `socialInvites` matches; social consent records are now callable-only).

**Prerequisite: App Check.** The four social callables always enforce App Check (invite codes are bearer secrets), whatever `IRONBOI_ENFORCE_APP_CHECK` says. Register App Attest and the debug tokens first (docs/operations/appcheck-enable-runbook.md), or every social call will be rejected.

## What's in

- **One question**, after onboarding finishes: "Train with friends?" Default no — "Not now" or swiping it away. If no, the only trace of social is one "Train with friends" row in the You tab.
- **Invite by link or code.** You → Friends → Invite a friend makes a 12-character code (~59 bits) and a `myo://join/CODE` link to send. Single-use, expires after 7 days, one open invite per person. The friend opens the link (or types the code) and taps Join; that's a mutual connection. Max 20 friends, checked for both people. At most 10 accept attempts per person per day, wrong codes included.
- **Friend list in You**: first name, "Trained today" / "Not yet today", weekly streak. Per-friend **Leave** removes the connection for both people.
- **Coach brings friends in.** The text coach and live voice get one line like "Sam trained today." and are told to mention it once if it fits, never in pain or mid-set, and to say nothing about the friend's body, weight, injuries or health. The day counts as used only when a delivered coach reply actually names the friend, so a failed or unrelated turn doesn't burn it; after that, no more friend lines that day.
- **Privacy**
  - Consent is a normal consent record (`consentRecords/social_activity_v1`, category `social_activity`) written through `recordConsent`; turning off goes through `revokeConsent`.
  - Both sides consent: the inviter to create the invite, the friend before accepting; an invite from someone who has since turned it off is refused.
  - Friends never read Firestore. `getSocialFriendsCallable` returns first name, `trainedToday` (yes/no) and `streakWeeks`, and only accepts a "today" within a day of the server's date, so nobody can probe for the exact date. `socialActivity/{uid}` (`firstName`, `trainedOn`, `streakWeeks` only, with no ids or timestamps) is owner-readable only. A connection opens nothing under `users/{uid}`.
  - Every read (friend list, coach line) re-checks both people's current consent, so a missed cleanup can't leak.
  - Clients can't write the social consent record directly; it goes through `recordConsent`/`revokeConsent`, which always run the cleanup.
  - Revoking consent, turning it off, Start over and Delete account all remove your activity doc, every connection (both ways) and your open invites. On the Delete account and Start over paths the cleanup is best-effort and logged (`social_cleanup_failed`), so it can never block deletion.
  - Publishing activity reads consent inside a transaction, so a workout landing during a revoke or delete can't leave the doc behind.
  - Everything social is server-written; clients can't write any of it.

## What's out

Feeds, follower lists, public profiles, likes/comments, leaderboards, comparing workouts, push notifications about friends, contact-book or username search, universal links (the `myo://` scheme only opens the app if it's already installed), blocking/reporting (Leave is the only control).

## What to learn from testers

1. **Uptake** — how many say yes to the question, and how many turn it on later from You?
2. **Invites** — of invites made, how many get accepted? Where does it break (link not opening, code typed wrong, expired)?
3. **The coach line** — does "Sam trained today, your turn" feel motivating, pushy, or creepy? Does once a day feel right?
4. **Effect** — do connected people train more often or keep their streak longer than before?
5. **Privacy comfort** — is first name + trained today + streak the right amount to share? Does anyone want less (hide the streak) or more?
6. **Invisibility** — does anyone who said no ever notice social?

## Open items

- Privacy policy updated (`legal/`) — **needs legal review** before turning the flag on.
- The `myo://join` link only works when MYO is installed; a web landing page/universal link would be needed for friends who don't have it yet Another app can also claim the `myo://` scheme; a universal link fixes both. Codes are single-use, short-lived and accept-rate-limited, so a hijacked link costs one invite.
- "Trained today" uses each person's own calendar date from the workout log, compared against the viewer's date; friends in very different time zones can look off by a day.
