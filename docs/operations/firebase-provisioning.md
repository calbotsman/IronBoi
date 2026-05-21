# Firebase Provisioning + First Deploy

**Status:** ready to execute
**Estimated time:** 25–40 minutes for staging end-to-end
**Prereq access:** Apple Developer team, Anthropic API key, the IronBoi repo cloned at `~/IronBoi`

This is the path from "code on disk" to "Apple sign-in works against a real Firebase project, Firestore writes succeed, the coach trigger fires." Two environments: `ironboi-staging` first, `ironboi-prod` later (same playbook, different name + secrets).

---

## 1. Prerequisites

```sh
# Node 22 (Cloud Functions runtime)
node --version    # expect v22.x

# Firebase CLI (latest)
npm install -g firebase-tools
firebase --version

# Sign in
firebase login
```

If `firebase login` returns a Google account that isn't tied to TheCombinationRule, run `firebase login --reauth` or `firebase logout && firebase login`. The account that creates the project is the initial owner.

---

## 2. Create the staging project

```sh
firebase projects:create ironboi-staging --display-name "IronBoi Staging"
```

If the name's taken, try `ironboi-staging-tcr` or any unique suffix. The display name is mutable later; the project id isn't.

Link the local repo to the new project:

```sh
cd ~/IronBoi
firebase use --add ironboi-staging --alias staging
```

This writes a `.firebaserc` mapping `staging` → `ironboi-staging`. Commit `.firebaserc`. **Do not commit any `.env.local` files.**

---

## 3. Enable required services

