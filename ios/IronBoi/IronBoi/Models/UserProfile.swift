import Foundation

// MARK: - Enums (mirror functions/src/contracts/coach-agent.ts)

enum UserSex: String, CaseIterable, Codable, Identifiable {
    case female, male
    case nonBinary = "non_binary"
    case preferNotToSay = "prefer_not_to_say"
    case selfDescribed = "self_described"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .female: return "Female"
        case .male: return "Male"
        case .nonBinary: return "Non-binary"
        case .preferNotToSay: return "Prefer not to say"
        case .selfDescribed: return "Self-described"
        }
    }
}

enum TrainingExperience: String, CaseIterable, Codable, Identifiable {
    case new, beginner, intermediate, advanced
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

enum TrainingFocus: String, CaseIterable, Codable, Identifiable {
    case myoRecommended = "myo_recommended"
    case muscleSplit = "muscle_split"
    case fullBody = "full_body"
    case strengthConditioning = "strength_conditioning"
    case mobilityRecovery = "mobility_recovery"
    case enduranceConditioning = "endurance_conditioning"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .myoRecommended: return "Let MYO decide"
        case .muscleSplit: return "Muscle split"
        case .fullBody: return "Full body"
        case .strengthConditioning: return "Strength & conditioning"
        case .mobilityRecovery: return "Mobility & recovery"
        case .enduranceConditioning: return "Endurance & conditioning"
        }
    }
}

enum GoalType: String, CaseIterable, Codable, Identifiable {
    case strength
    case muscleGain = "muscle_gain"
    case fatLoss = "fat_loss"
    case generalFitness = "general_fitness"
    case mobility
    case endurance
    case habitBuilding = "habit_building"
    case returnToTraining = "return_to_training"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .strength: return "Get stronger"
        case .muscleGain: return "Build muscle"
        case .fatLoss: return "Lose fat"
        case .generalFitness: return "General fitness"
        case .mobility: return "Mobility"
        case .endurance: return "Endurance"
        case .habitBuilding: return "Build the habit"
        case .returnToTraining: return "Return to training"
        }
    }
}

enum CoachingTone: String, CaseIterable, Codable, Identifiable {
    case direct, warm, balanced
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

enum PreferredWorkoutTime: String, CaseIterable, Codable, Identifiable {
    case morning, afternoon, evening, flexible
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

// MARK: - Profile struct

struct UserProfile: Equatable {
    var ageYears: Int?
    var sexOrGender: UserSex?
    var sexOrGenderSelfDescription: String?
    var heightCm: Double?
    var weightKg: Double?
    var goals: [GoalType]
    var goalNotes: String?
    var trainingExperience: TrainingExperience?
    var injuriesOrLimitations: [String]
    var equipment: [String]
    var schedule: Schedule
    var preferences: Preferences
    var dietaryConstraints: [String]

    struct Schedule: Equatable {
        var daysPerWeek: Int?
        var preferredDays: [String]
        var sessionLengthMin: Int?
    }

    struct Preferences: Equatable {
        var coachingTone: CoachingTone
        var preferredWorkoutTime: PreferredWorkoutTime
        var dislikedExercises: [String]
        var trainingFocus: TrainingFocus

        static var defaults: Preferences {
            Preferences(
                coachingTone: .balanced,
                preferredWorkoutTime: .flexible,
                dislikedExercises: [],
                trainingFocus: .myoRecommended,
            )
        }
    }

