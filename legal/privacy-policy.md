# MYO Privacy Policy

**Effective date:** 2026-06-02
**Last updated:** 2026-10-07

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
| **Coach conversation history** | You chat with the coach | Let the coach maintain context across sessions. Each message also records whether you spoke or typed it, and any style preference you set in conversation ("be brief", "be quiet", "calm", "hype me up"), so the coach answers the way you asked. |
| **Memory facts** (e.g., "prefers morning sessions") | Either you tell the coach, or the coach infers them from a chat | Personalize advice. When you tell the coach something worth remembering (an injury, your schedule, equipment you have), it saves it and uses it in later replies. You can see and remove every saved fact in the app under **You → What Coach remembers**, or tell the coach "forget that". Facts the coach infers on its own, rather than from something you said, are marked "proposed" and aren't used until you keep them; unreviewed ones lapse after 14 days. |
| **Voice audio** | You talk to the coach: either a voice conversation (the microphone stays open from when you start it until you end it) or dictating a single message | Convert speech to text using Apple's speech recognition — on your iPhone when it supports on-device recognition, otherwise on Apple's servers under Apple's privacy policy. **The audio itself is never sent to our servers** — only the transcribed text. We do not keep audio. |
| **Coach's spoken replies** | The coach reads its replies aloud in a voice conversation | The **text of each spoken reply** (the coach's words, which can include what you asked about) is sent to Google Cloud Text-to-Speech to produce the audio you hear, under Google Cloud's data-processing terms (https://cloud.google.com/terms/data-processing-addendum), which do not allow Google to use it to train models. |
| **Usage counters** | App activity (number of messages, token counts per day) | Enforce per-user daily caps so one account can't run up an enormous bill or be abused. |
| **Audit log** | Server-side, every consent change, memory write, health-ingest, and spend-cap hit | Internal records of what changed and when. The actual content of what changed is never logged — only a one-way hash. |

We do NOT currently collect:
- **HealthKit data** — the iOS app has no HealthKit integration yet. When we add it (planned), we will ask for explicit permission per data type (steps, heart rate, sleep, body weight, HRV, workouts) before reading anything.
- **Location** — we don't ask for it and don't use it.
- **Contacts, photos, or anything else outside our own app's data**.

Two things stay on your phone and never reach us: a workout you have started but not finished is cached on the device until you finish or discard it, and nothing else is stored locally beyond what iOS keeps for the app. Exercise "watch" links open YouTube in your browser, where Google's privacy policy applies; we don't send YouTube anything about you.

---

## 3. How we use your data

- **To run the coaching feature.** Every chat turn sends what you wrote plus your profile, recent workouts, and confirmed memory facts to a third-party large language model so it can produce a reply. Today that request goes through OpenRouter, which forwards it to Google's Gemini model. Neither is permitted to use your content to train their models.
- **To speak replies aloud.** In a voice conversation, the text of each coach reply is sent to Google Cloud Text-to-Speech, which returns the audio. If the voice service is unavailable or you reach the daily voice limit, your iPhone's built-in voice reads the reply instead and nothing leaves the device.
- **To save your progress.** Workouts, daily checks, and your custom plan are stored so you can see them across devices and sessions.
- **To enforce safety limits.** Per-user daily caps on messages, model tokens, and spoken-reply characters prevent abuse. Hitting a cap is recorded in your audit log.
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
| **Proposed memory facts** (coach-inferred, not yet confirmed) | 14 days from creation. After that they are no longer shown or used, and they are erased with the rest of your account. |
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
- **Right to correct.** Most fields are editable in-app (profile, workouts). For coach memory, you can see every saved fact and keep or remove it under You → What Coach remembers. A removed fact stops being used immediately.
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

- **Google LLC** (Firebase / Google Cloud) — hosts our database, authentication, and serverless functions, and converts the coach's spoken replies to audio (Cloud Text-to-Speech). Google's privacy policy: https://policies.google.com/privacy
- **OpenRouter, Inc.** — routes each coach request to the language model that writes the reply. It receives the content of that request (your message plus the context described in section 3). OpenRouter's policy: https://openrouter.ai/privacy
- **Apple Inc.** — when you Sign In with Apple, Apple gives us a user identifier and (if you share) your name and a relay email. When your iPhone cannot recognize speech on-device, Apple processes your voice audio for speech recognition; that audio goes from your phone to Apple, never through us. Apple's policy: https://www.apple.com/legal/privacy/

We have no other third-party data processors. Google LLC also serves the Gemini model that OpenRouter forwards requests to. We do not share data with advertisers, data brokers, or affiliated entities.

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
