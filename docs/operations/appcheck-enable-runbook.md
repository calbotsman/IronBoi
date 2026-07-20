# App Check enable runbook (staging first, then prod)

How to turn App Check enforcement back on for the callable (`onCall`) surface.
The code side is already done: enforcement is env-gated behind
`IRONBOI_ENFORCE_APP_CHECK` (see `callableOpts` in `functions/src/index.ts`)
and defaults **OFF**. Everything below is operator work — Firebase Console
steps, one env line, one deploy.

Why it was off: enforcement was the only App Check anywhere in the stack, and
a Debug build whose debug token wasn't registered had every callable rejected
with `app:INVALID` while auth was valid (profile saves failed on device).
History: `docs/audits/myo-engineering-qa-2026-06-23.md`.

---

## Read this first — what flipping the flag actually protects (honest scope)

**The iOS app barely uses the callable surface.** Audit of
`ios/IronBoi/IronBoi/Services/AppModel.swift` (2026-07-17):

- The app reaches the backend almost entirely through the **`*Http`
  (`onRequest`) endpoints** using its custom `callFunction` wrapper with a
  **Bearer Firebase ID token**: `resetMyDataHttp`, `sendCoachMessageHttp`,
  `sendOnboardingAnswerHttp`, `acceptProgramProposalHttp`,
  `acceptPlanAdjustmentProposalHttp`, `startWorkoutSessionHttp`,
  `finishWorkoutSessionHttp`, `upsertProfileHttp`, `regenerateWorkoutPlanHttp`.
- The **only callable the app invokes via the Firebase SDK is
  `deleteAccount`**.
- The app *sends* an `X-Firebase-AppCheck` header on the HTTP wrapper calls,
  but **no `onRequest` handler verifies it server-side** — nothing in
  `functions/src/` calls `getAppCheck().verifyToken(...)`. The header is
  currently decorative.

So: flipping `IRONBOI_ENFORCE_APP_CHECK=true` locks down all 19 callables
(including the unused `onCall` mirrors), but of the surfaces the app actually
uses it protects **only `deleteAccount`**. The main traffic path stays
protected by Firebase Auth alone. That is still worth doing (it closes the
unused-but-live callable surface to scripted abuse and exercises the App
Attest pipeline before launch), but do not mistake it for full coverage.

**Before public App Store launch you must ALSO do one of:**

1. Migrate the iOS client from the `*Http` endpoints to the existing `onCall`
   twins (preferred — the mirrors exist precisely for this), then retire the
   `*Http` set; or
2. Add `getAppCheck().verifyToken(request.get("X-Firebase-AppCheck"))` inside
   each `onRequest` handler.

Tracked as a BLOCKER in `docs/audits/myo-engineering-qa-2026-06-23.md`.

## Second gotcha — Debug builds currently send NO App Check token

`IronBoiApp.swift` installs the provider factory only for Release builds
(`#if !DEBUG`). This was deliberate: an *unregistered* debug token is worse
than no token while enforcement is off. Consequences for this runbook:

- A stock Debug build never prints a debug token, and once enforcement is on,
  **Debug builds will fail every callable** (`deleteAccount`) because they
  send no token at all. The HTTP flows keep working.
- To do the debug-token registration in step 2 you must temporarily install
  the factory in Debug: in `ios/IronBoi/IronBoi/IronBoiApp.swift`, remove the
  `#if !DEBUG` / `#endif` around
  `AppCheck.setAppCheckProviderFactory(IronBoiAppCheckProviderFactory())`
  (the factory in `Services/AppCheckProviderFactory.swift` already picks
  `AppCheckDebugProvider` for DEBUG and `AppAttestProvider` for Release).
  Once your debug token is registered, that change is safe to keep — consider
  committing it at that point so all dev builds attest.

---

## Steps

### 1. Register the iOS app with App Attest

Firebase Console → project **ironboi-staging** → **App Check** → Apps →
**IronBoi (iOS)** → register → provider **App Attest**. Leave the token TTL at
the default (1 hour) for now.

### 2. Register your debug token

1. Apply the temporary Debug-provider change described above (remove
   `#if !DEBUG` in `IronBoiApp.swift`).
2. Run a Debug build in the simulator from Xcode.
3. Watch the Xcode console for `App Check debug token: <UUID>` (printed on
   first launch).
4. Firebase Console → App Check → IronBoi (iOS) → overflow menu (⋯) →
   **Manage debug tokens** → **Add debug token** → paste the UUID, name it
   after the developer/machine.

Repeat per developer/simulator install — the token is per-install.

### 3. Flip the flag

In `functions/.env.ironboi-staging` (tracked, non-secret), uncomment/add:

```
IRONBOI_ENFORCE_APP_CHECK=true
```

Land it through a normal PR, then deploy with a FULL functions deploy:

```
cd functions
firebase deploy --only functions --project ironboi-staging
```

**Never flip it per-service with `gcloud run services update`.** One flag
gates every callable across all services — flipping one service creates a
split-brain, and the next `firebase deploy` silently clobbers gcloud-set env
anyway (same rule as `IRONBOI_COACH_TOOL_LOOP_ENABLED`).

### 4. Verify with one app session

- Run a full app session (Debug build with registered token, or TestFlight
  build using App Attest): sign in, complete a coach exchange, save the
  profile, start/finish a workout. These ride the HTTP endpoints and must be
  unaffected.
- Verify the callable gate holds: a bare `curl` is 401 both before and after
  the flip (auth already rejects anonymous calls), so the status code alone
  proves nothing. The reliable signal is **a valid ID token with no App Check
  token**: sign in in the app, grab an ID token (or use the Firebase Auth REST
  API with a test account), then

  ```
  curl -s -X POST \
    https://us-central1-ironboi-staging.cloudfunctions.net/getUserState \
    -H "Authorization: Bearer <ID_TOKEN>" \
    -H "Content-Type: application/json" -d '{"data":{}}'
  ```

  Before the flip this succeeds; after the flip it must return 401 with an
  `UNAUTHENTICATED` body, and the function log shows the App Check
  verification failure with the handler never invoked
  (`gcloud functions logs read getUserState` or Console → Functions → Logs).
- Verify a *valid* callable still works: exercise `deleteAccount` from the app
  **with a throwaway test account only** — it is destructive and it is the
  sole callable the app calls.

### 5. Rollback

Remove (re-comment) the `IRONBOI_ENFORCE_APP_CHECK=true` line and run the same
FULL deploy:

```
firebase deploy --only functions --project ironboi-staging
```

No code change needed; OFF is the default.

---

## Notes / known sharp edges

- **`consumeAppCheckToken` is now a SEPARATE opt-in** (updated 2026-07-18,
  callable-migration PR): the client migration made callables the
  high-frequency path, and one-shot tokens + the iOS SDK's cached-token
  reuse would replay-reject every call after the first within a token
  lifetime. Consumption therefore requires BOTH `IRONBOI_ENFORCE_APP_CHECK`
  and `IRONBOI_CONSUME_APP_CHECK`. Do NOT set the consume flag until the
  iOS client adopts limited-use tokens
  (`HTTPSCallableOptions(requireLimitedUseAppCheckTokens: true)`).
  Enforcement alone is safe to flip once App Attest + debug tokens are
  registered.
- **Prod (`ironboi-prod` or equivalent):** repeat steps 1–4 with that
  project's console and `functions/.env.<project>` file. Do staging first and
  soak for at least a day of normal use.
- **The static test suite** pins the contract both ways:
  `functions/test/security/static/appCheckEnforcement.test.ts`. It no longer
  hardcodes `true`, so the suite is green with the flag off and stays green
  when you flip it.
