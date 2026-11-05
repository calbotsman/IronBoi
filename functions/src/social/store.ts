// Social prototype — "train with friends", opt in, invisible if you don't.
// docs/product/social-prototype.md has the product shape; this is the data.
//
// Privacy contract (enforced here AND in firestore.rules):
//   - Friends never read Firestore directly. The getSocialFriends callable
//     and the coach nudge return only first name, "trained today" yes/no and
//     the weekly streak — never a date, time, user id, body, weight, injury,
//     health sample, plan or chat. socialActivity/{uid} (which holds the
//     date that "today" is computed from) is readable by its owner only.
//   - Every read re-checks BOTH people's current consent, so a stale doc or
//     a missed cleanup can never leak.
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
  socialAcceptLimitPath,
  socialNudgeStatePath,
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

/** Every field socialActivity/{uid} may hold (owner-readable only). */
export const SOCIAL_ACTIVITY_FIELDS = ["firstName", "trainedOn", "streakWeeks"] as const;

const INVITE_TTL_DAYS = 7;
export const MAX_FRIENDS = 20;
// No 0/O/1/I/L: codes get read aloud and typed. 12 chars ≈ 59 bits.
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
export const CODE_LENGTH = 12;
/** Accept attempts (right or wrong) per person per UTC day. */
export const MAX_ACCEPTS_PER_DAY = 10;

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

function consentGranted(data: DocumentData | undefined): boolean {
  return data?.granted === true && data?.category === SOCIAL_CONSENT_CATEGORY;
}

export async function hasSocialConsent(db: Firestore, userId: string): Promise<boolean> {
  const snap = await db.doc(consentRecordPath(userId, SOCIAL_CONSENT_RECORD_ID)).get();
  return consentGranted(snap.data());
}

/**
 * "Today" as the server will accept it from a phone: within a day of the
 * server's UTC date (every real time zone). Stops a client probing other
 * dates to learn exactly when a friend last trained.
 */
export function plausibleToday(today: string, now = new Date()): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(today)) return false;
  const t = Date.parse(`${today}T12:00:00.000Z`);
  return Number.isFinite(t) && Math.abs(t - now.getTime()) <= 38 * 3_600_000;
}

/** Friends who are connected AND still consent, with their activity. */
async function consentingFriends(db: Firestore, userId: string) {
  const ids = await connectedFriendIds(db, userId);
  const rows = await Promise.all(
    ids.map(async (id) => {
      const [consent, activity] = await Promise.all([
        db.doc(consentRecordPath(id, SOCIAL_CONSENT_RECORD_ID)).get(),
        db.doc(socialActivityPath(id)).get(),
      ]);
      return consentGranted(consent.data()) ? { id, activity: activity.data() } : null;
    }),
  );
  return rows.filter((r): r is { id: string; activity: DocumentData | undefined } => r !== null);
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
  const ref = db.doc(socialActivityPath(userId));
  const consentRef = db.doc(consentRecordPath(userId, SOCIAL_CONSENT_RECORD_ID));
  // Consent is read INSIDE the transaction: a revoke or deleteAccount that
  // writes the consent record concurrently conflicts with this write, so the
  // doc can't be written after the cleanup that should have removed it.
  return db.runTransaction(async (tx) => {
    const [consent, profileSnap, progressSnap, existing] = await Promise.all([
      tx.get(consentRef),
      tx.get(db.doc(profilePath(userId))),
      tx.get(db.doc(progressSummaryPath(userId))),
      tx.get(ref),
    ]);
    if (!consentGranted(consent.data())) return false;
    const streak = progressSnap.data()?.adherence?.streakWeeks;
    const previous = existing.data()?.trainedOn;
    const trainedOn =
      opts.trainedOn && (typeof previous !== "string" || opts.trainedOn > previous) ? opts.trainedOn : previous;
    const doc: Record<string, unknown> = {
      firstName: firstNameFrom(profileSnap.data()),
      streakWeeks: typeof streak === "number" && Number.isFinite(streak) ? Math.max(0, Math.floor(streak)) : 0,
    };
    if (typeof trainedOn === "string" && /^\d{4}-\d{2}-\d{2}$/.test(trainedOn)) doc.trainedOn = trainedOn;
    // set() without merge: the doc can never accumulate a field outside the list.
    tx.set(ref, doc);
    return true;
  });
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
  await requireConsent(db, userId);
  // Every attempt counts, right or wrong, so codes can't be guessed.
  await countAcceptAttempt(db, userId, now);
  const code = normalizeInviteCode(rawCode);
  if (!code) throw new HttpsError("invalid-argument", "invite_code_invalid");

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
    const [mine, theirs] = await Promise.all([
      tx.get(db.collection("socialConnections").where("members", "array-contains", userId)),
      tx.get(db.collection("socialConnections").where("members", "array-contains", inviterId)),
    ]);
    if (mine.size >= MAX_FRIENDS) throw new HttpsError("resource-exhausted", "too_many_friends");
    if (theirs.size >= MAX_FRIENDS) throw new HttpsError("resource-exhausted", "inviter_has_too_many_friends");
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
  const inviter = await db.doc(profilePath(result.inviterId)).get();
  return { friendId: result.inviterId, firstName: firstNameFrom(inviter.data()) };
}

