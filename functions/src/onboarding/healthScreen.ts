import { z } from "zod";

// The health screen asked during onboarding (docs/product/flexible-training-
// plan.md §2). It follows the logic of ACSM's 2015 pre-participation
// screening (Riebe et al., MSSE 47:2473): whether someone is active now,
// whether they have known heart, metabolic or kidney disease, and whether
// they have symptoms. The wording is ours, not the PAR-Q+'s, and is pending
// a clinician's review before any public launch. Everything here is
// deterministic, so the screen is testable and the model never decides it.

export const SCREEN_CONDITIONS = [
  "heart",
  "high_blood_pressure",
  "diabetes",
  "kidney",
  "lung",
  "pregnant",
  "postpartum",
  "surgery",
  "osteoporosis",
  "glaucoma",
  "falls",
] as const;

export const HealthScreen = z.object({
  /** regular: most weeks, 30+ minutes on 3+ days, for months. */
  activeNow: z.enum(["regular", "some", "none"]),
  conditions: z.array(z.enum(SCREEN_CONDITIONS)).max(SCREEN_CONDITIONS.length).default([]),
  /** Chest pain, unusual breathlessness, dizziness or fainting, a racing heartbeat when active. */
  symptoms: z.boolean(),
  /** Pregnant, and a doctor said not to exercise or an ACOG absolute contraindication applies. */
  pregnancyContraindication: z.boolean().optional(),
  /** They said a doctor has cleared them to exercise. */
  clearedByDoctor: z.boolean().optional(),
});

export type HealthScreenType = z.infer<typeof HealthScreen>;

export type ScreenOutcome = {
  /** clear: train as planned. moderate: moderate effort only. clearance_needed: no plan until a doctor clears them. */
  status: "clear" | "moderate" | "clearance_needed";
  /** Why clearance is needed, in plain words, for the app to show. */
  reasons: string[];
  /** Notes the coach sees on every turn and the plan builder respects. */
  notes: string[];
};

/** Moderate effort until a doctor clears harder work: the plan starts at the gentlest loads. */
export const MODERATE_NOTE = "Keep effort moderate (you can still talk) until a doctor clears harder work";

const KNOWN_DISEASE = new Set<string>(["heart", "diabetes", "kidney"]);

const CONDITION_NOTES: Record<(typeof SCREEN_CONDITIONS)[number], string> = {
  heart: "Heart condition: moderate effort until a doctor clears harder work",
  diabetes: "Diabetes: watch for low blood sugar and keep fast sugar on hand",
  kidney: "Kidney disease: moderate effort until a doctor clears harder work",
  high_blood_pressure:
    "High blood pressure: no breath-holding or straining, and no head-below-heart positions unless it's well controlled",
  lung: "Lung condition: keep effort conversational, with any prescribed inhaler nearby",
  pregnant:
    "Pregnant: no lying flat on the back for long after the first trimester, no hot or contact exercise, no high-intensity intervals; stop for bleeding, dizziness, chest pain, calf pain or swelling, fluid leakage, or regular contractions",
  postpartum:
    "Had a baby in the last year: rebuild gradually with pelvic-floor-friendly core work, after the doctor's go-ahead",
  surgery: "Surgery or a joint replacement in the last year: follow the surgeon's movement precautions",
  osteoporosis: "Osteoporosis: no loaded or end-range spinal flexion, and no flexion with twisting",
  glaucoma: "Glaucoma: no head-below-heart positions (downward dog, forward folds, inversions)",
  falls: "Fall risk: balance work with a chair or wall for support, progressed slowly",
};

/** Every note the screen can add, so changed answers replace old notes. */
export const ALL_SCREEN_NOTES = new Set<string>([MODERATE_NOTE, ...Object.values(CONDITION_NOTES)]);

export function screenOutcome(screen: HealthScreenType): ScreenOutcome {
  const conditions = new Set(screen.conditions);
  const knownDisease = [...conditions].some((condition) => KNOWN_DISEASE.has(condition));
  const reasons: string[] = [];
  if (screen.symptoms) reasons.push("symptoms when you're active");
  if (knownDisease && screen.activeNow !== "regular") {
    reasons.push("a heart, metabolic or kidney condition, and you're not exercising regularly yet");
  }
  if (conditions.has("pregnant") && screen.pregnancyContraindication) {
    reasons.push("a pregnancy where a doctor's advice comes first");
  }

  const notes = SCREEN_CONDITIONS.filter((condition) => conditions.has(condition)).map((c) => CONDITION_NOTES[c]);
  if (reasons.length > 0 && !screen.clearedByDoctor) {
    return { status: "clearance_needed", reasons, notes };
  }
  if (reasons.length > 0 || conditions.size > 0) {
    return { status: "moderate", reasons, notes: [MODERATE_NOTE, ...notes] };
  }
  return { status: "clear", reasons: [], notes: [] };
}

/** The screen from a draft value, or undefined if it isn't a valid one. */
export function readHealthScreen(value: unknown): HealthScreenType | undefined {
  const parsed = HealthScreen.safeParse(value);
  return parsed.success ? parsed.data : undefined;
}
