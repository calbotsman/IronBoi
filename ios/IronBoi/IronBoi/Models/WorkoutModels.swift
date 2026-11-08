import Foundation

struct WorkoutPlanSummary: Equatable, Identifiable {
    var id: String { planId }

    let userId: String
    let planId: String
    let source: String
    let updatedAt: String
    let days: [PlannedWorkoutDay]
}

struct PlanAdjustmentProposalSummary: Equatable, Identifiable {
    let id: String
    let proposalId: String
    let category: String
    let riskLevel: String
    let summary: String
    let rationale: String
    let dayKey: String?
    let patchTitle: String
    // proposedPlanPatch.type — drives special card layouts (clear_overrides
    // gets a single restore button instead of the scope picker).
    let patchType: String
    let changes: [String]
    // Full exercise detail for model-authored day patches. The card MUST
    // show exactly what will land in the plan — the user can't approve
    // content they can't see.
    let dayPatchDetails: [ProposalDayPatchDetail]
    let safetyNotes: [String]
    let sourceCorpusEntryIds: [String]
    let requiresFollowUp: Bool
    let createdAt: String
    // "today" | "rest_of_week" | "going_forward" — nil until the user (or a
    // future LLM tool call) has decided how far the change should reach.
    let scope: String?
}

struct ProposalDayPatchDetail: Equatable, Identifiable {
    var id: String { dayKey }
    let dayKey: String
    let name: String
    let exerciseLines: [String]
}

struct PlannedWorkoutDay: Equatable, Identifiable {
    var id: String { dayKey }

    let dayKey: String
    let name: String
    let muscles: [String]
    let exercises: [PlannedExercise]
    // True when this day's content comes from a dated dailyOverride (a
    // temporary coach adjustment) rather than the repeating template —
    // drives the ADJUSTED tag on the Train tab card.
    var isAdjusted: Bool = false
    // Their runs this day (people who run: the lifting is fitted around them).
    var runs: [PlannedRun] = []

    var totalSets: Int {
        exercises.reduce(0) { $0 + $1.sets }
    }
}

struct PlannedRun: Equatable, Identifiable, Hashable {
    var id: String { label + (note ?? "") }

    let kind: String
    let distanceMi: Double?
    let durationMin: Int?
    let note: String?

    /// "Easy run · 2 mi", "Long run · 45 min".
    var label: String {
        let name: String
        switch kind {
        case "long": name = "Long run"
        case "steady": name = "Steady run"
        case "intervals": name = "Intervals"
        case "walk_run": name = "Walk-run"
        default: name = "Easy run"
        }
        var parts = [name]
        if let distanceMi {
            parts.append(distanceMi == distanceMi.rounded() ? "\(Int(distanceMi)) mi" : String(format: "%.2g mi", distanceMi))
        }
        if let durationMin { parts.append("\(durationMin) min") }
        return parts.joined(separator: " · ")
    }
}

struct PlannedExercise: Equatable, Identifiable {
    var id: String { name }

    let name: String
    let sets: Int
    let reps: Int
    let weight: Double
}

struct ActiveWorkoutSession: Codable, Equatable, Identifiable {
    var id: String { sessionId }

    let userId: String
    let sessionId: String
    let planId: String
    let dayKey: String
    let workoutName: String
    var status: Status
    let startedAt: String
    var updatedAt: String
    var completedAt: String?
    var exercises: [ActiveWorkoutExercise]

    enum Status: String, Codable {
        case active
        case completed
        case abandoned
    }
}

struct ActiveWorkoutExercise: Codable, Equatable, Identifiable {
    var id: Int { exerciseIndex }

    let exerciseIndex: Int
    // `var`: you can swap a lift or change its sets and reps mid-workout.
    var name: String
    var targetSets: Int
    var targetReps: Int
    var targetWeight: Double
    var completedSets: [ActiveWorkoutSet]
    var exerciseDone: Bool
    var notes: String?
    /// Reps are per side, said mid-workout ("10 reps each side"); nil = the
    /// exercise's own default (ExerciseKnowledge.isUnilateral).
    var eachSide: Bool? = nil

    var completedSetCount: Int {
        completedSets.filter(\.completed).count
    }
}

