// Social prototype server logic against the emulator: consent on both
// sides, revocation and account deletion clean up both ways, the coach
// nudge fires at most once a day, and nothing beyond the shared fields is
// ever published.
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteApp, getApps, initializeApp } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import {
  SOCIAL_ACTIVITY_FIELDS,
  SOCIAL_CONSENT_RECORD_ID,
  MAX_ACCEPTS_PER_DAY,
  MAX_FRIENDS,
  acceptSocialInvite,
  createSocialInvite,
  friendNudgeRules,
  leaveSocialConnection,
  listSocialFriends,
  markFriendNudgeUsed,
  markLiveFriendNudgeIfMentioned,
  mentionsFriend,
  normalizeInviteCode,
  peekFriendNudge,
  plausibleToday,
  publishSocialActivity,
  removeSocialData,
  removeSocialDataBestEffort,
  socialEnabled,
} from "../../../src/social/store.js";
import {
  consentRecordPath,
  profilePath,
  progressSummaryPath,
  socialAcceptLimitPath,
  socialActivityPath,
  socialConnectionPath,
  socialNudgeStatePath,
} from "../../../src/paths.js";
import { baseProfile } from "../fixtures/users.js";

const A = "social-user-a";
const B = "social-user-b";
const C = "social-user-c";
const TODAY = "2026-11-05";
const ON = { IRONBOI_SOCIAL_ENABLED: "true" };
const NOW = new Date("2026-11-05T09:00:00.000Z");

let db: Firestore;

async function consent(userId: string, granted = true) {
  await db.doc(consentRecordPath(userId, SOCIAL_CONSENT_RECORD_ID)).set({
    userId,
    recordId: SOCIAL_CONSENT_RECORD_ID,
    category: "social_activity",
    purpose: "Share trained-today and streak with friends",
    granted,
    scope: { read: true, write: false, share: true, retrieval: false },
    policyVersion: "2026-11-05",
  });
}

async function seedUser(userId: string, name: string) {
  await db.doc(profilePath(userId)).set({
    ...baseProfile,
    userId,
    preferredName: name,
    injuriesOrLimitations: ["left knee"],
  });
  await db.doc(progressSummaryPath(userId)).set({ adherence: { streakWeeks: 2 }, bodyWeightKg: 81 });
}

async function connect(inviter: string, friend: string) {
  const { code } = await createSocialInvite(db, inviter, NOW);
  return acceptSocialInvite(db, friend, code, NOW);
}

async function wipe() {
  for (const col of ["socialActivity", "socialConnections", "socialInvites"]) {
    await db.recursiveDelete(db.collection(col));
  }
  for (const u of [A, B, C]) await db.recursiveDelete(db.doc(`users/${u}`));
}

