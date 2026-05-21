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
    let changes: [String]
    let safetyNotes: [String]
    let sourceCorpusEntryIds: [String]
    let requiresFollowUp: Bool
    let createdAt: String
}

struct PlannedWorkoutDay: Equatable, Identifiable {
    var id: String { dayKey }

    let dayKey: String
    let name: String
    let muscles: [String]
    let exercises: [PlannedExercise]

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