async function countAcceptAttempt(db: Firestore, userId: string, now: Date) {
  const day = now.toISOString().slice(0, 10);
  const ref = db.doc(socialAcceptLimitPath(userId));
  const allowed = await db.runTransaction(async (tx) => {
    const data = (await tx.get(ref)).data();
    const count = data?.day === day && typeof data.count === "number" ? data.count : 0;
    if (count >= MAX_ACCEPTS_PER_DAY) return false;
    tx.set(ref, { day, count: count + 1 });
    return true;
  });
  if (!allowed) throw new HttpsError("resource-exhausted", "too_many_invite_attempts");
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

/** The friend list for the You tab: name, trained today yes/no, streak. */
export async function listSocialFriends(
  db: Firestore,
  userId: string,
  today: string,
  now = new Date(),
): Promise<SocialFriend[]> {
  if (!plausibleToday(today, now)) throw new HttpsError("invalid-argument", "today_invalid");
  if (!(await hasSocialConsent(db, userId))) return [];
  const friends = await consentingFriends(db, userId);
  return friends.map(({ id, activity }) => ({
    friendId: id,
    firstName: typeof activity?.firstName === "string" ? activity.firstName : "A friend",
    trainedToday: activity?.trainedOn === today,
    streakWeeks: typeof activity?.streakWeeks === "number" ? activity.streakWeeks : 0,
  }));
}

/**
 * Everything social about one person, gone: their activity, every
 * connection (both ways), open invites, nudge state. Used by revokeConsent,
 * deleteAccount and resetMyData. Runs whether or not the flag is on, so a
 * flag flipped off later can never strand data. Throws; callers on the
 * account-deletion path use removeSocialDataBestEffort.
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
  batch.delete(db.doc(socialAcceptLimitPath(userId)));
  await batch.commit();
  return { connections: connections.size, invites: invites.size };
}

export type FriendNudge = { line: string; names: string[] };

/**
 * One line the coach may use, at most once per calendar day: friends who
 * trained today. Read-only — the day is marked used by markFriendNudgeUsed
 * only once a delivered coach reply actually mentioned a friend. Null when
 * social is off, either side lacks consent, or no friend trained today.
 */
export async function peekFriendNudge(
  db: Firestore,
  userId: string,
  today: string,
  env: NodeJS.ProcessEnv = process.env,
): Promise<FriendNudge | null> {
  if (!socialEnabled(env)) return null;
  try {
    if (!(await hasSocialConsent(db, userId))) return null;
    const state = await db.doc(socialNudgeStatePath(userId)).get();
    if (state.data()?.lastNudgeOn === today) return null;
    const trained = (await consentingFriends(db, userId)).filter((f) => f.activity?.trainedOn === today);
    if (trained.length === 0) return null;
    const names = trained.map((f) => (typeof f.activity?.firstName === "string" ? f.activity.firstName : "A friend"));
    const others = names.length - 1;
    const line = others > 0
      ? `${names[0]} and ${others} other friend${others === 1 ? "" : "s"} trained today.`
      : `${names[0]} trained today.`;
    return { line, names };
  } catch {
    // Social is garnish: a failed read must never break a coach turn.
    return null;
  }
}

/** True when the coach's words name one of the friends (whole word). */
export function mentionsFriend(coachText: string, names: string[]): boolean {
  return names.some((name) => {
    if (!name || name === "A friend") return false;
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    return new RegExp(`(^|[^\\p{L}])${escaped}($|[^\\p{L}])`, "iu").test(coachText);
  });
}

/**
 * After a coach reply was delivered: if it mentioned a friend, the day's
 * mention is used. Best-effort; never throws.
 */
export async function markFriendNudgeUsed(
  db: Firestore,
  userId: string,
  today: string,
  coachText: string,
  nudge: FriendNudge | null,
): Promise<boolean> {
  if (!nudge || !mentionsFriend(coachText, nudge.names)) return false;
  try {
    await db.doc(socialNudgeStatePath(userId)).set({ lastNudgeOn: today });
    return true;
  } catch {
    return false;
  }
}

/** Live voice: the instruction was built at session start, so the turn
 * recorder re-derives today's nudge and marks it if the coach used it. */
export async function markLiveFriendNudgeIfMentioned(
  db: Firestore,
  userId: string,
  today: string,
  coachText: string,
  env: NodeJS.ProcessEnv = process.env,
): Promise<boolean> {
  if (!coachText || !socialEnabled(env)) return false;
  const nudge = await peekFriendNudge(db, userId, today, env);
  return markFriendNudgeUsed(db, userId, today, coachText, nudge);
}

/** deleteAccount / resetMyData: social cleanup must never block deletion. */
export async function removeSocialDataBestEffort(
  db: Firestore,
  userId: string,
  onError: (error: unknown) => void,
): Promise<void> {
  try {
    await removeSocialData(db, userId);
  } catch (error) {
    onError(error);
  }
}

/** System-prompt block for the nudge; empty when there is none. */
export function friendNudgeRules(nudge: FriendNudge | null): string | null {
  if (!nudge) return null;
  const line = nudge.line;
  return [
    "Friends (the user opted in to training with friends):",
    `- Today: ${line}`,
    "- You may mention this once, naturally and briefly, if it fits — e.g. \"Sam got a session in today — your turn.\" Skip it if the user is in pain, upset, or mid-set.",
    "- You know nothing else about the friend. Never guess or say anything about their body, weight, workouts, injuries or health, and never compare the user to them.",
  ].join("\n");
}