describe("social prototype store", () => {
  beforeAll(() => {
    const app = getApps()[0] ?? initializeApp({ projectId: "demo-ironboi-security" });
    db = getFirestore(app);
  });

  beforeEach(async () => {
    process.env.IRONBOI_SOCIAL_ENABLED = "true";
    await wipe();
    await seedUser(A, "Alex Smith");
    await seedUser(B, "Sam");
    await seedUser(C, "Jo");
  });

  afterAll(async () => {
    delete process.env.IRONBOI_SOCIAL_ENABLED;
    await wipe();
    await Promise.all(getApps().map((a) => deleteApp(a)));
  });

  it("flag is off unless explicitly true", () => {
    expect(socialEnabled({})).toBe(false);
    expect(socialEnabled({ IRONBOI_SOCIAL_ENABLED: "1" })).toBe(false);
    expect(socialEnabled(ON)).toBe(true);
  });

  it("normalizes 12-character codes and share links", () => {
    expect(normalizeInviteCode("myo://join/abcd2345wxyz")).toBe("ABCD2345WXYZ");
    expect(normalizeInviteCode(" ABCD-2345-WXYZ ")).toBe("ABCD2345WXYZ");
    expect(normalizeInviteCode("ABCD2345")).toBeNull(); // old 8-char length
    expect(normalizeInviteCode("ABCD0OIL2345")).toBeNull();
    expect(normalizeInviteCode(42)).toBeNull();
  });

  it("only accepts a 'today' within a day of the server's date", () => {
    expect(plausibleToday("2026-11-05", NOW)).toBe(true);
    expect(plausibleToday("2026-11-04", NOW)).toBe(true);
    expect(plausibleToday("2026-11-06", NOW)).toBe(true);
    expect(plausibleToday("2026-11-02", NOW)).toBe(false);
    expect(plausibleToday("nope", NOW)).toBe(false);
  });

  it("inviting requires the inviter's consent", async () => {
    await expect(createSocialInvite(db, A, NOW)).rejects.toThrow(/social_consent_required/);
  });

  it("accepting requires the friend's consent", async () => {
    await consent(A);
    const { code } = await createSocialInvite(db, A, NOW);
    await expect(acceptSocialInvite(db, B, code, NOW)).rejects.toThrow(/social_consent_required/);
  });

  it("accept makes a mutual connection and the invite is single-use", async () => {
    await consent(A);
    await consent(B);
    await consent(C);
    const { code, link } = await createSocialInvite(db, A, NOW);
    expect(link).toBe(`myo://join/${code}`);
    const result = await acceptSocialInvite(db, B, link, NOW);
    expect(result).toEqual({ friendId: A, firstName: "Alex" });
    expect((await db.doc(socialConnectionPath(A, B)).get()).exists).toBe(true);
    expect((await listSocialFriends(db, A, TODAY, NOW)).map((f) => f.friendId)).toEqual([B]);
    expect((await listSocialFriends(db, B, TODAY, NOW)).map((f) => f.friendId)).toEqual([A]);
    await expect(acceptSocialInvite(db, C, code, NOW)).rejects.toThrow(/invite_not_found/);
  });

  it("refuses your own invite and expired invites", async () => {
    await consent(A);
    await consent(B);
    const { code } = await createSocialInvite(db, A, NOW);
    await expect(acceptSocialInvite(db, A, code, NOW)).rejects.toThrow(/invite_is_yours/);
    const later = new Date(NOW.getTime() + 8 * 86_400_000);
    await expect(acceptSocialInvite(db, B, code, later)).rejects.toThrow(/invite_expired/);
  });

  it("refuses an invite whose sender has since revoked consent", async () => {
    await consent(A);
    await consent(B);
    const { code } = await createSocialInvite(db, A, NOW);
    await consent(A, false);
    await expect(acceptSocialInvite(db, B, code, NOW)).rejects.toThrow(/inviter_left/);
  });

  it("stores only name, day and streak — no ids, times, weights, injuries or health", async () => {
    await consent(B);
    await publishSocialActivity(db, B, { trainedOn: TODAY, now: NOW, env: ON });
    const data = (await db.doc(socialActivityPath(B)).get()).data()!;
    expect(Object.keys(data).sort()).toEqual([...SOCIAL_ACTIVITY_FIELDS].sort());
    expect(data).toEqual({ firstName: "Sam", trainedOn: TODAY, streakWeeks: 2 });
  });

  it("friends get exactly name, trained-today yes/no and streak", async () => {
    await consent(A);
    await consent(B);
    await connect(A, B);
    await publishSocialActivity(db, B, { trainedOn: TODAY, env: ON });
    const [friend] = await listSocialFriends(db, A, TODAY, NOW);
    expect(friend).toEqual({ friendId: B, firstName: "Sam", trainedToday: true, streakWeeks: 2 });
    await expect(listSocialFriends(db, A, "2026-10-01", NOW)).rejects.toThrow(/today_invalid/);
  });

  it("re-checks the friend's consent on every read, even if cleanup was missed", async () => {
    await consent(A);
    await consent(B);
    await connect(A, B);
    await publishSocialActivity(db, B, { trainedOn: TODAY, env: ON });
    await consent(B, false); // e.g. a cleanup that never ran
    expect(await listSocialFriends(db, A, TODAY, NOW)).toEqual([]);
    expect(await peekFriendNudge(db, A, TODAY, ON)).toBeNull();
  });

  it("rate-limits invite accepts, wrong codes included", async () => {
    await consent(B);
    for (let i = 0; i < MAX_ACCEPTS_PER_DAY; i += 1) {
      await expect(acceptSocialInvite(db, B, "ZZZZZZZZZZZZ", NOW)).rejects.toThrow(/invite_not_found/);
    }
    await expect(acceptSocialInvite(db, B, "ZZZZZZZZZZZZ", NOW)).rejects.toThrow(/too_many_invite_attempts/);
    const tomorrow = new Date(NOW.getTime() + 86_400_000);
    await expect(acceptSocialInvite(db, B, "ZZZZZZZZZZZZ", tomorrow)).rejects.toThrow(/invite_not_found/);
    await removeSocialData(db, B);
    expect((await db.doc(socialAcceptLimitPath(B)).get()).exists).toBe(false);
  });

  it("enforces the friend cap on the inviter too", async () => {
    await consent(A);
    await consent(B);
    const batch = db.batch();
    for (let i = 0; i < MAX_FRIENDS; i += 1) {
      batch.set(db.doc(socialConnectionPath(A, `filler-${i}`)), { members: [A, `filler-${i}`].sort(), createdAt: "x" });
    }
    await batch.commit();
    const { code } = await createSocialInvite(db, A, NOW);
    await expect(acceptSocialInvite(db, B, code, NOW)).rejects.toThrow(/inviter_has_too_many_friends/);
    await db.recursiveDelete(db.collection("socialConnections"));
  });

  it("deletion cleanup is best-effort: an error is reported, never thrown", async () => {
    const broken = { batch: () => { throw new Error("boom"); }, collection: () => { throw new Error("boom"); }, doc: () => { throw new Error("boom"); } } as unknown as Firestore;
    const errors: unknown[] = [];
    await expect(removeSocialDataBestEffort(broken, A, (e) => errors.push(e))).resolves.toBeUndefined();
    expect(errors).toHaveLength(1);
  });

  it("publishes nothing without consent or with the flag off", async () => {
    expect(await publishSocialActivity(db, B, { trainedOn: TODAY, env: ON })).toBe(false);
    await consent(B);
    expect(await publishSocialActivity(db, B, { trainedOn: TODAY, env: {} })).toBe(false);
    expect((await db.doc(socialActivityPath(B)).get()).exists).toBe(false);
  });

  it("never moves trainedOn backwards", async () => {
    await consent(B);
    await publishSocialActivity(db, B, { trainedOn: TODAY, env: ON });
    await publishSocialActivity(db, B, { trainedOn: "2026-11-01", env: ON });
    expect((await db.doc(socialActivityPath(B)).get()).data()?.trainedOn).toBe(TODAY);
  });

  it("leave removes the connection both ways", async () => {
    await consent(A);
    await consent(B);
    await connect(A, B);
    await leaveSocialConnection(db, B, A);
    expect(await listSocialFriends(db, A, TODAY, NOW)).toEqual([]);
    expect(await listSocialFriends(db, B, TODAY, NOW)).toEqual([]);
  });

  it("revocation cleanup removes activity, every connection and open invites", async () => {
    await consent(A);
    await consent(B);
    await consent(C);
    await connect(A, B);
    await connect(C, B);
    await createSocialInvite(db, B, NOW);
    // What revokeConsent / recordConsent(granted:false) / deleteAccount run.
    await consent(B, false);
    const removed = await removeSocialData(db, B);
    expect(removed).toEqual({ connections: 2, invites: 1 });
    expect((await db.doc(socialActivityPath(B)).get()).exists).toBe(false);
    expect(await listSocialFriends(db, A, TODAY, NOW)).toEqual([]);
    expect(await listSocialFriends(db, C, TODAY, NOW)).toEqual([]);
    // And with consent gone, nothing republishes.
    expect(await publishSocialActivity(db, B, { trainedOn: TODAY, env: ON })).toBe(false);
  });

  it("coach nudge: needs both consents and a friend who trained today; used only once mentioned", async () => {
    await consent(A);
    await consent(B);
    await connect(A, B);
    expect(await peekFriendNudge(db, A, TODAY, ON)).toBeNull(); // B hasn't trained
    await publishSocialActivity(db, B, { trainedOn: TODAY, env: ON });
    expect(await peekFriendNudge(db, A, TODAY, {})).toBeNull(); // flag off
    const nudge = await peekFriendNudge(db, A, TODAY, ON);
    expect(nudge).toEqual({ line: "Sam trained today.", names: ["Sam"] });
    // A failed or unrelated reply doesn't use up the day.
    expect(await markFriendNudgeUsed(db, A, TODAY, "Let's do squats.", nudge)).toBe(false);
    expect(await peekFriendNudge(db, A, TODAY, ON)).not.toBeNull();
    // Live voice: the turn that says the name uses it.
    expect(await markLiveFriendNudgeIfMentioned(db, A, TODAY, "Sam got a session in — your turn.", ON)).toBe(true);
    expect(await peekFriendNudge(db, A, TODAY, ON)).toBeNull(); // once a day
    expect((await db.doc(socialNudgeStatePath(A)).get()).data()?.lastNudgeOn).toBe(TODAY);
    // A revokes: no nudge tomorrow either.
    await consent(A, false);
    expect(await peekFriendNudge(db, A, "2026-11-06", ON)).toBeNull();
  });

  it("mention matching is whole-word", () => {
    expect(mentionsFriend("sam trained, your turn", ["Sam"])).toBe(true);
    expect(mentionsFriend("Samples of form", ["Sam"])).toBe(false);
    expect(mentionsFriend("A friend trained", ["A friend"])).toBe(false);
  });

  it("nudge rules never carry anything but the line", () => {
    expect(friendNudgeRules(null)).toBeNull();
    const rules = friendNudgeRules({ line: "Sam trained today.", names: ["Sam"] })!;
    expect(rules).toContain("Sam trained today.");
    expect(rules).toMatch(/Never guess or say anything about their body/);
  });
});
