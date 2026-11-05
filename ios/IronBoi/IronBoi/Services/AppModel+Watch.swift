import Foundation

/// The workout as the Watch shows it, and what the Watch can do to it.
/// See WatchWorkoutLink.
extension AppModel {
    /// What the Watch shows right now. Nil outside a workout.
    func watchState() -> WatchWorkoutState? {
        guard let workout = activeWorkout else { return nil }
        var state = WatchWorkoutState(
            sessionId: workout.sessionId,
            workoutName: String(workout.workoutName.prefix(80)),
            ageYears: profile.ageYears,
            saveToHealth: HealthSync.shared.enabled)
        if let index = currentExerciseIndex, workout.exercises.indices.contains(index) {
            let exercise = workout.exercises[index]
            state.exercise = String(exercise.name.prefix(80))
            state.totalSets = max(1, exercise.targetSets)
            state.setNumber = max(1, min(exercise.completedSetCount + 1, exercise.targetSets))
            state.targetReps = exercise.targetReps
            state.weightLb = workingWeight(for: exercise)
            state.nextExercise = workout.exercises.indices
                .first { $0 != index && !workout.exercises[$0].exerciseDone }
                .map { String(workout.exercises[$0].name.prefix(80)) }
        }
        state.restEndsAt = restEndsAt
        if let line = messages.last(where: { $0.role == .coach && !$0.isPendingCoachReply })?.content {
            state.caption = String(line.prefix(400))
        }
        return state
    }

    /// Set done on the Watch, when the coach screen isn't there to take it:
    /// the next set of the lift you're on, at its target reps.
    func logSetFromWatch() {
        guard let index = currentExerciseIndex, let exercise = activeWorkout?.exercises[index] else { return }
        completeNextSet(exerciseIndex: index, reps: exercise.targetReps)
    }

    /// A workout started: open MYO on the Watch, if there is one.
    func startWatchWorkout() {
        guard let workout = activeWorkout else { return }
        WatchWorkoutLink.shared.startWatchWorkout(activityType: HealthSync.activityType(for: workout.workoutName))
    }

    /// The workout finished. The Watch saves it to Health when it ran it;
    /// otherwise the phone does (HealthSync), as before.
    func saveFinishedWorkoutToHealth(sessionId: String, name: String, start: Date, end: Date) {
        Task {
            let watchSaves = await WatchWorkoutLink.shared.endWorkout(sessionId: sessionId, save: HealthSync.shared.enabled)
            guard !watchSaves else { return }
            await HealthSync.shared.saveWorkout(sessionId: sessionId, name: name, start: start, end: end)
        }
    }

    /// The workout was thrown away: the Watch drops its recording too.
    func discardWatchWorkout(sessionId: String) {
        Task { _ = await WatchWorkoutLink.shared.endWorkout(sessionId: sessionId, save: false) }
    }
}
