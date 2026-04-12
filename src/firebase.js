import { initializeApp } from "firebase/app";
import { getAuth, GoogleAuthProvider, signInWithPopup, signOut } from "firebase/auth";
import { getFirestore, doc, getDoc, setDoc } from "firebase/firestore";

const firebaseConfig = {
  apiKey: "AIzaSyCil4Bny7uZB_ea1mQJC8QT-qJ39kQRnXc",
  authDomain: "ironboi-ac586.firebaseapp.com",
  projectId: "ironboi-ac586",
  storageBucket: "ironboi-ac586.firebasestorage.app",
  messagingSenderId: "757563087947",
  appId: "1:757563087947:web:00d74abba7f789695301ce",
};

const app = initializeApp(firebaseConfig);
export const auth = getAuth(app);
export const db = getFirestore(app);

const googleProvider = new GoogleAuthProvider();

export const signInWithGoogle = () => signInWithPopup(auth, googleProvider);
export const logOut = () => signOut(auth);

// ── Firestore helpers ──
const userDoc = (uid, collection) => doc(db, "users", uid, "data", collection);

export const loadData = async (uid, key) => {
  const snap = await getDoc(userDoc(uid, key));
  return snap.exists() ? snap.data() : null;
};

export const saveData = (uid, key, data) =>
  setDoc(userDoc(uid, key), data, { merge: true });
