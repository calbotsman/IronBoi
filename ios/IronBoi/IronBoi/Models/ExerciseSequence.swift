import Foundation

struct ExerciseSequence: Equatable {
    let slug: String
    let title: String
    let variant: String
    let frames: [ExerciseSequenceFrame]

    static func lookup(exerciseName: String, variant: String = "masculine") -> ExerciseSequence? {
        let normalized = exerciseName
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        guard normalized.contains("kb swing") || normalized.contains("kettlebell swing") else {
            return nil
        }

        guard variant == "masculine" else {
            return nil
        }

        return kettlebellSwingMasculine
    }

    private static let kettlebellSwingMasculine = ExerciseSequence(
        slug: "kettlebell_swing",
        title: "Kettlebell Swing",
        variant: "masculine",
        frames: [
            .init(
                id: "setup",
                title: "Setup",
                cue: "Hinge, reach for the bell, and keep your spine neutral.",
                imageName: "kettlebell_swing_masculine_01_setup"
            ),
            .init(
                id: "hike",
                title: "Hike",
                cue: "Pull the bell high between your thighs with your lats packed.",
                imageName: "kettlebell_swing_masculine_02_hike"
            ),
            .init(
                id: "snap",
                title: "Snap",
                cue: "Drive the hips forward. The bell floats from hip power.",
                imageName: "kettlebell_swing_masculine_03_snap"
            ),
            .init(
                id: "float",
                title: "Float",
                cue: "Stand tall, ribs down, glutes locked, arms relaxed.",
                imageName: "kettlebell_swing_masculine_04_float"
            ),
            .init(
                id: "return",
                title: "Return",
                cue: "Let the bell fall. Wait to hinge until it nears your hips.",
                imageName: "kettlebell_swing_masculine_05_return"
            ),
            .init(
                id: "reset",
                title: "Reset",
                cue: "Reload the hinge with the bell close and your back neutral.",
                imageName: "kettlebell_swing_masculine_06_reset"
            )
        ]
    )
}

struct ExerciseSequenceFrame: Identifiable, Equatable {
    let id: String
    let title: String
    let cue: String
    let imageName: String
}
