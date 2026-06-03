# MYO Privacy Policy

**Effective date:** 2026-06-02
**Last updated:** 2026-06-02

This is the privacy policy for **MYO** ("MYO," "we," "us"), an AI fitness coaching app for iOS published under the App Store name "IronBoi" by The Combination Rule (bundle identifier `com.thecombinationrule.ironboi`).

If you have questions about this policy or your data, contact us at **support@thecombinationrule.com**.

---

## 1. The short version

- We collect only the data we need to coach you. No advertising, no data brokers, no cross-app tracking.
- Your data lives in your own private corner of Google Firebase. Other users cannot read it.
- You can delete your account and all your data from the app at any time: **Account menu → Delete Account…**.
- We do not sell your data to anyone.
- We will tell you within 60 days if a security incident affects your data (FTC Health Breach Notification Rule).

The rest of this document spells out the details.

---

## 2. What we collect

| Category | Source | Why |
|---|---|---|
| **Email address and name** | Apple Sign In (only if you share them) | Identify your account so the coach is talking to *you* and only you |
| **User ID (Firebase Auth UID)** | Apple Sign In | Tie all your data together server-side |
| **Workouts and daily checks** | You enter them in the app | Show your history, let the coach see what you've actually done |
| **Coach conversation history** | You chat with the coach | Let the coach maintain context across sessions |
| **Memory facts** (e.g., "prefers morning sessions") | Either you tell the coach, or the coach infers them from a chat | Personalize advice. Inferred facts are marked "proposed" and don't influence advice until you confirm them. They auto-expire after 14 days if unconfirmed. |
| **Voice audio** | You hold the mic button to dictate to the coach | Convert speech to text using Apple's on-device speech recognition. **The audio itself is not sent to our servers** — only the transcribed text. |
| **Usage counters** | App activity (number of messages, token counts per day) | Enforce per-user daily caps so one account can't run up an enormous bill or be abused. |
| **Audit log** | Server-side, every consent change, memory write, health-ingest, and spend-cap hit | Internal records of what changed and when. The actual content of what changed is never logged — only a one-way hash. |

We do NOT currently collect:
- **HealthKit data** — the iOS app has no HealthKit integration yet. When we add it (planned), we will ask for explicit permission per data type (steps, heart rate, sleep, body weight, HRV, workouts) before reading anything.
- **Location** — we don't ask for it and don't use it.
- **Contacts, photos, or anything else outside our own app's data**.

---

## 3. How we use your data

- **To run the coaching feature.** Every chat turn sends what you wrote plus your profile, recent workouts, and confirmed memory facts to a third-party large language model (currently Google Gemini) so it can produce a reply. Google does not retain that content for training their models when accessed via the Vertex AI API.
- **To save your progress.** Workouts, daily checks, and your custom plan are stored so you can see them across devices and sessions.
- **To enforce safety limits.** A per-user daily message and token cap prevents abuse. Hitting the cap is recorded in your audit log.
- **To respond if something goes wrong.** Errors are logged with your account ID so we can debug; no chat content or personal data appears in error logs.

We do **not** use your data:
- to train AI models
- to sell to advertisers, data brokers, or affiliates
- to profile you for cross-app tracking
- to target you with ads

---

## 4. Where your data lives

Backend infrastructure is **Google Firebase** (Firestore database, Cloud Functions, Firebase Auth, Firebase App Check). Servers are in the **us-central1** region in the United States.

If you are outside the United States, your data will be transferred to and processed in the U.S. We rely on Standard Contractual Clauses (SCCs) and Google's terms of service to cover those transfers.

---

## 5. How long we keep it