struct ActiveWorkoutSet: Codable, Equatable, Identifiable {
    var id: Int { setIndex }

    let setIndex: Int
    var completed: Bool
    // `var`, not `let`. These carry what was ACTUALLY lifted, and until now
    // nothing ever wrote them — so finishWorkoutSession recorded
    // `loadKg: undefined` on every set of every workout, and the whole
    // progress layer (tonnage, Epley e1RM) silently had no data to read.
    var reps: Int?
    var weight: Double?
    /// A one-side-at-a-time lift: each side's reps (`reps` is the fewer).
    var leftReps: Int? = nil
    var rightReps: Int? = nil
}

struct StartWorkoutResponse: Decodable {
    let ok: Bool
    let activeWorkout: ActiveWorkoutSession
}

struct FinishWorkoutResponse: Decodable {
    let ok: Bool
    let activeWorkout: ActiveWorkoutSession
    // Weights the user actually worked at that differ from what was
    // prescribed. Proposals only — the server writes nothing until
    // applyExerciseBaselines is called from the finish card.
    let baselineSuggestions: [BaselineSuggestion]?
    /// What the coach says as the workout ends — built by the server from
    /// the logged sets. Missing when it couldn't be built (older backend).
    let recap: WorkoutRecap?
    /// Records, next-time weights and the streak (the contract's
    /// WorkoutRecap). Read from `recap` (its fields alongside `lines`) or a
    /// separate `trainingRecap`; missing or malformed means no card, never
    /// a failed finish.
    let trainingRecap: TrainingRecapModel?

    private enum CodingKeys: String, CodingKey {
        case ok, activeWorkout, baselineSuggestions, recap, trainingRecap
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        activeWorkout = try container.decode(ActiveWorkoutSession.self, forKey: .activeWorkout)
        baselineSuggestions = try container.decodeIfPresent([BaselineSuggestion].self, forKey: .baselineSuggestions)
        // A recap in a shape this build doesn't know costs the recap, not the workout.
        recap = try? container.decodeIfPresent(WorkoutRecap.self, forKey: .recap)
        let separate = try? container.decodeIfPresent(TrainingRecapModel.self, forKey: .trainingRecap)
        let merged = try? container.decodeIfPresent(TrainingRecapModel.self, forKey: .recap)
        trainingRecap = separate ?? merged
    }
}

/// The end of a workout, in three short lines: what you did, one thing
/// noticed, what's next. Every number comes from the log.
struct WorkoutRecap: Decodable, Equatable {
    let lines: [String]
    let firstWorkout: Bool
}

/// What this workout moved, for the card after it: records set, weights
/// that go up next time, the streak. Mirror of WorkoutRecap in
/// functions/src/contracts/coach-agent.ts (pounds). Named apart from
/// `WorkoutRecap` above, which is the spoken three lines.
struct TrainingRecapModel: Equatable {
    struct NextWeight: Equatable, Identifiable {
        var id: String { exerciseName }
        let exerciseName: String
        let fromLb: Double
        let toLb: Double
        let reason: String
    }

    struct ComparedToLast: Equatable, Identifiable {
        var id: String { exerciseName }
        let exerciseName: String
        let deltaLb: Double?
        let deltaReps: Int?
    }

    let records: [PersonalRecordModel]
    let nextWeights: [NextWeight]
    let comparedToLast: [ComparedToLast]
    let volumeLb: Double
    let previousVolumeLb: Double?
    let streakWeeks: Int

    /// Worth a card: a record, a weight going up, or a streak running.
    var hasNews: Bool { !records.isEmpty || !nextWeights.isEmpty || streakWeeks > 0 }
}

extension TrainingRecapModel: Decodable {
    private enum CodingKeys: String, CodingKey {
        case records, nextWeights, comparedToLast, volumeLb, previousVolumeLb, streakWeeks
    }

    // Every field optional, so one odd entry drops that entry, not the recap.
    private struct RawRecord: Decodable {
        let exerciseName: String?
        let kind: String?
        let weightLb: Double?
        let reps: Int?
        let e1rmLb: Double?
        let date: String?
    }

