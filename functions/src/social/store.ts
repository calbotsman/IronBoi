// Social prototype — "train with friends", opt in, invisible if you don't.
// docs/product/social-prototype.md has the product shape; this is the data.
//
// Privacy contract (enforced here AND in firestore.rules):
//   - A friend can only ever read socialActivity/{uid}: first name, the last
//     day you trained, your weekly streak. Never bodies, weights, injuries,
//     health samples, plans or chat.
//   - socialActivity/{uid} exists only while uid's social consent is granted.
//     Revoking consent, turning social off, or deleting the account removes
//     it, every connection both ways, and any open invite.
//   - Connections need consent from both sides: the inviter consented to
//     create the invite, the friend consents before accepting.
//   - Everything is server-written; the client has no write path.
import { randomInt } from "node:crypto";
import type { DocumentData, Firestore } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import {
  consentRecordPath,
  profilePath,
  progressSummaryPath,
  socialActivityPath,
  socialConnectionPath,
  socialInvitePath,
  socialNudgeStatePath,
  socialPairId,
} from "../paths.js";

/** Off by default: every social callable refuses until this is "true". */
export function socialEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.IRONBOI_SOCIAL_ENABLED === "true";
}

export function requireSocialEnabled(env: NodeJS.ProcessEnv = process.env) {
  if (!socialEnabled(env)) throw new HttpsError("failed-precondition", "social_disabled");
}

/** The consent record the app writes through recordConsent / revokeConsent. */
export const SOCIAL_CONSENT_RECORD_ID = "social_activity_v1";
export const SOCIAL_CONSENT_CATEGORY = "social_activity";

/** Fields a friend may read. firestore.rules repeats this list. */
export const SOCIAL_ACTIVITY_FIELDS = ["userId", "firstName", "trainedOn", "streakWeeks", "updatedAt"] as const;

const INVITE_TTL_DAYS = 7;
const MAX_FRIENDS = 20;
// No 0/O/1/I/L: codes get read aloud and typed.
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const CODE_LENGTH = 8;

export function generateInviteCode(): string {
  let code = "";
  for (let i = 0; i < CODE_LENGTH; i += 1) code += CODE_ALPHABET[randomInt(CODE_ALPHABET.length)];
  return code;
}

export function normalizeInviteCode(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  // Accept the bare code or the whole share link (myo://join/CODE).
  const tail = raw.trim().split(/[/=]/).pop() ?? "";
  const code = tail.toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (code.length !== CODE_LENGTH) return null;
  for (const ch of code) if (!CODE_ALPHABET.includes(ch)) return null;
  return code;
}

