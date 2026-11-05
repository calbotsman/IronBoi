// Social prototype rules: friends get nothing from Firestore directly (the
// callable re-checks consent and returns yes/no + streak); clients can't
// write any social doc, nor their social consent record (so revoking always
// runs the cleanup).
import { collection, deleteDoc, doc, getDoc, getDocs, setDoc } from "firebase/firestore";
import { afterAll, beforeEach, describe, it } from "vitest";
import {
  assertFails,
  assertSucceeds,
  authedDb,
  cleanupTestEnv,
  clearFirestore,
  unauthedDb,
  withAdminDb,
} from "../fixtures/emulator.js";
import { USER_A, USER_B, baseProfile } from "../fixtures/users.js";

const USER_C = "test-user-c";
const pair = [USER_A, USER_B].sort().join("_");
const activity = (_userId: string, extra: Record<string, unknown> = {}) => ({
  firstName: "Sam",
  trainedOn: "2026-11-05",
  streakWeeks: 3,
  ...extra,
});

async function seed({ connected = true, bExtra = {} as Record<string, unknown> } = {}) {
  await withAdminDb(async (admin) => {
    await setDoc(doc(admin, `socialActivity/${USER_B}`), activity(USER_B, bExtra));
    await setDoc(doc(admin, `socialActivity/${USER_C}`), activity(USER_C));
    if (connected) {
      await setDoc(doc(admin, `socialConnections/${pair}`), { members: [USER_A, USER_B].sort(), createdAt: "x" });
    }
    await setDoc(doc(admin, `socialInvites/ABCDEFGH`), { inviterId: USER_B, createdAt: "x", expiresAt: "y" });
    await setDoc(doc(admin, `users/${USER_B}/profile/current`), { ...baseProfile, userId: USER_B });
    await setDoc(doc(admin, `users/${USER_B}/workoutLogs/l1`), { userId: USER_B, sessionId: "l1" });
    await setDoc(doc(admin, `users/${USER_B}/healthSamples/h1`), { category: "body_weight_kg", value: 80 });
    await setDoc(doc(admin, `users/${USER_B}/exerciseBaselines/bench`), { weightKg: 100 });
    await setDoc(doc(admin, `users/${USER_B}/memoryFacts/f1`), { text: "knee injury" });
  });
}

describe("social rules", () => {
  beforeEach(async () => {
    await clearFirestore();
  });

  afterAll(async () => {
    await cleanupTestEnv();
  });

  it("connected_friend_cannot_read_activity_directly", async () => {
    await seed();
    await assertFails(getDoc(doc(await authedDb(USER_A), `socialActivity/${USER_B}`)));
  });

  it("owner_can_read_own_activity", async () => {
    await seed();
    await assertSucceeds(getDoc(doc(await authedDb(USER_B), `socialActivity/${USER_B}`)));
  });

  it("stranger_cannot_read_activity", async () => {
    await seed();
    await assertFails(getDoc(doc(await authedDb(USER_A), `socialActivity/${USER_C}`)));
  });

  it("unconnected_user_cannot_read_activity", async () => {
    await seed({ connected: false });
    await assertFails(getDoc(doc(await authedDb(USER_A), `socialActivity/${USER_B}`)));
  });

  it("unauthenticated_cannot_read_activity", async () => {
    await seed();
    await assertFails(getDoc(doc(await unauthedDb(), `socialActivity/${USER_B}`)));
  });

  it("friend_read_denied_whatever_the_doc_holds", async () => {
    for (const extra of [{}, { weightKg: 80 }, { injuries: ["knee"] }]) {
      await clearFirestore();
      await seed({ bExtra: extra });
      await assertFails(getDoc(doc(await authedDb(USER_A), `socialActivity/${USER_B}`)));
    }
  });

  it("client_cannot_write_social_consent_directly", async () => {
    const db = await authedDb(USER_A);
    const record = {
      userId: USER_A,
      recordId: "social_activity_v1",
      category: "social_activity",
      purpose: "x",
      granted: false,
      scope: { read: true, write: false, share: true, retrieval: false },
      policyVersion: "v",
    };
    await assertFails(setDoc(doc(db, `users/${USER_A}/consentRecords/social_activity_v1`), record));
    // Same category under another id is refused too.
    await assertFails(setDoc(doc(db, `users/${USER_A}/consentRecords/other`), { ...record, recordId: "other" }));
    // And an existing social record can't be overwritten into something else.
    await withAdminDb(async (admin) => setDoc(doc(admin, `users/${USER_A}/consentRecords/legacy`), { ...record, recordId: "legacy", granted: true }));
    await assertFails(setDoc(doc(db, `users/${USER_A}/consentRecords/legacy`), { ...record, recordId: "legacy", category: "profile" }));
    // Other consent categories still work as before.
    await assertSucceeds(setDoc(doc(db, `users/${USER_A}/consentRecords/p1`), { ...record, recordId: "p1", category: "profile" }));
  });

  it("friend_cannot_list_activity_collection", async () => {
    await seed();
    await assertFails(getDocs(collection(await authedDb(USER_A), "socialActivity")));
  });

  it("connection_grants_nothing_under_the_friends_user_tree", async () => {
    await seed();
    const db = await authedDb(USER_A);
    for (const path of [
      `users/${USER_B}`,
      `users/${USER_B}/profile/current`,
      `users/${USER_B}/workoutLogs/l1`,
      `users/${USER_B}/healthSamples/h1`,
      `users/${USER_B}/exerciseBaselines/bench`,
      `users/${USER_B}/memoryFacts/f1`,
    ]) {
      await assertFails(getDoc(doc(db, path)));
    }
  });

  it("clients_cannot_write_social_docs", async () => {
    await seed();
    const db = await authedDb(USER_A);
    await assertFails(setDoc(doc(db, `socialActivity/${USER_A}`), activity(USER_A)));
    await assertFails(setDoc(doc(db, `socialActivity/${USER_B}`), activity(USER_B, { streakWeeks: 0 })));
    await assertFails(setDoc(doc(db, `socialConnections/${[USER_A, USER_C].sort().join("_")}`), { members: [USER_A, USER_C] }));
    await assertFails(deleteDoc(doc(db, `socialConnections/${pair}`)));
    await assertFails(setDoc(doc(db, `socialInvites/ZZZZZZZZ`), { inviterId: USER_A }));
  });

  it("members_can_read_their_connection_but_others_cannot", async () => {
    await seed();
    await assertSucceeds(getDoc(doc(await authedDb(USER_A), `socialConnections/${pair}`)));
    await assertFails(getDoc(doc(await authedDb(USER_C), `socialConnections/${pair}`)));
  });

  it("invites_are_unreadable_even_by_the_inviter", async () => {
    await seed();
    await assertFails(getDoc(doc(await authedDb(USER_B), "socialInvites/ABCDEFGH")));
    await assertFails(getDoc(doc(await authedDb(USER_A), "socialInvites/ABCDEFGH")));
  });
});