    private struct RawNextWeight: Decodable {
        let exerciseName: String?
        let fromLb: Double?
        let toLb: Double?
        let reason: String?
    }

    private struct RawCompared: Decodable {
        let exerciseName: String?
        let deltaLb: Double?
        let deltaReps: Int?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The spoken recap ({lines, firstWorkout}) has none of these: not one of us.
        guard container.contains(.records) || container.contains(.nextWeights) || container.contains(.streakWeeks) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "Not a training recap"))
        }
        let rawRecords = try? container.decodeIfPresent([RawRecord].self, forKey: .records)
        records = (rawRecords ?? []).compactMap { raw in
            guard let name = raw.exerciseName, let kind = raw.kind else { return nil }
            return PersonalRecordModel(exerciseName: name, kind: kind, weightLb: raw.weightLb ?? 0,
                                       reps: raw.reps ?? 0, e1rmLb: raw.e1rmLb, date: raw.date ?? "")
        }
        let rawNext = try? container.decodeIfPresent([RawNextWeight].self, forKey: .nextWeights)
        nextWeights = (rawNext ?? []).compactMap { raw in
            guard let name = raw.exerciseName, let from = raw.fromLb, let to = raw.toLb else { return nil }
            return NextWeight(exerciseName: name, fromLb: from, toLb: to, reason: raw.reason ?? "")
        }
        let rawCompared = try? container.decodeIfPresent([RawCompared].self, forKey: .comparedToLast)
        comparedToLast = (rawCompared ?? []).compactMap { raw in
            guard let name = raw.exerciseName else { return nil }
            return ComparedToLast(exerciseName: name, deltaLb: raw.deltaLb, deltaReps: raw.deltaReps)
        }
        volumeLb = (try? container.decodeIfPresent(Double.self, forKey: .volumeLb)) ?? 0
        previousVolumeLb = try? container.decodeIfPresent(Double.self, forKey: .previousVolumeLb)
        streakWeeks = (try? container.decodeIfPresent(Int.self, forKey: .streakWeeks)) ?? 0
    }
}

/// "How did that feel?" after a workout.
enum WorkoutEffort: String, CaseIterable, Identifiable {
    case easy
    case aboutRight = "about_right"
    case tooMuch = "too_much"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .easy: return "Easy"
        case .aboutRight: return "About right"
        case .tooMuch: return "Too much"
        }
    }
}

// MARK: - Exercise swaps

/// One substitute the server is willing to accept for an exercise.
///
/// The list is server-ranked and server-validated: `swapExercise` re-checks
/// the replacement against the same catalog, so nothing outside a returned
/// option can be written into the plan.
struct ExerciseSwapOption: Codable, Equatable, Identifiable {
    var id: String { name }

    let name: String
    let primary: [String]
    let secondary: [String]
    let equipment: [String]
    /// Server-built one-liner ("Chest · no equipment · same movement"). Built
    /// alongside the ranking so the reason can never disagree with the order.
    let reason: String
    let suggestedWeightLb: Double
    /// True when the suggested weight came from the user's own anchor for
    /// this movement rather than being carried over from the original.
    let weightFromBaseline: Bool
}

struct SwapOptionsResponse: Decodable {
    let ok: Bool
    let exerciseName: String
    let options: [ExerciseSwapOption]
}

/// Why the swap list is empty, which the UI has to tell apart.
///
/// Collapsing "the request failed" into an empty array made the sheet blame
/// the user's equipment filter for an unreachable backend — the two need
/// completely different copy, and only one of them is worth a retry button.
enum SwapOptionsOutcome {
    case loaded([ExerciseSwapOption])
    case failed
}

/// How far a swap reaches. Mirrors the server's scope enum.
enum SwapScope: String, CaseIterable, Identifiable {
    /// Mid-workout only. The plan is untouched.
    case session
    /// This occurrence only, as a dated override that expires on its own.
    case today
    /// The repeating template and every future week.
    case goingForward = "going_forward"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .session: return "Just this workout"
        case .today: return "Just today"
        case .goingForward: return "Every time"
        }
    }

    var explanation: String {
        switch self {
        case .session: return "Swaps it right now. Your plan keeps the original."
        case .today: return "Changes today's session only. Next week is unchanged."
        case .goingForward: return "Replaces it in this day from now on."
        }
    }
}

