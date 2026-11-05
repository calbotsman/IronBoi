import Foundation

/// Changing the weight of a lift mid-workout, from any of the three ways it
/// arrives: an exact phrase the phone hears itself ("bump it to 40"), the
/// text coach's set_workout_weight tool (a `clientActions` entry on its
/// reply), or the live coach calling the same tool on the phone.
extension AppModel {
    /// The coach asked "up to what?": the next bare number is the weight.
    struct WeightQuestion: Equatable {
        let exerciseName: String
        let at: Date
    }

    /// Sets the weight for the sets left on an exercise (and so the next
    /// logged set) and returns what it became. `guess`: see WeightLoad.resolve.
    @discardableResult
    func applyWeightRequest(_ request: WeightRequest, exerciseIndex: Int, guess: Bool) -> WeightResolution? {
        guard let workout = activeWorkout, workout.exercises.indices.contains(exerciseIndex) else { return nil }
        let exercise = workout.exercises[exerciseIndex]
        let result = WeightLoad.resolve(request, current: workingWeight(for: exercise),
                                        basis: WeightLoad.basis(for: exercise.name), guess: guess)
        setWorkoutExerciseWeight(exerciseIndex: exerciseIndex, weight: result.pounds)
        return result
    }

    /// The exercise a tool named, or the one you're on.
    func workoutExerciseIndex(named name: String?) -> Int? {
        guard let workout = activeWorkout else { return nil }
        func key(_ s: String) -> String { s.lowercased().filter(\.isLetter) }
        if let name, !name.isEmpty {
            let want = key(name)
            return workout.exercises.firstIndex { key($0.name) == want }
                ?? workout.exercises.firstIndex { key($0.name).contains(want) || want.contains(key($0.name)) }
        }
        return currentExerciseIndex
    }

    /// The live coach's set_workout_weight (same arguments as the server's).
    func liveSetWeight(_ args: [String: Any]) -> [String: Any] {
        guard activeWorkout != nil else { return ["ok": false, "error": "no_workout_in_progress"] }
        guard let index = workoutExerciseIndex(named: args["exerciseName"] as? String),
              let exercise = activeWorkout?.exercises[index] else {
            return ["ok": false, "error": "exercise_not_in_workout"]
        }
        let kilos = (args["unit"] as? String) == "kg"
        func pounds(_ key: String) -> Double? {
            guard let value = (args[key] as? NSNumber)?.doubleValue else { return nil }
            return kilos ? (value * 2.20462 / 2.5).rounded() * 2.5 : value
        }
        let stated = (args["basis"] as? String).flatMap(WeightRequest.Stated.init(rawValue:))
        let request: WeightRequest
        switch (pounds("weight"), pounds("change")) {
        case (nil, nil):
            weightQuestion = WeightQuestion(exerciseName: exercise.name, at: Date())
            return ["ok": true, "waitingForNumber": true, "say": "Ask how heavy, briefly: \"Up to what?\""]
        case (let to?, nil): request = WeightRequest(change: .to(to), stated: stated)
        case (nil, let by?): request = WeightRequest(change: .by(by), stated: stated)
        default: return ["ok": false, "error": "weight_or_change_not_both"]
        }
        guard let result = applyWeightRequest(request, exerciseIndex: index, guess: false) else {
            return ["ok": false, "error": "exercise_not_in_workout"]
        }
        weightQuestion = nil
        return ["ok": true, "exercise": exercise.name, "nowLb": result.pounds,
                "shown": WeightLoad.label(result.pounds, for: exercise.name),
                "say": "Confirm in one short sentence: \(exercise.name) at \(WeightLoad.spoken(result.pounds, for: exercise.name))."]
    }

    /// Applies one set_workout_weight decision from the text coach. It
    /// arrives on the reply's `clientActions`, which applyNewClientActions
    /// already applies once each and only for recent replies.
    func applyWorkoutAction(_ action: CoachWorkoutAction, now: Date = Date()) {
        guard activeWorkout != nil,
              let index = workoutExerciseIndex(named: action.exerciseName),
              let name = activeWorkout?.exercises[index].name else { return }
        switch action.kind {
        case .askWeight:
            weightQuestion = WeightQuestion(exerciseName: name, at: now)
        case .setWeight:
            guard let request = action.request else { return }
            applyWeightRequest(request, exerciseIndex: index, guess: false)
            weightQuestion = nil
            AudioHub.log("coach set weight: \(name) \(request.change)")
        }
    }
}
