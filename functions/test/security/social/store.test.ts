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
  acceptSocialInvite,
  claimFriendNudge,
  createSocialInvite,
  friendNudgeRules,
  leaveSocialConnection,
  listSocialFriends,
  normalizeInviteCode,
  publishSocialActivity,
  removeSocialData,
  socialEnabled,
} from "../../../src/social/store.js";
import {
  consentRecordPath,
  profilePath,
  progressSummaryPath,
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

  it("normalizes codes and share links", () => {
    expect(normalizeInviteCode("myo://join/abcd2345")).toBe("ABCD2345");
    expect(normalizeInviteCode(" ABCD-2345 ")).toBe("ABCD2345");
    expect(normalizeInviteCode("ABCD0OIL")).toBeNull();
    expect(normalizeInviteCode(42)).toBeNull();
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
    expect((await listSocialFriends(db, A, TODAY)).map((f) => f.friendId)).toEqual([B]);
    expect((await listSocialFriends(db, B, TODAY)).map((f) => f.friendId)).toEqual([A]);
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

  it("publishes only the shared fields — no weights, injuries or health", async () => {
    await consent(B);
    await publishSocialActivity(db, B, { trainedOn: TODAY, now: NOW, env: ON });
    const data = (await db.doc(socialActivityPath(B)).get()).data()!;
    expect(Object.keys(data).sort()).toEqual([...SOCIAL_ACTIVITY_FIELDS].sort());
    expect(data).toMatchObject({ firstName: "Sam", trainedOn: TODAY, streakWeeks: 2 });
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
    expect(await listSocialFriends(db, A, TODAY)).toEqual([]);
    expect(await listSocialFriends(db, B, TODAY)).toEqual([]);
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
    expect(await listSocialFriends(db, A, TODAY)).toEqual([]);
    expect(await listSocialFriends(db, C, TODAY)).toEqual([]);
    // And with consent gone, nothing republishes.
    expect(await publishSocialActivity(db, B, { trainedOn: TODAY, env: ON })).toBe(false);
  });

  it("coach nudge: needs both consents, a friend who trained today, at most once a day", async () => {
    await consent(A);
    await consent(B);
    await connect(A, B);
    expect(await claimFriendNudge(db, A, TODAY, ON)).toBeNull(); // B hasn't trained
    await publishSocialActivity(db, B, { trainedOn: TODAY, env: ON });
    expect(await claimFriendNudge(db, A, TODAY, {})).toBeNull(); // flag off
    const line = await claimFriendNudge(db, A, TODAY, ON);
    expect(line).toBe("Sam trained today.");
    expect(await claimFriendNudge(db, A, TODAY, ON)).toBeNull(); // once a day
    expect((await db.doc(socialNudgeStatePath(A)).get()).data()?.lastNudgeOn).toBe(TODAY);
    // A revokes: no nudge tomorrow either.
    await consent(A, false);
    expect(await claimFriendNudge(db, A, "2026-11-06", ON)).toBeNull();
  });

  it("nudge rules never carry anything but the line", () => {
    expect(friendNudgeRules(null)).toBeNull();
    const rules = friendNudgeRules("Sam trained today.")!;
    expect(rules).toContain("Sam trained today.");
    expect(rules).toMatch(/Never guess or say anything about their body/);
  });
});
