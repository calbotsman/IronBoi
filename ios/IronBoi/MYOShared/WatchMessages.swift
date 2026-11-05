import Foundation

/// What the phone and the Watch say to each other during a workout.
///
/// Carried over the mirrored HKWorkoutSession (`sendToRemoteWorkoutSession`
/// one way, `didReceiveDataFromRemoteWorkoutSession` the other) as JSON.
/// Apple caps that channel at 100 KB per 10 s, so messages stay small and
/// state is sent whole (no diffs to lose). Compiled into both targets.
enum WatchMessage: Codable, Equatable {
    // Watch → phone
    /// A heart-rate reading, plus the workout's active energy so far.
    case heart(bpm: Int, at: Date, activeEnergyKcal: Double?)
    /// The Set done button on the Watch.
    case setDone
    /// The End button on the Watch (after its own confirm).
    case endRequested

    // Phone → Watch
    /// Everything the Watch shows, whole.
    case state(WatchWorkoutState)
    /// The phone finished (save = true) or discarded (save = false) the
    /// workout. The Watch ends its session and saves or discards the
    /// HKWorkout; the phone then skips its own Health save.
    case end(sessionId: String, save: Bool)

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func decode(_ data: Data) -> WatchMessage? {
        try? JSONDecoder().decode(WatchMessage.self, from: data)
    }
}

/// The workout as the Watch draws it. Every field comes from the phone's
/// AppModel; the Watch adds only its own heart rate.
struct WatchWorkoutState: Codable, Equatable {
    /// The phone's workout session id, used as the HKWorkout's sync
    /// identifier so a workout is never saved twice.
    var sessionId: String
    var workoutName: String
    var exercise: String?
    /// 1-based set you're on, and how many there are.
    var setNumber: Int?
    var totalSets: Int?
    var targetReps: Int?
    /// Working weight; nil or 0 for bodyweight.
    var weightLb: Double?
    /// The rest timer's end, while resting.
    var restEndsAt: Date?
    /// The lift after this one, for "next:" during rest.
    var nextExercise: String?
    /// The coach's latest line, for when the phone is across the room.
    var caption: String?
    /// For heart-rate zones on the Watch; nil when the profile has no age.
    var ageYears: Int?
    /// Whether "Save workouts to Apple Health" is on in the phone's settings.
    var saveToHealth: Bool
}
