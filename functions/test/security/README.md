# IronBoi Security Tests

These tests lock the cross-user isolation contract before Coach memory, tools,
and retrieval become more powerful.

## Run

Static/unit security tests, no emulator:

```sh
npm run test:security:static
```

Full suite with Firestore emulator:

```sh
npm run test:security
```

The Firestore emulator requires Java.

## Adding User-Scoped Collections

Add the new test path to `src/firestore/userScopedCollections.ts`, add matching
rules in `../firestore.rules`, then extend `test/security/rules/firestore.rules.test.ts`
if the collection needs special behavior.

## Logging

Agent code must log through `src/logging/safeLogger.ts`. Do not use
`console.log`, `console.warn`, `console.error`, or direct Firebase logger calls
inside `src/coach`, `src/tools`, or `src/agents`.
