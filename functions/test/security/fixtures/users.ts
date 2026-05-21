export const USER_A = "test-user-a";
export const USER_B = "test-user-b";

export const baseProfile = {
  userId: USER_A,
  ageYears: 38,
  sexOrGender: "male",
  goals: ["muscle_gain"],
  trainingExperience: "intermediate",
  injuriesOrLimitations: [],
  equipment: ["barbell"],
  schedule: { daysPerWeek: 4, preferredDays: [], sessionLengthMin: 45 },
  preferences: {
    coachingTone: "balanced",
    preferredWorkoutTime: "flexible",
    dislikedExercises: [],
  },
  dietaryConstraints: [],
  createdAt: "2026-05-08T00:00:00.000Z",
  updatedAt: "2026-05-08T00:00:00.000Z",
};

export function withUserId<T extends Record<string, unknown>>(value: T, userId: string) {
  return { ...value, userId };
}
