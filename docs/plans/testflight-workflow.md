---
title: TestFlight — fast iteration workflow
date: 2026-06-02
status: live
---

# TestFlight workflow

How to spin up a fresh TestFlight build in under five minutes once the one-time setup is done.

## One-time setup (do once, then forget)

1. **Xcode → Settings → Accounts** — sign in with the Apple Account tied to the Developer Program enrollment (joshuaelliottlong@gmail.com per `launch-checklist.md`).
2. **Open the project** at `ios/IronBoi/IronBoi.xcodeproj`.
3. **Select the IronBoi target → Signing & Capabilities** — confirm:
   - **Team:** Joshua Long (SGQ2WLB6M9)
   - **Automatically manage signing:** ✅
   - **Bundle Identifier:** `com.thecombinationrule.ironboi`
   - **Provisioning profile:** Xcode auto-fills "Xcode Managed Profile" for Debug and an automatic Distribution profile for Release. Both should be green.
4. **In App Store Connect → TestFlight tab → Internal Testing**, add yourself (joshuaelliottlong@gmail.com) as an internal tester. Internal testers don't need beta app review — they see your build as soon as Apple finishes processing it (~5-20 min after upload).
5. **Install TestFlight on your iPhone** from the App Store, sign in with the same Apple Account.

That's the setup. Each subsequent TestFlight push is the loop below.

## Fast iteration loop (per build)

```bash
# 1. Bump build number (App Store Connect rejects duplicates)
./scripts/ios-bump-build.sh

# 2. Open Xcode
open ios/IronBoi/IronBoi.xcodeproj
```

In Xcode:

3. **Set destination dropdown to "Any iOS Device (arm64)"** — Archive requires a generic device target, not a simulator.
4. **Product → Archive** (Cmd-Shift-B then Cmd-B, or just menu). Build takes ~3-8 min.
5. When the Organizer window opens automatically with the new archive selected: **Distribute App → App Store Connect → Upload**. Click through the defaults. Upload takes ~2-5 min depending on connection.
6. App Store Connect processes the build for ~5-20 min. You'll get an email when it's "Ready to Test."
7. On your iPhone, **open TestFlight → IronBoi (or MYO Coach) → Update or Install**. Done.

Total wall-clock: ~10-30 minutes from code change to running on phone.

## What the bump script does

```bash
scripts/ios-bump-build.sh           # increments by 1 (most common)
scripts/ios-bump-build.sh 42        # sets to exactly 42 (rarely needed)
```

It rewrites `CURRENT_PROJECT_VERSION` in `ios/IronBoi/project.yml` and re-runs xcodegen to update `IronBoi.xcodeproj`. Build numbers are integers that must increase per marketing version. The marketing version (`MARKETING_VERSION`, currently `0.1.0`) only changes when you want a new "user-facing version" — you can ship many builds under the same marketing version.

## Firebase fallback note

Until you create the `ironboi-prod` Firebase project, the Release config (which TestFlight uses) **falls back to staging credentials with a loud warning**:

```
warning: GoogleService-Info-Prod.plist still contains REPLACE_WITH_PROD_*
sentinels. Falling back to STAGING for this Release build...
```

That's fine for internal TestFlight — your testers (you) talk to staging Firebase, which already works.

**Do NOT submit to public App Store review until that warning goes away.** Replace `ios/IronBoi/IronBoi/Firebase/GoogleService-Info-Prod.plist` with the real download from the `ironboi-prod` Firebase project; the next Release build picks it up automatically and stops warning.

## Common errors and what they mean

| Error | Cause | Fix |
|---|---|---|
| "No accounts found" in signing | Apple Account not added to Xcode | Settings → Accounts → + |
| "No profiles for com.thecombinationrule.ironboi" | App ID not registered, or capability mismatch | developer.apple.com → Identifiers → Myo → verify Sign in with Apple + App Attest both checked |
| "Build number must be greater than..." | You tried to upload with a duplicate build number | Run `./scripts/ios-bump-build.sh` and re-archive |
| "Missing compliance" in App Store Connect | Apple wants you to answer the export compliance question | TestFlight → Builds → click the build → answer "No, uses standard encryption only" (unless you've added custom crypto, which you haven't) |
| App crashes on launch in TestFlight | Firebase init failure (placeholder prod plist + no staging fallback, or App Check not registered) | Check the Console.app logs from the device; usually fixable via Firebase Console → App Check → Add device token, or by populating the prod plist |

## When to switch from "internal TestFlight" to "external TestFlight"

Internal testers (your team members on the Apple Developer Program team) install builds instantly with no review. Up to 100 of them.

External testers (anyone outside the team) require **Beta App Review** — a 24-48 hour Apple review of each new "Beta App Description." External testing is what you use to ship to a wider audience for feedback before public launch.

For now (single-developer use), internal testing is all you need.
