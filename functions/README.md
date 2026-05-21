# IronBoi Firebase Functions

This package is the first backend scaffold for IronBoi Coach.

The original IronBoi app is a React PWA with `localStorage` persistence. There
was no server to reuse. This package starts the server-side brain:

- Firebase Auth is the intended user identity layer.
- Firestore is the canonical store for profiles, memory facts, workouts,
  metrics, sessions, and consent records.
- Cloud Functions validate all user writes with Zod before Firestore writes.
- The PWA's exercise library, muscle map, swap logic, default plan, daily
  habits, and philosophy content are extracted as seed data, not treated as
  infrastructure.

## Validate

```bash
npm run validate:phase0
```

## Current Callable Functions

- `getCoachBootstrap` - authenticated bootstrap payload with coach policy and
  Iron Lab seed data.
- `upsertProfile` - validates and writes `UserHealthProfile`.
- `recordConsent` - validates and writes `ConsentRecord`.
- `logWorkout` - validates and writes `WorkoutLog`.
- `upsertMemoryFact` - validates and writes inspectable coach memory facts.
- `deleteMemoryFact` - soft-deletes a user memory fact.
- `revokeConsent` - records consent revocation.
- `createCoachSession` - creates a user-scoped coach session.
- `sendCoachMessage` - writes a queued user message under the session.
- `onUserCoachMessageCreated` - Firestore trigger for coach turns. It writes a
  placeholder coach response today; Anthropic orchestration plugs into this
  trigger next.
- `recordSafetyEvalResult` - records release-gate safety eval results. Requires
  an authenticated user with the custom claim `{ admin: true }`.

## Chat Data Flow

The chat path is Firestore-first rather than SSE-first:

1. Client calls `createCoachSession`.
2. Client calls `sendCoachMessage`.
3. The message lands at
   `users/{userId}/coachSessions/{sessionId}/messages/{messageId}`.
4. `onUserCoachMessageCreated` reacts to user messages and writes coach
   message docs back into the same subcollection.
5. iOS / PWA subscribes to the messages subcollection with a snapshot listener.

This keeps the mobile client offline-tolerant and gives the future coach
orchestrator one durable queue point.

Firestore rules allow clients to create only `role: "user"` message docs and
deny client updates/deletes. Coach messages are server-authored through the
Admin SDK, so clients cannot forge `role: "coach"` responses.

## Regenerate Seed Data

From the repo root:

```bash
node scripts/extract-ironlab-domain.mjs
```

## Not Implemented Yet

- Firebase project provisioning.
- Production Firebase env values in the root `.env.local`.
- Firestore migrations or backfill from existing `localStorage`.
- LLM/coach orchestration.
- Corpus retrieval.
- HealthKit ingestion.
