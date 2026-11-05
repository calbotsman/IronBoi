// Test-only stand-in. The logic tests compile the phone's pure parsing files
// on their own (no app host, so nothing launches or talks), and
// WorkoutVoice.swift names ExerciseMotion.Stance, which lives in the 3D body
// code. This is just that enum, so the parsing files compile unchanged.
enum ExerciseMotion {
    enum Stance: Equatable {
        case standing, seated, kneeling

        static func named(in text: String) -> Stance? {
            if text.contains("seated") || text.contains("sitting") { return .seated }
            if text.contains("kneeling") || text.contains("on my knees") { return .kneeling }
            if text.contains("standing") || text.contains("stand up") { return .standing }
            return nil
        }
    }
}
