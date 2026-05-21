import { initializeApp } from "firebase/app";
import {
  getAuth,
  OAuthProvider,
  onAuthStateChanged,
  signInWithPopup,
  signOut as firebaseSignOut,
} from "firebase/auth";
import { getFunctions, httpsCallable } from "firebase/functions";
import {
  collection,
  getFirestore,
  onSnapshot,
  orderBy,
  query,
} from "firebase/firestore";

const firebaseConfig = {
  apiKey: import.meta.env.VITE_FIREBASE_API_KEY,
  authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN,
  projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID,
  appId: import.meta.env.VITE_FIREBASE_APP_ID,
  messagingSenderId: import.meta.env.VITE_FIREBASE_MESSAGING_SENDER_ID,
};

export const firebaseConfigured = Boolean(
  firebaseConfig.apiKey &&
    firebaseConfig.authDomain &&
    firebaseConfig.projectId &&
    firebaseConfig.appId,
);

const app = firebaseConfigured ? initializeApp(firebaseConfig) : null;
export const auth = app ? getAuth(app) : null;
const functions = app ? getFunctions(app, "us-central1") : null;
const firestore = app ? getFirestore(app) : null;

export function subscribeAuth(callback) {
  if (!auth) {
    callback(null);
    return () => {};
  }
  return onAuthStateChanged(auth, callback);
}

export async function signInWithApple() {
  if (!auth) throw new Error("Firebase is not configured.");
  const provider = new OAuthProvider("apple.com");
  provider.addScope("email");
  provider.addScope("name");
  return signInWithPopup(auth, provider);
}

export async function signOut() {
  if (!auth) return;
  await firebaseSignOut(auth);
}

export async function callFunction(name, payload = {}) {
  if (!functions) throw new Error("Firebase is not configured.");
  const callable = httpsCallable(functions, name);
  const result = await callable(payload);
  return result.data;
}

export function subscribeCoachMessages(userId, sessionId, callback) {
  if (!firestore || !userId || !sessionId) {
    callback([]);
    return () => {};
  }

  const messagesQuery = query(
    collection(
      firestore,
      "users",
      userId,
      "coachSessions",
      sessionId,
      "messages",
    ),
    orderBy("serverCreatedAt", "asc"),
  );

  return onSnapshot(
    messagesQuery,
    (snapshot) => {
      callback(snapshot.docs.map((doc) => ({ id: doc.id, ...doc.data() })));
    },
    (error) => {
      callback([], error);
    },
  );
}
