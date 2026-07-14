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

// Multi-week source of truth. workoutPlans/current stays as a flattened
// snapshot of the program's active week (see workouts/program.ts) so the
// Train tab and existing plan-adjustment code keep reading one doc.
export function trainingProgramPath(userId: string, programId = "current") {
  return `${userRoot(userId)}/trainingPrograms/${programId}`;
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

// Phase 3 Task 3.4 — Audit log for sensitive writes.
// Server-only collection; one doc per event with a UUID id. Lives under
// the user's root so it's wiped automatically on account deletion.
export function auditLogPath(userId: string, eventId: string) {
  return `${userRoot(userId)}/auditLog/${eventId}`;
}

// Phase 3 Task 3.1 — Account deletion tombstone.
// Lives OUTSIDE users/ so it survives the recursive delete of the user's
// data. Holds the deletion timestamp and who requested it; never holds
// any of the deleted data itself.
export function deletedAccountPath(userId: string) {
  return `deletedAccounts/${userId}`;
}

// Phase 2 Task 2.4 — HealthKit ingestion.
// Document ID IS the sampleHash. iOS computes it deterministically from
// {category, startDate, endDate, sourceBundleId, deviceUUID, value} so
// re-ingesting the same HealthKit sample = same path = idempotent write.
export function healthSamplePath(userId: string, sampleHash: string) {
  return `${userRoot(userId)}/healthSamples/${sampleHash}`;
}

// Daily rollup of HealthKit samples for a given UTC date. Rebuilder is a
// separate follow-up; path defined now so consumers can take a dependency.
export function healthContextSummaryPath(userId: string, date: string) {
  return `${userRoot(userId)}/derivedSummaries/healthContext_${date}`;
}
