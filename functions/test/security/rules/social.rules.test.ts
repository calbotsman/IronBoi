// Social prototype rules: a friend can read ONLY socialActivity/{friend},
// only while connected, and only when the doc holds the shared fields.
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
const activity = (userId: string, extra: Record<string, unknown> = {}) => ({
  userId,
  firstName: "Sam",
  trainedOn: "2026-11-05",
  streakWeeks: 3,
  updatedAt: "2026-11-05T09:00:00.000Z",
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

  it("connected_friend_can_read_shared_activity", async () => {
    await seed();
    await assertSucceeds(getDoc(doc(await authedDb(USER_A), `socialActivity/${USER_B}`)));
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

  it("friend_read_denied_when_doc_holds_any_field_beyond_the_shared_set", async () => {
    for (const extra of [{ weightKg: 80 }, { injuries: ["knee"] }, { restingHeartRate: 52 }, { lastWorkout: {} }]) {
      await clearFirestore();
      await seed({ bExtra: extra });
      await assertFails(getDoc(doc(await authedDb(USER_A), `socialActivity/${USER_B}`)));
    }
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

  it("after_leave_the_friend_loses_access", async () => {
    await seed();
    await withAdminDb(async (admin) => deleteDoc(doc(admin, `socialConnections/${pair}`)));
    await assertFails(getDoc(doc(await authedDb(USER_A), `socialActivity/${USER_B}`)));
  });
});