    static var empty: UserProfile {
        UserProfile(
            ageYears: nil,
            sexOrGender: nil,
            sexOrGenderSelfDescription: nil,
            heightCm: nil,
            weightKg: nil,
            goals: [],
            goalNotes: nil,
            trainingExperience: nil,
            injuriesOrLimitations: [],
            equipment: [],
            schedule: Schedule(daysPerWeek: nil, preferredDays: [], sessionLengthMin: nil),
            preferences: Preferences.defaults,
            dietaryConstraints: [],
        )
    }
}

// MARK: - Firestore ↔ Swift conversion

extension UserProfile {
    /// Build a UserProfile from a Firestore document. Missing fields stay nil
    /// or default empty — we don't fail on partial profiles.
    static func from(firestoreData data: [String: Any]) -> UserProfile {
        var profile = UserProfile.empty
        profile.ageYears = data["ageYears"] as? Int
        if let raw = data["sexOrGender"] as? String { profile.sexOrGender = UserSex(rawValue: raw) }
        profile.sexOrGenderSelfDescription = data["sexOrGenderSelfDescription"] as? String
        profile.heightCm = data["heightCm"] as? Double
        profile.weightKg = data["weightKg"] as? Double
        if let goalStrings = data["goals"] as? [String] {
            profile.goals = goalStrings.compactMap { GoalType(rawValue: $0) }
        }
        profile.goalNotes = data["goalNotes"] as? String
        if let raw = data["trainingExperience"] as? String {
            profile.trainingExperience = TrainingExperience(rawValue: raw)
        }
        profile.injuriesOrLimitations = data["injuriesOrLimitations"] as? [String] ?? []
        profile.equipment = data["equipment"] as? [String] ?? []
        if let s = data["schedule"] as? [String: Any] {
            profile.schedule.daysPerWeek = s["daysPerWeek"] as? Int
            profile.schedule.preferredDays = s["preferredDays"] as? [String] ?? []
            profile.schedule.sessionLengthMin = s["sessionLengthMin"] as? Int
        }
        if let p = data["preferences"] as? [String: Any] {
            if let tone = p["coachingTone"] as? String, let v = CoachingTone(rawValue: tone) {
                profile.preferences.coachingTone = v
            }
            if let time = p["preferredWorkoutTime"] as? String,
               let v = PreferredWorkoutTime(rawValue: time) {
                profile.preferences.preferredWorkoutTime = v
            }
            profile.preferences.dislikedExercises = p["dislikedExercises"] as? [String] ?? []
            if let focus = p["trainingFocus"] as? String,
               let v = TrainingFocus(rawValue: focus) {
                profile.preferences.trainingFocus = v
            }
        }
        profile.dietaryConstraints = data["dietaryConstraints"] as? [String] ?? []
        return profile
    }

    /// Serialize for the upsertProfile callable.
    /// Backend strips userId (server injects from auth) so we don't include it.
    /// All required-by-Zod fields are sent even when nil so the server gives
    /// a clear validation error rather than silently dropping fields.
    func firestorePayload() -> [String: Any] {
        var payload: [String: Any] = [
            "goals": goals.map(\.rawValue),
            "injuriesOrLimitations": injuriesOrLimitations,
            "equipment": equipment,
            "dietaryConstraints": dietaryConstraints,
            "schedule": [
                "preferredDays": schedule.preferredDays,
                "daysPerWeek": schedule.daysPerWeek as Any,
                "sessionLengthMin": schedule.sessionLengthMin as Any,
            ],
            "preferences": [
                "coachingTone": preferences.coachingTone.rawValue,
                "preferredWorkoutTime": preferences.preferredWorkoutTime.rawValue,
                "dislikedExercises": preferences.dislikedExercises,
                "trainingFocus": preferences.trainingFocus.rawValue,
            ],
        ]
        if let ageYears { payload["ageYears"] = ageYears }
        if let sexOrGender { payload["sexOrGender"] = sexOrGender.rawValue }
        if let sexOrGenderSelfDescription { payload["sexOrGenderSelfDescription"] = sexOrGenderSelfDescription }
        if let heightCm { payload["heightCm"] = heightCm }
        if let weightKg { payload["weightKg"] = weightKg }
        if let goalNotes, !goalNotes.isEmpty { payload["goalNotes"] = goalNotes }
        if let trainingExperience { payload["trainingExperience"] = trainingExperience.rawValue }
        return payload
    }
}
