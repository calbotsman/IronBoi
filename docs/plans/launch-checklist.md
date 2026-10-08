---
title: IronBoi / MYO — Launch Checklist
date: 2026-06-02
status: live
---

# Launch Checklist

The roadmap (`docs/plans/ironboi-phase-plan.md`) tracks the engineering work. **This doc tracks the things that are NOT engineering** — the manual steps you have to do in Apple's, Google's, and your own systems before users can install MYO.

Each item is either ⬜ open or ✅ done. Date the done items so future-you knows when. Last updated by Claude 2026-06-02.

## Status as of 2026-10-07 (read this first — the boxes below are from June)

Re-audited from the repo, GitHub, the Firebase CLI and staging logs on 2026-10-07 (`docs/audits/myo-full-audit-2026-10-07.md`). gcloud was expired, so IAM and API-enablement on staging could not be verified.

**Done (implied by TestFlight build 34 existing):** Apple Developer enrollment and team, App ID, Sign in with Apple and App Attest capabilities (both in `IronBoi.entitlements`), App Store Connect record, distribution signing. Staging backend is live with the voice-coach branch deployed. Plist switching, CI, build-number script, brand decision (display name MYO, bundle stays `ironboi`).

**Done in the repo on 2026-10-05:** memory review screen; privacy policy names OpenRouter; `ITSAppUsesNonExemptEncryption = NO`; `functions/.env.ironboi-prod`; listing draft; OpenRouter requests send `provider.data_collection: "deny"`; 401/402/403 from OpenRouter log as `model_billing_error`.

**Done in the repo on 2026-10-07 (branch `claude/audit-followups`, stacked on the voice-coach PR):**
- Spoken replies are metered: `synthesizeSpeechCallable` enforces a per-user daily character cap (`IRONBOI_TTS_CHARS_PER_DAY_CAP`, default 60k ≈ $1.80/day worst case) and the voice is pinned server-side (`IRONBOI_COACH_VOICE`); the client can no longer pick a voice. Over the cap the app falls back to the on-device voice.
- The twelve bearer-token `*Http` endpoints are gone from `functions/src/index.ts`, the iOS fallback transport is gone from `AppModel.swift`, and the nightly E2E harness calls the callables. The onCall surface is now the only surface, so App Check enforcement will cover all traffic once it is turned on. The next full staging deploy will prompt to delete the twelve retired functions — say yes.
- Privacy policy (md + html) now names Google Cloud Text-to-Speech, describes the always-open conversation mic, and says speech recognition is Apple's (on-device when supported, otherwise Apple's servers). `Last updated` 2026-10-07. **This expands what is shared (§12), so hosted copy + an in-app notice are needed before public users; TestFlight testers should be told.**
- `adapt_plan_shape` logs now carry `painTriageRedFlagsAsked`, `painTriageUserReportsSevere`, `severeMarkersHit` so a high-risk injury proposal after clean red-flag answers is diagnosable (deployed to staging 2026-10-07).
- README and the listing draft describe the voice-first screen instead of four tabs.

**Still open — Josh, in a web console:**
1. `gcloud auth login` (expired; firebase CLI auth was fine on 10-07).
2. Create the `ironboi-prod` Firebase project → add the iOS app → replace `ios/IronBoi/IronBoi/Firebase/GoogleService-Info-Prod.plist` with the real download → set `OPENROUTER_API_KEY` and `GEMINI_API_KEY` secrets → enable the Cloud Text-to-Speech API on the project → deploy. (As of 10-07 the only Firebase projects are ironboi-ac586, ironboi-fe18f and ironboi-staging.)
3. Register App Attest for the app in Firebase App Check — **and verify in logs before enforcing.** On 2026-10-07 build 34 every callable logged `Failed to validate AppCheck token … Decoding App Check token failed` and `app_check_presence outcome=absent`. With enforcement off this costs nothing; with it on, every call fails. Flip `IRONBOI_ENFORCE_APP_CHECK` only after `app_check_presence` reports `outcome:present` from a real build.
4. Host the privacy policy and pick a support URL (both required).
5. In App Store Connect: paste the listing, answer App Privacy (declare OpenRouter and Google as processors), age rating, category, contacts.
6. A GCP budget alert on the prod project.
6b. **Separate OpenRouter keys for MYO**: one for staging, one for prod, each with a credit limit, plus auto top-up and a low-balance email. Today's key is shared with the studio. The staging outages on 09-22, 09-23 and 10-04 (every turn failing with HTTP 402) were a drained balance. Set each with `firebase functions:secrets:set OPENROUTER_API_KEY --project <project>`, then redeploy.
7. Confirm OpenRouter, the Gemini API and Google Cloud Text-to-Speech are on terms that don't train on user content (the policy now says so and links Google Cloud's data-processing addendum; `data_collection: deny` backs the OpenRouter half).

