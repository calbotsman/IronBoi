# Legal documents

This directory holds documents that must be hosted publicly for the App Store submission and ongoing compliance.

## Files

- **`privacy-policy.md`** — the source-of-truth privacy policy in Markdown. Edit this when policy changes are needed; regenerate the HTML.
- **`privacy-policy.html`** — a single-file, self-contained HTML version. No external scripts, no fonts loaded from the network, no trackers. Drop it on any static host.

## Deployment options

Pick whichever is least friction:

### Option A — Firebase Hosting (you already have Firebase)

```bash
# First time only
firebase init hosting
# Pick "Use an existing project" → your IronBoi project
# Public directory: "legal"
# Single-page app: No
# Set up automatic builds: No

# Edit firebase.json to limit the hosting "public" target to this dir
# (so it doesn't try to host the PWA at the same time).

firebase deploy --only hosting
```

The policy will be at `https://<your-project>.web.app/privacy-policy.html`.

### Option B — Vercel / Netlify / GitHub Pages

Drop `privacy-policy.html` into any static host. The page is fully self-contained — no build step required.

### Option C — Your existing marketing site

Copy the HTML body into your CMS. Adjust the styles to match your site's theme.

## What URL to give Apple

In **App Store Connect → App Privacy** there is a "Privacy Policy URL" field. Put the publicly-reachable URL of `privacy-policy.html` there.

In the **PrivacyInfo.xcprivacy** manifest (already shipped in the iOS app), the declared data types must match what's described here. Cross-check before submission:

| In privacy-policy.md (Section 2) | In PrivacyInfo.xcprivacy |
|---|---|
| Email address | `NSPrivacyCollectedDataTypeEmailAddress` |
| Name | `NSPrivacyCollectedDataTypeName` |
| User ID (Firebase Auth UID) | `NSPrivacyCollectedDataTypeUserID` |
| Voice audio | `NSPrivacyCollectedDataTypeAudioData` |
| Workouts / daily checks / coach history / memory facts | `NSPrivacyCollectedDataTypeOtherUserContent` |

If you add data collection later, BOTH this policy and the manifest must be updated together.

## When to update

- Adding a new third-party data processor (analytics, error reporting, etc.) → update §11.
- Adding HealthKit ingestion → update §2 to remove the "not currently collected" note and add a HealthKit row.
- Changing retention period → update §5.
- Material change → bump the "Effective date" + post an in-app notice (§12 promises this).
