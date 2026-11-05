import Foundation

/// The moves the body knows as data (`MoveSpec`), on top of the hand-built
/// lifts in `Lift`. Matched before them, so a specific name ("bench dip",
/// "leg raise") isn't swallowed by a broader lift's keyword. Order matters
/// here too: "upright row" before "row", "reverse fly" before "fly".
enum MoveLibrary {
    static func match(_ name: String) -> MoveSpec? {
        let n = " " + name.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[^a-z']+"#, with: " ", options: .regularExpression) + " "
        return all.first { spec in
            spec.names.contains { n.contains(" " + $0.replacingOccurrences(of: "-", with: " ") + " ") }
        }
    }

    private typealias Key = MoveSpec.Key
    private typealias Lesson = MoveSpec.Lesson

    // Shared stances.
    private static let sideFeet: [[Float]] = [[0, -0.385], [0.04, -0.385]]
    private static let frontFeet: [[Float]] = [[-0.15, -0.385], [0.15, -0.385]]
    private static let sideHang: [[Float]] = [[-88, -88], [-86, -86]]
    /// On its back, head to the left, knees up, feet flat.
    private static let lyingFeet: [[Float]] = [[0.30, -0.385], [0.33, -0.385]]
    /// Hips when lying on the floor.
    private static let lyingHip: [Float] = [0.04, -0.30]

    static let all: [MoveSpec] = [
        MoveSpec(
            id: "walking-lunge",
            names: ["walking lunge", "walking lunges", "alternating lunge", "alternating lunges", "travelling lunge", "traveling lunge"],
            view: .side, seconds: 3.6, tempo: .wave,
            keys: [
                // Down on one leg, up through standing, down on the other.
                Key(hip: [-0.01, -0.15], tilt: 2, arms: sideHang, feet: [[-0.24, -0.36], [0.21, -0.385]]),
                Key(hip: [0.0, 0.005], tilt: 2, arms: sideHang, feet: sideFeet),
                Key(hip: [0.01, -0.15], tilt: 2, arms: sideHang, feet: [[0.21, -0.385], [-0.24, -0.36]]),
            ],
            lesson: [
                Lesson(line: "Walking lunges. A long step, then drop the back knee toward the floor.", at: 0),
                Lesson(line: "Stand up through the front heel and step through.", at: 0.5),
                Lesson(line: "Then the other leg. Like this."),
            ],
            cues: ["Long steps.", "Chest tall.", "Drive through the front heel."]),
        MoveSpec(
            id: "upright-row", names: ["upright row", "upright rows"], view: .front, gear: "barbell", seconds: 2.8,
            keys: [
                Key(hip: [0, 0.005], hands: [[-0.10, -0.10]], bend: [-1, 0], feet: frontFeet),
                Key(hip: [0, 0.005], hands: [[-0.08, 0.33]], bend: [-1, 0.5], feet: frontFeet),
            ],
            lesson: [
                Lesson(line: "Upright rows. Hands close, keep it near your body.", at: 0),
                Lesson(line: "Lead with your elbows, up to your chest.", at: 1),
                Lesson(line: "Then lower it slow. Like this."),
            ],
            cues: ["Elbows lead.", "Keep it close.", "Chest height, no higher."]),
        MoveSpec(
            id: "row",
            names: ["bent over row", "barbell row", "dumbbell row", "db row", "pendlay row", "t bar row",
                    "seal row", "single arm row", "one arm row", "cable row", "seated row", "row", "rows"],
            view: .side, gear: "barbell", seconds: 2.8, heavy: true,
            keys: [
                Key(hip: [-0.11, -0.03], tilt: 55, arms: [[-90, -90], [-90, -90]], feet: sideFeet),
                Key(hip: [-0.11, -0.03], tilt: 55, arms: [[-150, -92], [-150, -92]], feet: sideFeet),
            ],
            lesson: [
                Lesson(line: "Rows. Hinge forward, back flat, arms long.", at: 0),
                Lesson(line: "Pull it to your belly, elbows back.", at: 1),
                Lesson(line: "Lower it slow. Like this."),
            ],
            cues: ["Back flat.", "Elbows back.", "Squeeze your shoulder blades."]),
        MoveSpec(
            id: "shrug", names: ["shrug", "shrugs"], view: .front, gear: "dumbbells", seconds: 2.4,
            keys: [
                Key(hip: [0, 0.005], arms: [[-95, -92]], feet: frontFeet),
                Key(hip: [0, 0.005], arms: [[-95, -92]], feet: frontFeet, shrug: 0.055),
            ],
            lesson: [
                Lesson(line: "Shrugs. Arms long, weights at your sides.", at: 0),
                Lesson(line: "Shoulders straight up toward your ears.", at: 1),
                Lesson(line: "Hold it, then lower slowly. Like this."),
            ],
            cues: ["Straight up.", "Pause at the top.", "No rolling."]),
        MoveSpec(
            id: "front-raise", names: ["front raise", "front raises", "plate raise"], view: .side,
            gear: "dumbbells", seconds: 2.8,
            keys: [
                Key(hip: [-0.01, 0.005], tilt: 2, arms: [[-85, -83], [-85, -83]], feet: sideFeet),
                Key(hip: [-0.01, 0.005], tilt: 0, arms: [[0, 2], [0, 2]], feet: sideFeet),
            ],
            lesson: [
                Lesson(line: "Front raises. Soft elbows, weights by your thighs.", at: 0),
                Lesson(line: "Raise them in front, up to shoulder height.", at: 1),
                Lesson(line: "Lower with control. Like this."),
            ],
            cues: ["Shoulder height.", "No swinging.", "Slow on the way down."]),
        MoveSpec(
            id: "reverse-fly",
            names: ["reverse fly", "reverse flye", "reverse flys", "reverse flyes", "rear delt fly", "rear delt raise",
                    "rear delt", "face pull", "face pulls"],
            view: .front, gear: "dumbbells", seconds: 2.8,
            keys: [
                Key(hip: [0, 0.005], hands: [[-0.06, 0.20]], bend: [-1, -0.3], feet: frontFeet),
                Key(hip: [0, 0.005], hands: [[-0.48, 0.22]], bend: [-1, -0.3], feet: frontFeet),
            ],
            lesson: [
                Lesson(line: "Reverse flys. Arms in front, a soft bend.", at: 0),
                Lesson(line: "Open wide and squeeze your upper back.", at: 1),
                Lesson(line: "Back in, slow. Like this."),
            ],
            cues: ["Squeeze your upper back.", "Soft elbows.", "Slow and controlled."]),
        MoveSpec(
            id: "fly", names: ["chest fly", "fly", "flye", "flys", "flyes", "flies", "pec deck", "cable crossover"],
            view: .front, gear: "dumbbells", seconds: 2.8,
            keys: [
                Key(hip: [0, 0.005], hands: [[-0.48, 0.22]], bend: [-1, -0.3], feet: frontFeet),
                Key(hip: [0, 0.005], hands: [[-0.06, 0.24]], bend: [-1, -0.3], feet: frontFeet),
            ],
            lesson: [
                Lesson(line: "Flys. Arms wide, a soft bend in your elbows.", at: 0),
                Lesson(line: "Bring them together like you're hugging a tree.", at: 1),
                Lesson(line: "Open back up slowly. Like this."),
            ],
            cues: ["Hug the tree.", "Soft elbows.", "Feel the stretch."]),
        MoveSpec(
            id: "glute-bridge", names: ["glute bridge", "hip bridge", "bridge", "bridges", "hip thrust", "hip thrusts"],
            view: .side, takesGear: false, seconds: 3.0,
            keys: [
                Key(hip: lyingHip, tilt: -88, arms: [[-5, 0], [-5, 0]], feet: lyingFeet),
                Key(hip: [0.06, -0.12], tilt: -125, nod: 16, arms: [[-15, -5], [-15, -5]], feet: lyingFeet),
            ],
            lesson: [
                Lesson(line: "Glute bridges. On your back, feet flat, knees up.", at: 0),
                Lesson(line: "Drive your hips up and squeeze at the top.", at: 1),
                Lesson(line: "Lower slow. Like this."),
            ],
            cues: ["Squeeze at the top.", "Drive through your heels.", "Ribs down."]),
        MoveSpec(
            id: "sit-up", names: ["sit up", "sit ups", "situp", "situps"], view: .side, takesGear: false, seconds: 3.0,
            keys: [
                Key(hip: lyingHip, tilt: -88, arms: [[-2, 0], [-2, 0]], feet: lyingFeet),
                Key(hip: lyingHip, tilt: -15, arms: [[0, 0], [0, 0]], feet: lyingFeet),
            ],
            lesson: [
                Lesson(line: "Sit-ups. On your back, knees up, feet flat.", at: 0),
                Lesson(line: "Roll all the way up, reaching past your knees.", at: 1),
                Lesson(line: "Roll back down slow. Like this."),
            ],
            cues: ["Exhale up.", "Slow on the way down.", "Feet stay down."]),
        MoveSpec(
            id: "crunch", names: ["crunch", "crunches", "ab crunch", "bicycle crunch"], view: .side, takesGear: false,
            seconds: 2.4,
            keys: [
                Key(hip: lyingHip, tilt: -88, arms: [[-2, 0], [-2, 0]], feet: lyingFeet),
                Key(hip: lyingHip, tilt: -60, nod: 15, arms: [[-8, -8], [-8, -8]], feet: lyingFeet),
            ],
            lesson: [
                Lesson(line: "Crunches. Knees up, lower back down.", at: 0),
                Lesson(line: "Curl your shoulders up off the floor.", at: 1),
                Lesson(line: "Down slow. Like this."),
            ],
            cues: ["Exhale up.", "Chin off your chest.", "Slow down."]),
        MoveSpec(
            id: "leg-raise", names: ["leg raise", "leg raises", "leg lift", "leg lifts"], view: .side, takesGear: false,
            seconds: 3.2,
            keys: [
                // Legs straight the whole way: flat, 45°, vertical.
                Key(hip: [0.04, -0.30], tilt: -90, arms: [[-3, 0], [-3, 0]], feet: [[0.43, -0.37], [0.43, -0.35]]),
                Key(hip: [0.04, -0.30], tilt: -90, arms: [[-3, 0], [-3, 0]], feet: [[0.31, -0.03], [0.33, -0.02]]),
                Key(hip: [0.04, -0.30], tilt: -90, arms: [[-3, 0], [-3, 0]], feet: [[0.07, 0.09], [0.10, 0.09]]),
            ],
            lesson: [
                Lesson(line: "Leg raises. Lie flat, legs long.", at: 0),
                Lesson(line: "Lift them up to vertical, lower back pressed down.", at: 1),
                Lesson(line: "Lower slowly, don't let them drop. Like this."),
            ],
            cues: ["Lower back down.", "Slow on the way down.", "Legs long."]),
        MoveSpec(
            id: "calf-raise", names: ["calf raise", "calf raises", "heel raise", "heel raises"], view: .side,
            seconds: 2.2,
            keys: [
                Key(hip: [-0.01, 0.005], tilt: 2, arms: sideHang, feet: sideFeet),
                Key(hip: [0.0, 0.045], tilt: 2, arms: sideHang, feet: [[0.02, -0.35], [0.06, -0.35]]),
            ],
            lesson: [
                Lesson(line: "Calf raises. Stand tall, weight on the balls of your feet.", at: 0),
                Lesson(line: "Rise up as high as you can.", at: 1),
                Lesson(line: "Lower all the way down. Like this."),
            ],
            cues: ["All the way up.", "Pause at the top.", "Full stretch at the bottom."]),
        MoveSpec(
            id: "dip", names: ["dip", "dips", "tricep dip", "triceps dip", "bench dip", "chair dip"], view: .front,
            takesGear: false, seconds: 2.8, lowersFirst: true,
            keys: [
                Key(hip: [0, 0.09], hands: [[-0.21, 0.0]], bend: [-1, 0.6], feet: [[-0.07, -0.27], [0.07, -0.27]]),
                Key(hip: [0, -0.04], hands: [[-0.21, 0.0]], bend: [-1, 0.6], feet: [[-0.07, -0.38], [0.07, -0.38]]),
            ],
            lesson: [
                Lesson(line: "Dips. Arms straight, shoulders down.", at: 0),
                Lesson(line: "Lower until your elbows bend to ninety.", at: 1),
                Lesson(line: "Then press back up. Like this."),
            ],
            cues: ["Shoulders down.", "Elbows back.", "Press all the way up."]),
        MoveSpec(
            id: "jumping-jack", names: ["jumping jack", "jumping jacks", "star jump", "star jumps"], view: .front,
            takesGear: false, seconds: 1.2, tempo: .wave, hop: 0.05,
            keys: [
                Key(hip: [0, 0.005], arms: [[-100, -95]], feet: [[-0.08, -0.385], [0.08, -0.385]]),
                Key(hip: [0, -0.04], arms: [[118, 108]], feet: [[-0.25, -0.385], [0.25, -0.385]]),
            ],
            lesson: [
                Lesson(line: "Jumping jacks. Feet together, arms down.", at: 0),
                Lesson(line: "Jump out wide, arms overhead.", at: 1),
                Lesson(line: "Keep a steady rhythm. Like this."),
            ],
            cues: ["Light on your feet.", "Keep breathing.", "Steady rhythm."]),
        MoveSpec(
            // On all fours, opposite arm and leg reach long, then the other
            // side. Hips over knees, shoulders over hands.
            id: "bird-dog", names: ["bird dog", "bird dogs", "birddog", "birddogs", "quadruped reach"],
            view: .side, takesGear: false, seconds: 3.2, tempo: .wave,
            keys: [
                Key(hip: [-0.12, -0.195], tilt: 90, nod: -5, arms: [[-90, -90], [-90, -90]],
                    feet: [[-0.31, -0.385], [-0.29, -0.385]]),
                Key(hip: [-0.12, -0.195], tilt: 90, nod: -5, arms: [[2, 2], [-90, -90]],
                    feet: [[-0.31, -0.385], [-0.50, -0.19]]),
                Key(hip: [-0.12, -0.195], tilt: 90, nod: -5, arms: [[-90, -90], [-90, -90]],
                    feet: [[-0.31, -0.385], [-0.29, -0.385]]),
                Key(hip: [-0.12, -0.195], tilt: 90, nod: -5, arms: [[-90, -90], [2, 2]],
                    feet: [[-0.50, -0.19], [-0.29, -0.385]]),
            ],
            lesson: [
                Lesson(line: "Bird dogs. On all fours, hands under shoulders, knees under hips.", at: 0),
                Lesson(line: "Reach one arm forward and the opposite leg back, long and level.", at: 1),
                Lesson(line: "Back to the middle, then switch sides. Slow, like this."),
            ],
            cues: ["Back flat, like a tabletop.", "Reach long, not high.", "Slow and steady."]),
        MoveSpec(
            id: "mountain-climber", names: ["mountain climber", "mountain climbers"], view: .side, takesGear: false,
            seconds: 0.9, tempo: .wave,
            keys: [
                Key(hip: [-0.20, -0.055], tilt: 75, nod: -10, arms: [[-90, -90], [-88, -88]],
                    feet: [[-0.02, -0.30], [-0.42, -0.385]]),
                Key(hip: [-0.20, -0.055], tilt: 75, nod: -10, arms: [[-90, -90], [-88, -88]],
                    feet: [[-0.42, -0.385], [-0.02, -0.30]]),
            ],
            lesson: [
                Lesson(line: "Mountain climbers. Strong plank, hands under your shoulders.", at: 0),
                Lesson(line: "Drive one knee to your chest, then switch.", at: 1),
                Lesson(line: "Quick and steady. Like this."),
            ],
            cues: ["Hips down.", "Quick feet.", "Hands under shoulders."]),
        MoveSpec(
            id: "high-knees", names: ["high knees", "high knee", "march", "marching", "march in place"], view: .front,
            takesGear: false, seconds: 0.8, tempo: .wave, mirror: false,
            keys: [
                Key(hip: [0, 0.01], arms: [[-60, -20], [-95, -95]], feet: [[-0.12, -0.17], [0.13, -0.385]]),
                Key(hip: [0, 0.01], arms: [[-85, -85], [-120, -160]], feet: [[-0.13, -0.385], [0.12, -0.17]]),
            ],
            lesson: [
                Lesson(line: "High knees. Stand tall, arms ready.", at: 0),
                Lesson(line: "Drive each knee up to hip height.", at: 1),
                Lesson(line: "Quick and light. Like this."),
            ],
            cues: ["Knees up.", "Stay on your toes.", "Pump your arms."]),
        MoveSpec(
            id: "carry",
            names: ["farmer carry", "farmer's carry", "farmers carry", "farmer walk", "farmer's walk", "farmers walk",
                    "suitcase carry", "carry", "carries"],
            view: .front, gear: "dumbbells", seconds: 1.3, tempo: .wave,
            keys: [
                Key(hip: [-0.01, 0], tilt: -2, arms: [[-92, -91]], feet: [[-0.12, -0.30], [0.13, -0.385]]),
                Key(hip: [0.01, 0], tilt: 2, arms: [[-92, -91]], feet: [[-0.13, -0.385], [0.12, -0.30]]),
            ],
            lesson: [
                Lesson(line: "Carries. Stand tall, shoulders back, weights at your sides.", at: 0),
                Lesson(line: "Short, steady steps. Don't let them swing. Like this."),
            ],
            cues: ["Stand tall.", "Shoulders back.", "Grip hard."]),
    ]
}
