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
    let reps: Int?
    let weight: Double?
}

struct StartWorkoutResponse: Decodable {
    let ok: Bool
    let activeWorkout: ActiveWorkoutSession
}

struct FinishWorkoutResponse: Decodable {
    let ok: Bool
    let activeWorkout: ActiveWorkoutSession
}
