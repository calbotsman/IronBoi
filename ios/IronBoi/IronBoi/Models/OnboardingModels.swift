import Foundation

enum OnboardingStatus: String {
    case notStarted = "not_started"
    case collecting
    case proposalReady = "proposal_ready"
    case complete
}

enum CoachInputMode: String {
    case text
    case tap
    case dictation
    case liveVoice = "live_voice"
}

struct OnboardingChoice: Identifiable, Equatable {
    let id: String
    let label: String
    let structuredAnswer: [String: Any]

    static func == (lhs: OnboardingChoice, rhs: OnboardingChoice) -> Bool {
        lhs.id == rhs.id && lhs.label == rhs.label
    }
}

struct ProgramProposalSummary: Identifiable, Equatable {
    let id: String
    let proposalId: String
    let decision: String
    let profile: ProposalProfileSummary
    let workoutDays: [WorkoutDaySummary]
    let calories: RangeSummary?
    let proteinGrams: RangeSummary?
    let assumptions: [String]
    let safetyNotes: [String]
}

struct ProposalProfileSummary: Equatable {
    let goals: [String]
    let ageYears: Int?
    let sexOrGender: String?
    let heightCm: Double?
    let weightKg: Double?
    let trainingExperience: String?
    let equipment: [String]
    let daysPerWeek: Int?
    let sessionLengthMin: Int?
    let trainingFocus: String?
    let injuriesOrLimitations: [String]
    let dietaryConstraints: [String]
}

struct WorkoutDaySummary: Identifiable, Equatable {
    let id: String
    let dayKey: String
    let name: String
    let exerciseNames: [String]
}

struct RangeSummary: Equatable {
    let min: Int
    let max: Int
    let note: String?
}
