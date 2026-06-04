---
title: IronBoi / MYO — Launch Checklist
date: 2026-06-02
status: live
---

# Launch Checklist

The roadmap (`docs/plans/ironboi-phase-plan.md`) tracks the engineering work. **This doc tracks the things that are NOT engineering** — the manual steps you have to do in Apple's, Google's, and your own systems before users can install MYO.

Each item is either ⬜ open or ✅ done. Date the done items so future-you knows when. Last updated by Claude 2026-06-02.

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

Until you replace `GoogleService-Info-Prod.plist` with the real prod download, **Release builds emit a loud warning** during xcodebuild and Firebase will fail at first API call. See `ios/IronBoi/IronBoi/Firebase/README.md` for the populate steps.

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

When this list is all checked: archive, upload, invite internal testers.

When internal testers report no critical bugs: submit for App Store review.

---

## F. Post-launch first-week monitoring

- Check Cloud Functions errors daily
- Check Firebase spend daily (set a budget alert at $X/day)
- Watch for App Store Review feedback (usually 24-72 hr turnaround)
- Track delete-account rate — if it's high, something's wrong
- Track Apple App Attest failure rate — should be near zero on real devices
