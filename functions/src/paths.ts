export function userRoot(userId: string) {
  return `users/${userId}`;
}

export function profilePath(userId: string) {
  return `${userRoot(userId)}/profile/current`;
}

export function workoutLogPath(userId: string, sessionId: string) {
  return `${userRoot(userId)}/workoutLogs/${sessionId}`;
}

export function workoutPlanPath(userId: string, planId = "current") {
  return `${userRoot(userId)}/workoutPlans/${planId}`;
}

export function dailyCheckPath(userId: string, date: string) {
  return `${userRoot(userId)}/dailyChecks/${date}`;
}

export function activeWorkoutPath(userId: string) {
  return `${userRoot(userId)}/activeWorkout/current`;
}

export function workoutSessionPath(userId: string, sessionId: string) {
  return `${userRoot(userId)}/workoutSessions/${sessionId}`;
}

export function memoryFactPath(userId: string, factId: string) {
  return `${userRoot(userId)}/memoryFacts/${factId}`;
}

export function metricSnapshotPath(userId: string, snapshotId: string) {
  return `${userRoot(userId)}/metricSnapshots/${snapshotId}`;
}

export function consentRecordPath(userId: string, recordId: string) {
  return `${userRoot(userId)}/consentRecords/${recordId}`;
}

export function usagePath(userId: string, date: string) {
  return `${userRoot(userId)}/usage/${date}`;
}

export function programProposalPath(userId: string, proposalId: string) {
  return `${userRoot(userId)}/programProposals/${proposalId}`;
}

export function planAdjustmentProposalPath(userId: string, proposalId: string) {
  return `${userRoot(userId)}/planAdjustmentProposals/${proposalId}`;
}

export function coachSessionPath(userId: string, sessionId: string) {
  return `${userRoot(userId)}/coachSessions/${sessionId}`;
}

export function coachSessionMessagePath(
  userId: string,
  sessionId: string,
  messageId: string,
) {
  return `${coachSessionPath(userId, sessionId)}/messages/${messageId}`;
}