/** First word of the preferred name, letters only, ≤ 20 chars. */
export function firstNameFrom(profile: DocumentData | undefined): string {
  const raw = typeof profile?.preferredName === "string" ? profile.preferredName : "";
  const first = raw.trim().split(/\s+/)[0] ?? "";
  const clean = first.replace(/[^\p{L}'-]/gu, "").slice(0, 20);
  return clean || "A friend";
}

export async function hasSocialConsent(db: Firestore, userId: string): Promise<boolean> {
  const snap = await db.doc(consentRecordPath(userId, SOCIAL_CONSENT_RECORD_ID)).get();
  const data = snap.data();
  return Boolean(snap.exists && data?.granted === true && data?.category === SOCIAL_CONSENT_CATEGORY);
}

async function requireConsent(db: Firestore, userId: string) {
  if (!(await hasSocialConsent(db, userId))) {
    throw new HttpsError("failed-precondition", "social_consent_required");
  }
}

async function connectedFriendIds(db: Firestore, userId: string): Promise<string[]> {
  const snap = await db.collection("socialConnections").where("members", "array-contains", userId).get();
  return snap.docs
    .map((doc) => (doc.data().members as unknown[] | undefined)?.find((m) => m !== userId))
    .filter((m): m is string => typeof m === "string");
}

/**
 * Write (or refresh) the user's shareable activity. A no-op without consent.
 * `trainedOn` is the user's calendar date of the workout that just landed.
 */
export async function publishSocialActivity(
  db: Firestore,
  userId: string,
  opts: { trainedOn?: string; now?: Date; env?: NodeJS.ProcessEnv } = {},
): Promise<boolean> {
  if (!socialEnabled(opts.env)) return false;
  if (!(await hasSocialConsent(db, userId))) return false;
  const ref = db.doc(socialActivityPath(userId));
  const [profileSnap, progressSnap, existing] = await Promise.all([
    db.doc(profilePath(userId)).get(),
    db.doc(progressSummaryPath(userId)).get(),
    ref.get(),
  ]);
  const streak = progressSnap.data()?.adherence?.streakWeeks;
  const previous = existing.data()?.trainedOn;
  const trainedOn =
    opts.trainedOn && (typeof previous !== "string" || opts.trainedOn > previous) ? opts.trainedOn : previous;
  const doc: Record<string, unknown> = {
    userId,
    firstName: firstNameFrom(profileSnap.data()),
    streakWeeks: typeof streak === "number" && Number.isFinite(streak) ? Math.max(0, Math.floor(streak)) : 0,
    updatedAt: (opts.now ?? new Date()).toISOString(),
  };
  if (typeof trainedOn === "string" && /^\d{4}-\d{2}-\d{2}$/.test(trainedOn)) doc.trainedOn = trainedOn;
  // set() without merge: the doc can never accumulate a field outside the list.
  await ref.set(doc);
  return true;
}

export async function createSocialInvite(db: Firestore, userId: string, now = new Date()) {
  await requireConsent(db, userId);
  // One open invite per person: a new one replaces the old.
  const open = await db.collection("socialInvites").where("inviterId", "==", userId).get();
  const batch = db.batch();
  open.docs.forEach((doc) => batch.delete(doc.ref));
  const code = generateInviteCode();
  const expiresAt = new Date(now.getTime() + INVITE_TTL_DAYS * 86_400_000).toISOString();
  batch.create(db.doc(socialInvitePath(code)), { inviterId: userId, createdAt: now.toISOString(), expiresAt });
  await batch.commit();
  await publishSocialActivity(db, userId, { now, env: { IRONBOI_SOCIAL_ENABLED: "true" } });
  return { code, link: `myo://join/${code}`, expiresAt };
}

export async function acceptSocialInvite(db: Firestore, userId: string, rawCode: unknown, now = new Date()) {
  const code = normalizeInviteCode(rawCode);
  if (!code) throw new HttpsError("invalid-argument", "invite_code_invalid");
  await requireConsent(db, userId);

  const inviteRef = db.doc(socialInvitePath(code));
  const result = await db.runTransaction(async (tx) => {
    const invite = await tx.get(inviteRef);
    const data = invite.data();
    if (!invite.exists || typeof data?.inviterId !== "string") throw new HttpsError("not-found", "invite_not_found");
    if (typeof data.expiresAt !== "string" || data.expiresAt < now.toISOString()) {
      tx.delete(inviteRef);
      return { expired: true as const };
    }
    const inviterId = data.inviterId;
    if (inviterId === userId) throw new HttpsError("failed-precondition", "invite_is_yours");
    // The inviter may have turned social off since sending it.
    const inviterConsent = await tx.get(db.doc(consentRecordPath(inviterId, SOCIAL_CONSENT_RECORD_ID)));
    const ic = inviterConsent.data();
    if (!(ic?.granted === true && ic?.category === SOCIAL_CONSENT_CATEGORY)) {
      tx.delete(inviteRef);
      throw new HttpsError("failed-precondition", "inviter_left");
    }
    const mine = await tx.get(db.collection("socialConnections").where("members", "array-contains", userId));
    if (mine.size >= MAX_FRIENDS) throw new HttpsError("resource-exhausted", "too_many_friends");
    tx.set(db.doc(socialConnectionPath(userId, inviterId)), {
      members: [userId, inviterId].sort(),
      createdAt: now.toISOString(),
    });
    // Single-use.
    tx.delete(inviteRef);
    return { expired: false as const, inviterId };
  });
  if (result.expired) throw new HttpsError("deadline-exceeded", "invite_expired");

  const enabled = { IRONBOI_SOCIAL_ENABLED: "true" };
  await Promise.all([
    publishSocialActivity(db, userId, { now, env: enabled }),
    publishSocialActivity(db, result.inviterId, { now, env: enabled }),
  ]);
  const inviter = await db.doc(socialActivityPath(result.inviterId)).get();
  return { friendId: result.inviterId, firstName: (inviter.data()?.firstName as string | undefined) ?? "A friend" };
}

/** "Leave": removes the connection for both people. */
export async function leaveSocialConnection(db: Firestore, userId: string, friendId: unknown) {
  if (typeof friendId !== "string" || friendId.length === 0 || friendId === userId) {
    throw new HttpsError("invalid-argument", "friend_id_invalid");
  }
  await db.doc(socialConnectionPath(userId, friendId)).delete();
  return { ok: true as const };
}

export type SocialFriend = { friendId: string; firstName: string; trainedToday: boolean; streakWeeks: number };

/** The friend list for the You tab: only the shared fields, never more. */
export async function listSocialFriends(db: Firestore, userId: string, today: string): Promise<SocialFriend[]> {
  if (!(await hasSocialConsent(db, userId))) return [];
  const ids = await connectedFriendIds(db, userId);
  const docs = await Promise.all(ids.map((id) => db.doc(socialActivityPath(id)).get()));
  return docs.map((snap, i) => {
    const d = snap.data();
    return {
      friendId: ids[i],
      firstName: typeof d?.firstName === "string" ? d.firstName : "A friend",
      trainedToday: d?.trainedOn === today,
      streakWeeks: typeof d?.streakWeeks === "number" ? d.streakWeeks : 0,
    };
  });
}

/**
 * Everything social about one person, gone: their activity, every
 * connection (both ways), open invites, nudge state. Used by revokeConsent,
 * deleteAccount and resetMyData. Runs whether or not the flag is on, so a
 * flag flipped off later can never strand data.
 */
export async function removeSocialData(db: Firestore, userId: string) {
  const [connections, invites] = await Promise.all([
    db.collection("socialConnections").where("members", "array-contains", userId).get(),
    db.collection("socialInvites").where("inviterId", "==", userId).get(),
  ]);
  const batch = db.batch();
  connections.docs.forEach((doc) => batch.delete(doc.ref));
  invites.docs.forEach((doc) => batch.delete(doc.ref));
  batch.delete(db.doc(socialActivityPath(userId)));
  batch.delete(db.doc(socialNudgeStatePath(userId)));
  await batch.commit();
  return { connections: connections.size, invites: invites.size };
}

/**
 * One line the coach may use, at most once per calendar day: a friend who
 * trained today. Claims the day atomically, so a second turn gets nothing.
 * Returns null when social is off, either side lacks consent, or no friend
 * trained today.
 */
export async function claimFriendNudge(
  db: Firestore,
  userId: string,
  today: string,
  env: NodeJS.ProcessEnv = process.env,
): Promise<string | null> {
  if (!socialEnabled(env)) return null;
  try {
    if (!(await hasSocialConsent(db, userId))) return null;
    const stateRef = db.doc(socialNudgeStatePath(userId));
    const state = await stateRef.get();
    if (state.data()?.lastNudgeOn === today) return null;
    const ids = await connectedFriendIds(db, userId);
    if (ids.length === 0) return null;
    const docs = await Promise.all(ids.map((id) => db.doc(socialActivityPath(id)).get()));
    const trained = docs.map((d) => d.data()).filter((d) => d?.trainedOn === today);
    if (trained.length === 0) return null;
    const pick = trained[0]!;
    const claimed = await db.runTransaction(async (tx) => {
      const fresh = await tx.get(stateRef);
      if (fresh.data()?.lastNudgeOn === today) return false;
      tx.set(stateRef, { lastNudgeOn: today, pairId: socialPairId(userId, String(pick.userId)) });
      return true;
    });
    if (!claimed) return null;
    const name = typeof pick.firstName === "string" ? pick.firstName : "A friend";
    const others = trained.length - 1;
    return others > 0 ? `${name} and ${others} other friend${others === 1 ? "" : "s"} trained today.` : `${name} trained today.`;
  } catch {
    // Social is garnish: a failed read must never break a coach turn.
    return null;
  }
}

/** System-prompt block for the nudge; empty when there is none. */
export function friendNudgeRules(line: string | null): string | null {
  if (!line) return null;
  return [
    "Friends (the user opted in to training with friends):",
    `- Today: ${line}`,
    "- You may mention this once, naturally and briefly, if it fits — e.g. \"Sam got a session in today — your turn.\" Skip it if the user is in pain, upset, or mid-set.",
    "- You know nothing else about the friend. Never guess or say anything about their body, weight, workouts, injuries or health, and never compare the user to them.",
  ].join("\n");
}
