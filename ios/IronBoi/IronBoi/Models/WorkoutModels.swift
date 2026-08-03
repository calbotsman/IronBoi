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

    var totalSets: Int {
        exercises.reduce(0) { $0 + $1.sets }
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
    let name: String
    let targetSets: Int
    let targetReps: Int
    let targetWeight: Double
    var completedSets: [ActiveWorkoutSet]
    var exerciseDone: Bool
    var notes: String?

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
}

// MARK: - Exercise swaps

/// One substitute the server is willing to accept for an exercise.
///
/// The list is server-ranked and server-validated: `swapExercise` re-checks
/// the replacement against the same catalog, so nothing outside a returned
/// option can be written into the plan.
struct ExerciseSwapOption: Decodable, Equatable, Identifiable {
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
    // Server-templated per-lens framings (computeLensHighlights). Empty for
    // docs written before the lens slice or when the lens is "none" — the
    // protocol card hides on empty.
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
