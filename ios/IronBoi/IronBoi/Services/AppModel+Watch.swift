import Foundation

/// Wearables during a workout: what the Watch shows and can do (see
/// WatchWorkoutLink), the heart-rate strap, and the iPhone workout session.
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

    /// A workout started: open MYO on the Watch, if there is one; connect
    /// the paired heart-rate strap; and, with no Watch after 15 s, try
    /// AirPods heart rate through an iPhone workout session (iOS 26).
    func startWatchWorkout() {
        guard let workout = activeWorkout else { return }
        let activityType = HealthSync.activityType(for: workout.workoutName)
        WatchWorkoutLink.shared.startWatchWorkout(activityType: activityType)
        HeartStrapConnector.shared.connect()
        let id = workout.sessionId
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard self.activeWorkout?.sessionId == id else { return }
            PhoneWorkoutSession.shared.startIfUseful(sessionId: id, activityType: activityType)
        }
    }

    /// The workout finished. Saved to Health once: by the Watch when it ran
    /// this workout, else by the iPhone workout session when it streamed
    /// heart rate, else by HealthSync, as before.
    func saveFinishedWorkoutToHealth(sessionId: String, name: String, start: Date, end: Date) {
        HeartStrapConnector.shared.disconnect()
        Task {
            let save = HealthSync.shared.enabled
            if await WatchWorkoutLink.shared.endWorkout(sessionId: sessionId, save: save) { return }
            if await PhoneWorkoutSession.shared.end(save: save, name: name) { return }
            await HealthSync.shared.saveWorkout(sessionId: sessionId, name: name, start: start, end: end)
        }
    }

    /// The workout was thrown away: the Watch drops its recording too.
    func discardWatchWorkout(sessionId: String) {
        HeartStrapConnector.shared.disconnect()
        Task {
            _ = await WatchWorkoutLink.shared.endWorkout(sessionId: sessionId, save: false)
            _ = await PhoneWorkoutSession.shared.end(save: false, name: "")
        }
    }
}