struct SwapExerciseResponse: Decodable {
    let ok: Bool
    let scope: String
    let activeWorkout: ActiveWorkoutSession?
}

// MARK: - Weight rebaselining

/// A proposed change to the working weight the plan prescribes for one
/// exercise, surfaced on the finish screen for the user to accept or decline.
struct BaselineSuggestion: Decodable, Equatable, Identifiable {
    var id: String { exerciseName }

    let exerciseName: String
    let fromLb: Double
    let toLb: Double
}

// MARK: - Progress summary (derivedSummaries/progress_current)
// Server-computed, read-only mirror of the backend ProgressSummary contract.
// All math happens in functions/src/progress/build.ts — the app only renders.

struct ProgressSummaryModel: Equatable {
    let computedAt: String
    let adherence: ProgressAdherence
    let volumeWeeklyTotals: [Double]
    let volumeTrend: String
    let lifts: [ProgressLift]
    let body: ProgressBody
    // Retired with the named coaching protocols: the server no longer writes
    // these and History doesn't show them. Still decoded so older docs load.
    let lensHighlights: [ProgressLensHighlight]
}

struct ProgressAdherence: Equatable {
    let plannedSessions: Int
    let completedSessions: Int
    let weeklyRate: [Double]
    let streakWeeks: Int
}

struct ProgressLift: Equatable, Identifiable {
    var id: String { exerciseName }
    let exerciseName: String
    let e1rmSeries: [ProgressPoint]
    let trendPct: Double
}

struct ProgressPoint: Equatable {
    let date: String
    let value: Double
}

struct ProgressBody: Equatable {
    let weightSeries: [ProgressPoint]
    let rollingAvgKg: Double?
    let trendPctPerWeek: Double?
    let goalDirection: String
    let withinSafeBand: Bool
}

struct ProgressLensHighlight: Equatable, Identifiable {
    var id: String { metric }
    let metric: String
    let framing: String
    let note: String
}


// MARK: - Training history (derivedSummaries/training_history)
// Server-built mirror of TrainingHistory in functions/src/contracts/coach-agent.ts
// (docs/plans/myo-training-intelligence.md). Weights are pounds. The app only
// renders and reads it; all the maths is server-side.

struct TrainingHistoryModel: Equatable {
    let computedAt: String
    let today: String
    let streak: TrainingStreak
    let thisWeek: TrainingWeek
    let calendar: [TrainingDay]
    let missedThisWeek: [MissedSession]
    let recentMuscles: [String]
    let lifts: [LiftProgress]
    let recentRecords: [PersonalRecordModel]
}

struct TrainingStreak: Equatable {
    let currentWeeks: Int
    let bestWeeks: Int
    let thisWeekMet: Bool
}

struct TrainingWeek: Equatable {
    let weekStart: String
    let planned: Int
    let done: Int
    let volumeLb: Double
    let avgEffort: Double?
}

struct TrainingDay: Equatable, Identifiable {
    var id: String { date }
    let date: String
    let dayKey: String
    /// done | missed | rest | today | planned | extra
    let status: String
    let name: String?
    let sessionId: String?
}

struct MissedSession: Equatable, Identifiable {
    var id: String { date }
    let date: String
    let dayKey: String
    let name: String
    let muscles: [String]
}

struct LiftProgress: Equatable, Identifiable {
    var id: String { exerciseKey }
    let exerciseKey: String
    let exerciseName: String
    let currentLb: Double
    let startLb: Double
    let firstDate: String
    let lastDate: String
    let sessions: Int
    /// Newest first.
    let events: [ProgressionEventModel]
    /// Oldest first, pounds.
    let e1rmSeries: [ProgressPoint]
    let prs: [PersonalRecordModel]
}

struct ProgressionEventModel: Equatable, Identifiable {
    var id: String { "\(date)-\(kind)-\(fromLb)-\(toLb)" }
    let date: String
    /// session_up | weekly_up | hold_missed_reps | hold_not_trained | deload | changed_in_workout | plan_change
    let kind: String
    let fromLb: Double
    let toLb: Double
    let reason: String
}

