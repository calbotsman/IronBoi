import Foundation

// Banked alternatives: every swap and whole-session replacement for the
// plan's days, cached on the phone so changing the workout never waits on
// the network. Mirrors AlternativesBank in
// functions/src/workouts/sessionAlternatives.ts — keep the keys in step.

/// What someone can switch today's session to.
enum SessionKind: String, Codable, CaseIterable {
    case run, walk, cycle, row, swim, hike, yoga, mobility, bodyweight, shorter
}

/// The broad kind of training someone mainly does.
enum TrainingStyle: String, Codable {
    case strength, endurance, mobility
}

struct BankedItem: Codable, Equatable {
    let name: String
    let sets: Int
    /// Seconds when `timed`.
    let reps: Int
    let weight: Double
    let timed: Bool
}

struct SessionAlternative: Codable, Equatable, Identifiable {
    let id: String
    let kind: SessionKind
    let style: TrainingStyle
    /// How it's saved to Apple Health (HealthSync.activityType).
    let activity: String
    let title: String
    let minutes: Int
    let items: [BankedItem]
}

struct BankedAddOn: Codable, Equatable {
    let style: TrainingStyle
    let equipment: String
    let title: String
    let minutes: Int
    let items: [BankedItem]
}

struct BankedSwaps: Codable, Equatable {
    let exerciseName: String
    let options: [ExerciseSwapOption]
}

struct DayBank: Codable, Equatable {
    let dayKey: String
    let workoutName: String
    let swaps: [BankedSwaps]
    let sessions: [SessionAlternative]
}

struct AlternativesBank: Codable, Equatable {
    let version: Int
    let builtAt: String
    let clientDate: String
    let mainStyle: TrainingStyle
    let addOn: BankedAddOn?
    let kinds: [KindInfo]
    let days: [DayBank]

    struct KindInfo: Codable, Equatable {
        let kind: SessionKind
        let style: TrainingStyle
        let activity: String
        /// The one timed block a cardio or yoga session is ("Run", "Yoga Flow").
        let timedItem: String?
    }

    func day(_ dayKey: String) -> DayBank? { days.first { $0.dayKey == dayKey } }
}

struct SessionAlternativesResponse: Decodable {
    let ok: Bool
    let bank: AlternativesBank
}

/// Today's session switched for something else: logged and saved to Health as this.
struct SessionReplacement: Codable, Equatable {
    let kind: SessionKind
    let style: TrainingStyle
    let activity: String
    let title: String
    /// When the switch happened, if sets were already logged before it (ISO 8601).
    var switchedAt: String?
}

/// A change only the phone can make, carried on a coach reply by the text
/// pipeline (orchestrate.ts `clientActions`). Applied once.
struct CoachClientAction: Equatable {
    enum ActionType: String { case replaceSession = "replace_session", addSessionAddOn = "add_session_add_on" }
    let type: ActionType
    var kind: SessionKind?
    var minutes: Int?
    var alternativeId: String?
    var offeredAddOn = false

    init?(_ raw: [String: Any]) {
        guard let type = (raw["type"] as? String).flatMap(ActionType.init(rawValue:)) else { return nil }
        self.type = type
        kind = (raw["kind"] as? String).flatMap(SessionKind.init(rawValue:))
        minutes = raw["minutes"] as? Int
        alternativeId = raw["alternativeId"] as? String
        offeredAddOn = raw["offeredAddOn"] as? Bool ?? false
        if type == .replaceSession, kind == nil { return nil }
    }
}

enum SessionBank {
    /// Where the bank lives between launches, one file per account.
    static func fileURL(userId: String) -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let safe = userId.filter { $0.isLetter || $0.isNumber }
        return dir.appendingPathComponent("alternatives-\(safe).json")
    }

    static func load(userId: String) -> AlternativesBank? {
        guard let url = fileURL(userId: userId), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AlternativesBank.self, from: data)
    }

    static func save(_ bank: AlternativesBank, userId: String) {
        guard let url = fileURL(userId: userId), let data = try? JSONEncoder().encode(bank) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The day's banked swaps for a lift, minus anything already in the workout.
    static func swaps(in bank: AlternativesBank?, dayKey: String?, exerciseName: String, excluding: [String]) -> [ExerciseSwapOption]? {
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter } }
        guard let bank else { return nil }
        let days = dayKey.flatMap { bank.day($0) }.map { [$0] } ?? bank.days
        let skip = Set(excluding.map(key))
        for day in days {
            if let entry = day.swaps.first(where: { key($0.exerciseName) == key(exerciseName) }) {
                let options = entry.options.filter { !skip.contains(key($0.name)) }
                return options.isEmpty ? nil : options
            }
        }
        return nil
    }

    /// The exercises a banked session becomes in the workout, starting at `index`.
    static func exercises(_ items: [BankedItem], from index: Int) -> [ActiveWorkoutExercise] {
        items.enumerated().map { offset, item in
            ActiveWorkoutExercise(
                exerciseIndex: index + offset, name: item.name, targetSets: item.sets, targetReps: item.reps,
                targetWeight: item.weight,
                completedSets: (0..<max(item.sets, 1)).map { ActiveWorkoutSet(setIndex: $0, completed: false, reps: nil, weight: nil) },
                exerciseDone: false, notes: nil)
        }
    }

    /// A timed session stretched or cut to the length they asked for.
    static func resized(_ alternative: SessionAlternative, minutes: Int?) -> SessionAlternative {
        guard let minutes, minutes > 0, alternative.items.count == 1, let only = alternative.items.first, only.timed,
              only.reps >= 60 else { return alternative }
        let item = BankedItem(name: only.name, sets: 1, reps: minutes * 60, weight: 0, timed: true)
        return SessionAlternative(id: alternative.id, kind: alternative.kind, style: alternative.style,
                                  activity: alternative.activity, title: alternative.title, minutes: minutes, items: [item])
    }
}