In the Firebase console (https://console.firebase.google.com), open the staging project and:

1. **Build → Firestore Database → Create database**
   - Mode: **Production**
   - Location: `us-central` (matches `region: "us-central1"` in the callables)

2. **Build → Authentication → Get started**
   - Sign-in providers → **Apple** → Enable

3. **Build → Functions** — no UI step needed; the deploy enables it.

If you see a banner asking to enable billing, click through and add a billing account. **Functions and Firestore both require Blaze (pay-as-you-go) even for staging.** Free tier of Blaze is generous; staging will sit at $0/month until traffic.

---

## 4. Configure the Apple sign-in provider

In **Authentication → Sign-in method → Apple**, you need:

| Field | Where it comes from |
|---|---|
| Services ID | Apple Developer → Certificates, Identifiers & Profiles → Identifiers → "+" → Services IDs. Use `com.tcr.ironboi.signin.staging`. |
| Apple Team ID | Apple Developer → Membership |
| Key ID | Apple Developer → Keys → "+" → "Sign in with Apple" → enable, register, download the `.p8` |
| Private Key | Contents of the downloaded `.p8` |

Paste them into the Firebase console. **Save the `.p8` somewhere safe — Apple lets you download it once.**

The Services ID needs **Sign in with Apple** enabled and the Firebase auth handler URL configured as a return URL: `https://ironboi-staging.firebaseapp.com/__/auth/handler`.

> Skipping this step makes `signInWithApple()` fail with "auth/invalid-credential" or "auth/operation-not-allowed". Both are silent in the PWA today (see review note about silent sign-in failures).

---

## 5. Set coach model secrets

Gemini is the default coach model provider in staging. Anthropic remains wired as a fallback/comparison provider.

Set the Gemini API key first:

```sh
firebase use staging
firebase functions:secrets:set GEMINI_API_KEY
# paste your Gemini API key when prompted
```

Verify it landed:

```sh
firebase functions:secrets:access GEMINI_API_KEY
```

Optional fallback/comparison key:

```sh
firebase use staging
firebase functions:secrets:set ANTHROPIC_API_KEY
# paste your key when prompted
```

Verify it landed:

```sh
firebase functions:secrets:access ANTHROPIC_API_KEY
```

These are referenced from the trigger via `defineSecret("GEMINI_API_KEY")` and `defineSecret("ANTHROPIC_API_KEY")`. Runtime provider selection is controlled by `IRONBOI_COACH_PROVIDER` and defaults to `gemini`; `IRONBOI_COACH_MODEL` defaults to `gemini-2.5-flash`.

---

## 6. First deploy

```sh
cd ~/IronBoi
firebase use staging
firebase deploy --only firestore:rules,firestore:indexes,functions
```

Expected output: 11 functions deployed (`getCoachBootstrap`, `getUserState`, `upsertProfile`, `recordConsent`, `logWorkout`, `upsertWorkoutPlan`, `recordDailyCheck`, `upsertMemoryFact`, `deleteMemoryFact`, `revokeConsent`, `createCoachSession`, `sendCoachMessage`, `recordSafetyEvalResult`, `onUserCoachMessageCreated`).

If Cloud Build fails on the first deploy with "permission denied" on the Eventarc service agent, run:

```sh
gcloud projects add-iam-policy-binding ironboi-staging \
  --member="serviceAccount:service-<PROJECT_NUMBER>@gcp-sa-eventarc.iam.gserviceaccount.com" \
  --role="roles/eventarc.serviceAgent"
```

(`<PROJECT_NUMBER>` is in the Firebase console → Project Settings → General.) This is a one-time Eventarc bootstrap.

---

## 7. Populate the local `.env.local`

In the Firebase console → **Project Settings → General → Your apps → Web app**, register a web app called `IronBoi PWA`. Copy the config values into `~/IronBoi/.env.local`:

```
VITE_FIREBASE_API_KEY=<apiKey>
VITE_FIREBASE_AUTH_DOMAIN=ironboi-staging.firebaseapp.com
VITE_FIREBASE_PROJECT_ID=ironboi-staging
VITE_FIREBASE_APP_ID=<appId>
VITE_FIREBASE_MESSAGING_SENDER_ID=<messagingSenderId>
```

`.env.local` is already in `.gitignore` — verify before committing anything.

Restart the dev server:

```sh
npm run dev
```

The header should now show `SYNC` instead of `Local mode`.

---

## 8. Smoke test (manual, 5 minutes)

Open the running PWA in Chrome.

1. Click **SYNC**. Apple sign-in popup opens. Complete sign-in.
2. Header should flip to `SYNC ON` with status `Synced`.
3. Open Firebase console → **Firestore Database**. Expect:
   - `users/{your-uid}/profile/current` — empty until first profile write, OK.
   - `users/{your-uid}/workoutPlans/current` — populated after the first plan edit.
4. Edit a plan exercise (change reps, swap an exercise). Wait ~700ms (debounce).
5. Refresh Firestore console. The plan doc should reflect the edit.
6. Toggle a daily habit. Within ~1s, `users/{your-uid}/dailyChecks/{YYYY-MM-DD}` should exist with the toggled key.
7. Start a workout, mark some sets done, finish. A `users/{your-uid}/workoutLogs/{sessionId}` doc should appear.

If any step fails, check the Cloud Functions logs:

```sh
firebase functions:log --only upsertWorkoutPlan,recordDailyCheck,logWorkout
```

Most failures are Zod validation errors — the client is sending a shape the schema doesn't accept. Fix the client mapping (`toFirestorePlan`, `toFirestoreDaily`, `legacyLogToFirestore`).

---

## 9. Grant yourself the admin custom claim

Required to call `recordSafetyEvalResult` and to access admin-only data (`internalSafetyEvalResults`).

There's no Firebase CLI command for custom claims; do it from a one-off script:

```sh
# scripts/set-admin.mjs (gitignored)
import admin from "firebase-admin";
admin.initializeApp({ projectId: "ironboi-staging" });
const uid = process.argv[2];
await admin.auth().setCustomUserClaims(uid, { admin: true });
console.log(`Set admin: true on ${uid}`);
```

```sh
GOOGLE_APPLICATION_CREDENTIALS=~/Downloads/ironboi-staging-adminsdk.json \
  node scripts/set-admin.mjs <your-uid>
```

The service account JSON comes from **Project Settings → Service accounts → Generate new private key**. Treat it like a password. Don't commit it. Don't even put it in iCloud Drive.

After running, sign out and back in to the PWA so the new claim lands in your ID token.

---

## 10. Common gotchas

- **"Apple sign-in popup closes immediately"** → Services ID return URL doesn't match `https://<project-id>.firebaseapp.com/__/auth/handler` exactly. Trailing slashes matter.
- **"Cloud Functions deploy fails on first run with `eventarc.googleapis.com` not enabled"** → run `gcloud services enable eventarc.googleapis.com run.googleapis.com cloudbuild.googleapis.com cloudfunctions.googleapis.com pubsub.googleapis.com --project=ironboi-staging`.
- **"Firestore rules deploy says no rules file"** → confirm `firebase.json` has `"firestore": { "rules": "firestore.rules" }` and you're in the repo root.
- **"`onUserCoachMessageCreated` doesn't fire"** → Firestore in **Datastore mode** instead of **Native mode** breaks Firestore triggers. Native mode is the default for new projects; if you migrated from a Datastore project, you can't switch. Make a new project.
- **"Functions cold-start is slow in staging"** → expected. Set `minInstances: 1` only on `onUserCoachMessageCreated` once the trigger actually does work; staging idle costs are otherwise zero.

---

## 11. Production cutover (later)

Same playbook, swap names:

```sh
firebase projects:create ironboi-prod --display-name "IronBoi"
firebase use --add ironboi-prod --alias prod
firebase functions:secrets:set ANTHROPIC_API_KEY  # use a different prod key
firebase deploy --only firestore:rules,firestore:indexes,functions --project prod
```

Production needs:

- A separate Apple Services ID (`com.tcr.ironboi.signin`) with the prod handler URL.
- Production privacy policy URL set on the App Store listing + in the PWA footer.
- Cloud Logging exports turned off for any sink that touches third-party analytics.
- App Check enabled on all Cloud Functions to block bots/scrapers (separate spec).

Don't deploy prod until staging passes the safety eval suite end-to-end.

---

## 12. After this doc is executed

Two things become true:

1. The PWA on staging supports real Apple sign-in + Firestore sync.
2. Codex can implement the orchestration spec against a live Firestore + Functions environment, with smoke tests against the trigger.

Next docs to read after this:
- `docs/plans/coach-orchestration-spec.md` — what to build next.
- `safety-evals.md` (functions package) — the release gate the orchestration must pass.