**Still open — repo work:**
- App icon. A kettlebell-stamp draft was rejected (2026-10-05); Zara recommends direction A — an M drawn in one ink stroke that reads as shoulders. Awaiting Josh's pick. `docs/design/app-icon/myo-icon.svg` is sitting untracked.
- Screenshots. Retake all five from the current build (plan in `app-store-listing.md`); two untracked drafts are in `docs/app-store/screenshots/`.
- Proposed memory facts aren't swept after 14 days (`decayProposedMemory` is still a nice-to-have).
- Safety evals aren't run in CI (`functions/src/evals/safety-evals.json` has `releaseGate: true`, nothing runs it). Needs a runner with an LLM judge; not a one-liner.
- No iOS unit tests. `AppModel.swift` ~2.3k lines, `CoachStageView.swift` ~1.8k.
- Then run `scripts/preflight-appstore.sh` — it must exit 0 before a public submission.

**Deferred to v1.1 (fine for launch):** embeddings for the evidence corpus (today it's a 20-entry keyword-matched corpus with a cite-or-refuse prompt rule), HealthKit.

**Watch — the nightly injury arc is FLAKY, not harness noise.** Of the nine nights Sep 29 – Oct 7, seven failed; Oct 4 was the OpenRouter balance (HTTP 402), the other six were scenario C: the same scripted red-flag answers produced `riskLevel:high requiresFollowUp:true` instead of a low-risk card. The server only downgrades to low when the model sends `painTriage.redFlagsAsked:true` and the raw turn has no severe markers. A manual run on 10-07 (after the diagnostics deploy) passed 30/30 with `redFlagsAsked:true`, so the model sometimes omits it. Next failure, read `adapt_plan_shape` for that night: `painTriageRedFlagsAsked:null` means the model skipped triage attestation (prompt/schema fix), `severeMarkersHit:true` means the deterministic screen fired on the harness text (regex fix). Prime suspect for the Oct 6+ frequency change is `ac4e90d` (`provider.data_collection: deny` changes which upstream serves Flash). The ramp-scenario checks are fine as they are.

---

## A. Apple side

### A.1 Apple Developer account
- ⬜ Enrolled in the Apple Developer Program ($99/yr). Team ID matches what's set in Xcode → Signing & Capabilities.
- ⬜ Bundle identifier `com.thecombinationrule.ironboi` registered as an App ID under your team in https://developer.apple.com/account/resources/identifiers/list

### A.2 App Capabilities (one-time per App ID)
On the Identifier page for `com.thecombinationrule.ironboi`, enable:
- ⬜ **Sign in with Apple**
- ⬜ **App Attest** (required by Phase 3.2 — without this, Firebase App Check fails in Release)
- ⬜ Push Notifications (only if/when you add them — not required at launch)

After enabling capabilities you must regenerate the Distribution provisioning profile.

### A.3 App Store Connect record
- ⬜ App record created in App Store Connect with the same bundle ID
- ⬜ App name set ("IronBoi" — note: brand decision pending vs. "MYO Coach"; the strategy doc pitches MYO)
- ⬜ App category set (Health & Fitness / Lifestyle?)
- ⬜ Age rating filled (likely 17+ given health/medical adjacency)
- ⬜ Primary contact + technical contact emails
- ⬜ "App Privacy" answers filled — they must match `legal/privacy-policy.md` and `ios/IronBoi/IronBoi/PrivacyInfo.xcprivacy`. See `legal/README.md` for the cross-reference table.
- ⬜ Privacy Policy URL set (point at wherever you host `legal/privacy-policy.html`)
- ⬜ Marketing URL (optional)
- ⬜ Support URL (required — can be a simple page or your email)

### A.4 Signing
- ⬜ Distribution certificate created (in Xcode → Settings → Accounts → Manage Certificates)
- ⬜ Distribution provisioning profile auto-managed by Xcode (Signing & Capabilities → "Automatically manage signing" on the IronBoi target)

---

## B. Firebase side

### B.1 Two Firebase projects

- ⬜ **`ironboi-staging`** Firebase project exists (current dev backend). Confirm the URL `https://us-central1-ironboi-staging.cloudfunctions.net` resolves to deployed functions.
- ⬜ **`ironboi-prod`** Firebase project created. Same setup steps:
  - Create the project in https://console.firebase.google.com
  - Add an iOS app with bundle id `com.thecombinationrule.ironboi`
  - Download the prod `GoogleService-Info.plist`
  - Deploy backend: `cd functions && firebase deploy --only functions,firestore --project ironboi-prod`

### B.2 GoogleService-Info.plist switching

✅ **Shipped 2026-06-02 (commit 7d37e6e).** The `preBuildScripts` block in `ios/IronBoi/project.yml` picks the right plist per `$CONFIGURATION`:
- **Debug** → `ios/IronBoi/IronBoi/Firebase/GoogleService-Info-Staging.plist` (real staging credentials, tracked)
- **Release** → `ios/IronBoi/IronBoi/Firebase/GoogleService-Info-Prod.plist` (placeholder until you replace it)

The canonical `ios/IronBoi/IronBoi/GoogleService-Info.plist` is `.gitignore`'d and regenerated at the start of every build.

Until you replace `GoogleService-Info-Prod.plist` with the real prod download, a Release build **falls back to the staging plist** and emits a loud warning. It does NOT fail at first API call — it works, against `ironboi-staging`. That is deliberate, so TestFlight is usable before `ironboi-prod` exists, and it is exactly why the fallback needs a gate: a working build pointed at the wrong project is much easier to ship by accident than a broken one.

**The gate is `MARKETING_VERSION`, not the build configuration.** A build cannot tell a TestFlight archive from an App Store archive — both use Release and produce the identical binary; the destination is chosen afterwards in Organizer. So the prebuild script only warns while the app is `0.x`, and **hard-fails from `1.0.0` onward** if the prod plist is still a placeholder.

That backstop is deliberately crude. The real check is `scripts/preflight-appstore.sh`, which verifies what a build phase cannot: that the prod project exists and has the backend deployed to it.

### B.3 App Check registration

- ⬜ In Firebase Console → App Check → IronBoi (iOS), enable App Attest provider with your Apple Team ID
- ⬜ For debug builds: register debug tokens (see `ios/IronBoi/IronBoi/Services/AppCheckProviderFactory.swift` — first Debug run prints a UUID to the Xcode console)

### B.4 Backend secrets
- ⬜ `GEMINI_API_KEY` secret set on the prod project: `firebase functions:secrets:set GEMINI_API_KEY --project ironboi-prod`

---

## C. App Store Connect — pre-submission assets

### C.1 Real brand icon
- ⬜ Replace the placeholder at `ios/IronBoi/IronBoi/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`. Requirements: 1024×1024, sRGB, no transparency, no rounded corners (Apple rounds them).
- ⬜ Optional: drop additional sizes (`AppIcon-180.png`, etc.) if you want pixel-perfect control rather than letting Xcode resample.

### C.2 Screenshots
Apple requires screenshots for at least one device size. Options:
- ⬜ 6.7" iPhone (iPhone 15 Pro Max / iPhone 16 Pro Max class) — required
- ⬜ 6.5" iPhone — recommended for older devices

Capture inside the iOS Simulator (Cmd-S in Simulator app). Two to three screenshots minimum, ten max.

### C.3 App preview video (optional)
- ⬜ 15-30 second video showing key flows (sign in, chat with coach, log workout). Reviewers see them.

### C.4 Descriptions
- ⬜ Promotional text (170 chars max) — appears above the description, can change between versions without re-review
- ⬜ Description (4000 chars max) — what the app does
- ⬜ Keywords (100 chars max, comma-separated) — improves App Store search
- ⬜ What's New in This Version (4000 chars) — release notes

### C.5 Legal
- ⬜ Privacy Policy URL hosted and reachable (see `legal/README.md`)
- ⬜ Decide on Terms of Service. Apple does not require a separate ToS; their EULA is the default. If you ship your own ToS, you'll need to host that page too.

---

## D. Engineering items still open

Lives under `docs/plans/ironboi-phase-plan.md`. The remaining work:

### Hard launch blockers
- ⬜ Phase 3.3 — corpus retrieval with embeddings + cite-or-refuse. Without this, the coach can make health claims it shouldn't. Multi-hour infra project (Vertex AI Vector Search OR Firestore Vector Search Extension setup). **Could potentially defer to v1.1 if MVP is just "general fitness coaching, no specific health claims."**

### Soft launch blockers (won't reject, but bad if missed)
- ⬜ iOS memory review UI (Phase 2.3 client). Proposed memory facts pile up with no way for users to confirm them.
- ⬜ Safety eval as CI gate (`functions/src/evals/safety-evals.json` has `releaseGate: true` — nothing runs it before deploy)
- ⬜ `decayProposedMemory` scheduled function (Phase 2.3 follow-up)
- ⬜ `DerivedHealthContext` rollup function (Phase 2.4 follow-up, only matters once HealthKit integration lands)
- ⬜ iOS HealthKit integration (when shipped, also update PrivacyInfo.xcprivacy + privacy-policy.md §2)

### Operational
- ⬜ CI/CD pipeline (GitHub Actions: run `npm test` on PRs, build iOS on PRs)
- ⬜ Monitoring + alerting on Cloud Functions errors + spend overages
- ⬜ Per-build version bumping. `CURRENT_PROJECT_VERSION` in `ios/IronBoi/project.yml` starts at 1; App Store Connect rejects duplicates.

### Strategic
- ⬜ Brand decision: "IronBoi" (repo + bundle ID) vs "MYO" (coach identity + strategy doc). Either rename the bundle (annoying — provisioning regen) or just ship as "IronBoi" with "MYO Coach" as the in-app character. Recommend the latter for simplicity.
- ⬜ PWA fate: `wip/firebase-bridge` branch is parked. Iron Lab either absorbs Firebase or stays local-first.

---

## E. First-launch readiness check

Before tapping Archive for the first prod build, confirm:

- ✅ Phase 0 + 1 + 2 + 3.1 + 3.2 + 3.4 backend shipped
- ✅ `npm run check`, `npm run lint:security`, `npm run test:security` all green
- ✅ iOS builds for Debug AND Release configurations (xcodebuild)
- ✅ `PrivacyInfo.xcprivacy` shipping in the .app bundle
- ✅ `AppIcon.appiconset` present
- ⬜ All ⬜ items above completed
- ⬜ One end-to-end smoke test: sign in with Apple → see coach → send message → log a workout → verify it lands in Firestore → invoke Delete Account → verify the wipe happened
- ⬜ Privacy Policy URL reachable on a public domain
- ⬜ **`scripts/preflight-appstore.sh` exits 0.** Run this immediately before a PUBLIC submission — not before a TestFlight upload, which is fine on staging. It checks the prod plist has no placeholders, the `ironboi-prod` project actually exists, and the core callables are deployed there. A real plist pointing at an empty project is the same outage as no plist at all.

When this list is all checked: archive, upload, invite internal testers.

When internal testers report no critical bugs: submit for App Store review.

---

## F. Post-launch first-week monitoring

- Check Cloud Functions errors daily
- Check Firebase spend daily (set a budget alert at $X/day)
- Watch for App Store Review feedback (usually 24-72 hr turnaround)
- Track delete-account rate — if it's high, something's wrong
- Track Apple App Attest failure rate — should be near zero on real devices