struct PersonalRecordModel: Equatable, Identifiable {
    var id: String { "\(exerciseName)-\(kind)-\(date)-\(weightLb)-\(reps)" }
    let exerciseName: String
    /// heaviest | most_reps | best_e1rm
    let kind: String
    let weightLb: Double
    let reps: Int
    let e1rmLb: Double?
    let date: String
}

extension TrainingHistoryModel {
    /// Parses the Firestore doc; nil if it isn't one.
    init?(firestore data: [String: Any]) {
        func double(_ any: Any?) -> Double? {
            if let n = any as? NSNumber { return n.doubleValue }
            return any as? Double
        }
        func int(_ any: Any?) -> Int? {
            if let n = any as? NSNumber { return n.intValue }
            return any as? Int
        }
        func record(_ raw: [String: Any]) -> PersonalRecordModel? {
            guard let name = raw["exerciseName"] as? String, let kind = raw["kind"] as? String,
                  let date = raw["date"] as? String else { return nil }
            return PersonalRecordModel(exerciseName: name, kind: kind, weightLb: double(raw["weightLb"]) ?? 0,
                                       reps: int(raw["reps"]) ?? 0, e1rmLb: double(raw["e1rmLb"]), date: date)
        }
        guard let streakRaw = data["streak"] as? [String: Any],
              let weekRaw = data["thisWeek"] as? [String: Any] else { return nil }
        computedAt = data["computedAt"] as? String ?? ""
        today = data["today"] as? String ?? ""
        streak = TrainingStreak(currentWeeks: int(streakRaw["currentWeeks"]) ?? 0,
                                bestWeeks: int(streakRaw["bestWeeks"]) ?? 0,
                                thisWeekMet: streakRaw["thisWeekMet"] as? Bool ?? false)
        thisWeek = TrainingWeek(weekStart: weekRaw["weekStart"] as? String ?? "",
                                planned: int(weekRaw["planned"]) ?? 0, done: int(weekRaw["done"]) ?? 0,
                                volumeLb: double(weekRaw["volumeLb"]) ?? 0, avgEffort: double(weekRaw["avgEffort"]))
        calendar = (data["calendar"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let date = raw["date"] as? String, let dayKey = raw["dayKey"] as? String,
                  let status = raw["status"] as? String else { return nil }
            return TrainingDay(date: date, dayKey: dayKey, status: status,
                               name: raw["name"] as? String, sessionId: raw["sessionId"] as? String)
        }
        missedThisWeek = (data["missedThisWeek"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let date = raw["date"] as? String, let dayKey = raw["dayKey"] as? String,
                  let name = raw["name"] as? String else { return nil }
            return MissedSession(date: date, dayKey: dayKey, name: name, muscles: raw["muscles"] as? [String] ?? [])
        }
        recentMuscles = data["recentMuscles"] as? [String] ?? []
        lifts = (data["lifts"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let key = raw["exerciseKey"] as? String, let name = raw["exerciseName"] as? String else { return nil }
            return LiftProgress(
                exerciseKey: key, exerciseName: name,
                currentLb: double(raw["currentLb"]) ?? 0, startLb: double(raw["startLb"]) ?? 0,
                firstDate: raw["firstDate"] as? String ?? "", lastDate: raw["lastDate"] as? String ?? "",
                sessions: int(raw["sessions"]) ?? 0,
                events: (raw["events"] as? [[String: Any]] ?? []).compactMap { e in
                    guard let date = e["date"] as? String, let kind = e["kind"] as? String else { return nil }
                    return ProgressionEventModel(date: date, kind: kind, fromLb: double(e["fromLb"]) ?? 0,
                                                 toLb: double(e["toLb"]) ?? 0, reason: e["reason"] as? String ?? "")
                },
                e1rmSeries: (raw["e1rmSeries"] as? [[String: Any]] ?? []).compactMap { p in
                    guard let date = p["date"] as? String, let value = double(p["value"]) else { return nil }
                    return ProgressPoint(date: date, value: value)
                },
                prs: (raw["prs"] as? [[String: Any]] ?? []).compactMap(record))
        }
        recentRecords = (data["recentRecords"] as? [[String: Any]] ?? []).compactMap(record)
    }
}