| Category | Retention |
|---|---|
| Account, workouts, daily checks, coach history, confirmed memory | Until you delete your account, or stop using the app for 18 months (we'll email you before deletion). |
| **Proposed memory facts** (coach-inferred, not yet confirmed) | 14 days from creation, then auto-deleted. |
| Audit log entries | As long as the rest of your account; deleted with it. |
| Crash and error logs | 90 days. |
| Deletion tombstone (`{ userId, deletedAt, requestedBy }`) | 7 years, for our records that a deletion request was processed. Never includes the deleted content itself. |

---

## 6. How to delete your data

Two paths:

1. **In-app.** Open the app → Coach tab → tap the account icon (top-right) → **Delete Account…** → confirm twice. We immediately:
   - Wipe everything under `users/{your_uid}/` (profile, memory, workouts, daily checks, coach history, audit log)
   - Revoke all your sign-in sessions so any other devices can't keep using your account
   - Write a tombstone at `deletedAccounts/{your_uid}` with the deletion timestamp

2. **Email.** Send a deletion request from the email address associated with your account to support@thecombinationrule.com. We will process it within 30 days.

Deletion is permanent. We cannot recover the data once it's gone.

---

## 7. Your rights

Depending on where you live, you may have additional rights:

- **Right to access.** Request a copy of the data we hold about you. Email us.
- **Right to correct.** Most fields are editable in-app (profile, workouts). For coach memory, you can confirm or delete proposed facts.
- **Right to delete.** Via in-app **Delete Account** or by emailing us.
- **Right to portability.** Email us; we can export your data as JSON.
- **California (CCPA/CPRA).** Same rights as above, plus the right to know what categories of data we collect, the right to opt out of any sale (we don't sell), and the right not to be discriminated against for exercising your rights.
- **EEA/UK (GDPR).** Same rights, plus right to lodge a complaint with your local supervisory authority. Lawful basis for our processing is "performance of a contract" (you asked us to coach you) and "legitimate interests" (security and abuse prevention, balanced against your privacy).

---

## 8. Children

MYO is intended for users aged **18 and older**. We do not knowingly collect data from anyone under 13 (under 16 in the EEA). If we learn that we have collected data from a child below that age, we will delete it. Contact us if you believe this has happened.

---

## 9. Security

- All data is encrypted in transit (TLS) and at rest (Firebase default encryption).
- Apple App Attest + Firebase App Check verify that only legitimate MYO app builds running on real Apple devices can talk to our backend.
- Per-user write-rule allowlists prevent one user's malicious client from writing into another user's data.
- Coach replies are filtered through pre- and post-flight safety classifiers before reaching you.
- We do not encrypt your data with a key only you hold. If a court orders us to disclose your data, we are technically able to do so.

Despite these measures, no system is perfect.

---

## 10. Breach notification (FTC HBNR)

MYO is a "vendor of personal health records" under the FTC's Health Breach Notification Rule. If we discover a breach of security affecting unsecured user-identifiable health information (e.g., your workouts, daily checks, voice transcripts containing health detail, future HealthKit data), we will:

1. Notify affected users within **60 days** of discovery, by email and an in-app notice.
2. If more than 500 users are affected, notify the FTC within 60 days and post a notice on our website.
3. Include in the notice: what happened, what information was involved, what we are doing about it, what you can do to protect yourself, and how to contact us.

---

## 11. Third parties we share data with

We share data only with the service providers that operate our backend:

- **Google LLC** (Firebase / Google Cloud) — hosts our database, authentication, and serverless functions. Google's privacy policy: https://policies.google.com/privacy
- **Apple Inc.** — when you Sign In with Apple, Apple gives us a user identifier and (if you share) your name and a relay email. Apple's policy: https://www.apple.com/legal/privacy/

We have no other third-party data processors. We do not share data with advertisers, data brokers, or affiliated entities.

---

## 12. Changes to this policy

When we materially change this policy, we will:

1. Update the **Effective date** at the top.
2. Post a notice in the app the next time you open it.
3. For changes that expand what we collect or how we share it, get your explicit consent before applying the new terms to existing accounts.

Minor wording changes (clarifications, typos, structural cleanup) we will silently update.

---

## 13. Contact

**The Combination Rule**
support@thecombinationrule.com

For privacy-specific requests (access, deletion, portability), put "Privacy request" in the subject line and we will respond within 30 days.
