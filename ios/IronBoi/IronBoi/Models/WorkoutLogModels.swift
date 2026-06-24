import Foundation

/// A completed workout, read from `users/{uid}/workoutLogs/{sessionId}`.
/// Mirrors the WorkoutLog the backend writes in finishWorkoutSession.
struct WorkoutLogSummary: Identifiable, Equatable {
    var id: String { sessionId }
    let sessionId: String
    /// "YYYY-MM-DD"
    let date: String
    let title: String
    let exercises: [LoggedExercise]
    let durationSec: Int?
    let perceivedEffort: Int?

    var exerciseCount: Int { exercises.count }
    var totalSets: Int { exercises.reduce(0) { $0 + $1.sets.count } }
    var totalReps: Int { exercises.reduce(0) { $0 + $1.sets.reduce(0) { $0 + ($1.reps ?? 0) } } }
    var bestLoadKg: Double? { exercises.compactMap { $0.topLoadKg }.max() }

    /// Parsed Date for display formatting; nil if the stored string is odd.
    var day: Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        // Fixed machine format must use a fixed locale, or non-Gregorian /
        // non-Latin device locales fail the parse.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: date)
    }
}

struct LoggedExercise: Equatable {
    let name: String
    let sets: [LoggedSet]
    var topLoadKg: Double? { sets.compactMap { $0.loadKg }.max() }
}

struct LoggedSet: Equatable {
    let reps: Int?
    let loadKg: Double?
}

extension Array where Element == WorkoutLogSummary {
    var totalSessions: Int { count }
    var totalRepsLogged: Int { reduce(0) { $0 + $1.totalReps } }

    /// Heaviest single lift across all logs, as (exercise, lb), for the PR stamp.
    var heaviestLift: (name: String, pounds: Int)? {
        var best: (String, Double)?
        for log in self {
            for ex in log.exercises {
                if let top = ex.topLoadKg, top > (best?.1 ?? 0) {
                    best = (ex.name, top)
                }
            }
        }
        guard let best else { return nil }
        return (best.0, Int((best.1 / 0.45359237).rounded()))
    }
}
