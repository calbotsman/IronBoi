import Foundation

/// During a workout the coach's body demonstrates the exercise you're on, as
/// a slow looping rep. One loop per movement family; an exercise is matched
/// to its family by name, and anything unmatched leaves the body a blob.
///
/// Same joint space as OneBodyMotion (blob centre at the origin, y up,
/// 13 joints). Upright lifts are seen from the front; hinges and lying
/// presses from the side.
enum ExerciseMotion: Equatable {
    case overheadPress, lateralRaise, squat, curl, tricepExtension, pullDown
    case hinge, benchPress, skullCrusher, pushups, plank

    /// Best guess from an exercise name, or nil when nothing fits.
    static func match(_ name: String) -> ExerciseMotion? {
        let n = name.lowercased()
        func has(_ words: String...) -> Bool { words.contains { n.contains($0) } }
        if has("push-up", "pushup", "push up") { return .pushups }
        if has("plank") { return .plank }
        if has("skull", "lying tricep", "lying extension") { return .skullCrusher }
        if has("tricep", "overhead extension", "french press") { return .tricepExtension }
        if has("curl") { return .curl }
        if has("lateral raise", "side raise", "lateral") { return .lateralRaise }
        if has("bench", "chest press", "floor press", "incline", "decline") { return .benchPress }
        if has("overhead press", "shoulder press", "military", "arnold", "push press", "ohp") { return .overheadPress }
        if has("pull-up", "pullup", "chin-up", "chinup", "pulldown", "pull-down", "lat ") { return .pullDown }
        if has("deadlift", "rdl", "romanian", "good morning", "hinge", "swing") { return .hinge }
        if has("squat", "lunge", "leg press", "split squat", "step-up", "step up") { return .squat }
        return nil
    }

    /// Seconds per rep: a slow, readable demonstration tempo.
    var repDuration: Float { repSeconds }

    private var repSeconds: Float {
        switch self {
        case .plank: return 4.5
        case .squat, .hinge, .pushups: return 3.0
        default: return 2.6
        }
    }

    /// Side-on lifts get the tucked-arm contact shading.
    private var side: Float {
        switch self {
        case .hinge, .benchPress, .skullCrusher, .pushups, .plank: return 1
        default: return 0
        }
    }

    func frame(at t: Float) -> BodyPose {
        let cycle = t / repSeconds
        // Down-and-back as a cosine with a short hold at each end.
        let raw = (1 - cos(cycle * 2 * .pi)) / 2
        let p = min(max((raw - 0.06) / 0.88, 0), 1)
        let joints: [Joint]
        switch self {
        case .pushups:
            joints = OneBodyMotion.plank(p)
        case .plank:
            let breath = p * 0.05
            joints = OneBodyMotion.plank(0, hipDepth: breath, headDepth: breath * 0.5)
        default:
            let (a, b) = poses
            joints = zip(a, b).map { $0 + ($1 - $0) * p }
        }
        return BodyPose(joints: joints, form: 1, side: side, label: "")
    }

    /// (start, end) of one rep.
    private var poses: ([Joint], [Joint]) {
        switch self {
        case .overheadPress:
            return (front(arms: (elbow: [-0.30, 0.10], hand: [-0.30, 0.30])),
                    front(arms: (elbow: [-0.22, 0.46], hand: [-0.19, 0.68])))
        case .lateralRaise:
            return (front(arms: (elbow: [-0.22, 0.08], hand: [-0.25, -0.08])),
                    front(arms: (elbow: [-0.38, 0.25], hand: [-0.59, 0.25])))
        case .curl:
            return (front(arms: (elbow: [-0.21, 0.06], hand: [-0.23, -0.13])),
                    front(arms: (elbow: [-0.21, 0.06], hand: [-0.20, 0.25])))
        case .tricepExtension:
            return (front(arms: (elbow: [-0.13, 0.48], hand: [-0.10, 0.30])),
                    front(arms: (elbow: [-0.13, 0.48], hand: [-0.11, 0.70])))
        case .pullDown:
            return (front(arms: (elbow: [-0.30, 0.45], hand: [-0.36, 0.66])),
                    front(arms: (elbow: [-0.37, 0.15], hand: [-0.32, 0.36])))
        case .squat:
            return (squatPose(depth: 0), squatPose(depth: 1))
        case .hinge:
            return (hingePose(depth: 0), hingePose(depth: 1))
        case .benchPress:
            return (lying(elbow: [-0.27, -0.06], hand: [-0.18, 0.02]),
                    lying(elbow: [-0.21, 0.10], hand: [-0.20, 0.32]))
        case .skullCrusher:
            return (lying(elbow: [-0.22, 0.20], hand: [-0.37, 0.10]),
                    lying(elbow: [-0.22, 0.20], hand: [-0.21, 0.42]))
        case .pushups, .plank:
            return (OneBodyMotion.plank(0), OneBodyMotion.plank(0))
        }
    }

    // MARK: - Pose builders

    /// Standing, front-on, with both arms set symmetrically from the left
    /// arm's elbow and hand.
    private func front(arms: (elbow: [Float], hand: [Float])) -> [Joint] {
        var j = OneBodyMotion.standing()
        j[4] = Joint(arms.elbow[0], arms.elbow[1], 0.105)
        j[5] = Joint(arms.hand[0], arms.hand[1], 0.10)
        j[7] = Joint(-arms.elbow[0], arms.elbow[1], 0.105)
        j[8] = Joint(-arms.hand[0], arms.hand[1], 0.10)
        return j
    }

    /// Front-on goblet squat: hips drop, knees track out, hands at the chest.
    private func squatPose(depth d: Float) -> [Joint] {
        func mix(_ a: Float, _ b: Float) -> Float { a + (b - a) * d }
        let drop = mix(0, -0.18)
        return [
            Joint(0, 0.50 + drop, 0.165), Joint(0, 0.26 + drop, 0.185), Joint(0, 0.005 + drop, 0.17),
            Joint(-0.16, 0.24 + drop, 0.10), Joint(-0.20, 0.12 + drop, 0.10), Joint(-0.06, 0.20 + drop, 0.095),
            Joint(0.16, 0.24 + drop, 0.10), Joint(0.20, 0.12 + drop, 0.10), Joint(0.06, 0.20 + drop, 0.095),
            Joint(mix(-0.13, -0.24), mix(-0.19, -0.20), 0.115), Joint(-0.16, -0.385, 0.11),
            Joint(mix(0.13, 0.24), mix(-0.19, -0.20), 0.115), Joint(0.16, -0.385, 0.11),
        ]
    }

    /// Side-on hip hinge: hips go back, chest goes forward, arms hang.
    private func hingePose(depth d: Float) -> [Joint] {
        func mix(_ a: Float, _ b: Float) -> Float { a + (b - a) * d }
        let shoulderX = mix(0.0, 0.13), shoulderY = mix(0.24, 0.13)
        return [
            Joint(mix(0.02, 0.29), mix(0.50, 0.17), 0.165),
            Joint(mix(0.0, 0.11), mix(0.26, 0.11), 0.185),
            Joint(mix(-0.02, -0.15), mix(0.005, -0.03), 0.17),
            Joint(shoulderX, shoulderY, 0.10),
            Joint(shoulderX + 0.01, shoulderY - 0.18, 0.085),
            Joint(shoulderX + 0.02, shoulderY - 0.35, 0.09),
            Joint(shoulderX + 0.03, shoulderY, 0.10),
            Joint(shoulderX + 0.04, shoulderY - 0.18, 0.085),
            Joint(shoulderX + 0.05, shoulderY - 0.35, 0.09),
            Joint(mix(0.01, 0.04), mix(-0.19, -0.20), 0.115), Joint(0.0, -0.385, 0.11),
            Joint(mix(0.03, 0.06), mix(-0.19, -0.20), 0.115), Joint(0.04, -0.385, 0.11),
        ]
    }

    /// Side-on, lying back on a bench, feet on the floor; both arms share
    /// one elbow/hand path.
    private func lying(elbow: [Float], hand: [Float]) -> [Joint] {
        [
            Joint(-0.44, -0.10, 0.155), Joint(-0.20, -0.13, 0.175), Joint(0.12, -0.15, 0.16),
            Joint(-0.22, -0.10, 0.10), Joint(elbow[0], elbow[1], 0.085), Joint(hand[0], hand[1], 0.09),
            Joint(-0.18, -0.10, 0.10), Joint(elbow[0] + 0.04, elbow[1], 0.085), Joint(hand[0] + 0.04, hand[1], 0.09),
            Joint(0.34, -0.11, 0.11), Joint(0.36, -0.385, 0.10),
            Joint(0.31, -0.13, 0.11), Joint(0.44, -0.385, 0.10),
        ]
    }
}

/// What makes the coach feel present during a workout instead of a looping
/// GIF: it rests as a blob, now and then takes shape to show a couple of
/// reps of what you're on, melts back, sometimes cheers — and always cheers
/// when you finish a set. Timings are randomised so it never settles into a
/// rhythm.
struct WorkoutLife {
    private enum Act {
        case blob(until: Float)
        case demo(start: Float, reps: Int)
        case cheer(start: Float, style: Int)
    }

    private var act: Act = .blob(until: 1.5)
    private var lastMotion: ExerciseMotion?
    private var lastSetsDone: Int?
    private static let cheerSeconds: Float = 2.8

    /// The pose for this moment. `setsDone` is the session's completed-set
    /// count; a rise means you just finished one.
    mutating func pose(motion: ExerciseMotion?, setsDone: Int, time t: Float) -> BodyPose? {
        // A finished set: celebrate now, whatever was happening.
        if let last = lastSetsDone, setsDone > last {
            act = .cheer(start: t, style: Int.random(in: 0...1))
        }
        lastSetsDone = setsDone
        // A new exercise: a breath as a blob, then show it.
        if motion != lastMotion {
            lastMotion = motion
            if case .cheer = act {} else { act = .blob(until: t + 1.5) }
        }

        switch act {
        case .blob(let until):
            if t >= until { act = next(after: t, motion: motion) }
            return nil
        case .demo(let start, let reps):
            guard let motion else { act = .blob(until: t + 2); return nil }
            let length = Float(reps) * motion.repDuration
            if t - start >= length {
                act = .blob(until: t + Float.random(in: 5...10))
                return nil
            }
            return motion.frame(at: t - start)
        case .cheer(let start, let style):
            if t - start >= Self.cheerSeconds {
                act = .blob(until: t + Float.random(in: 4...8))
                return nil
            }
            return Self.cheer(at: t - start, style: style)
        }
    }

    /// Hold as a blob (you're talking); pick back up a beat after.
    mutating func rest(until t: Float) {
        act = .blob(until: t)
    }

    private func next(after t: Float, motion: ExerciseMotion?) -> Act {
        let roll = Float.random(in: 0..<1)
        if motion != nil, roll < 0.7 { return .demo(start: t, reps: Int.random(in: 2...3)) }
        if roll < 0.85 { return .cheer(start: t, style: Int.random(in: 0...1)) }
        return .blob(until: t + Float.random(in: 4...8))
    }

    /// Arms up in a V with a little bounce, or a single fist pump.
    private static func cheer(at t: Float, style: Int) -> BodyPose {
        var j = OneBodyMotion.standing(t)
        let bounce = abs(sin(t * 6.5)) * 0.045 * (1 - min(t / cheerSeconds, 1) * 0.5)
        for i in j.indices { j[i].y += bounce }
        if style == 0 {
            // Both arms up — "yes!"
            j[4] = Joint(-0.27, 0.44 + bounce, 0.10); j[5] = Joint(-0.36, 0.66 + bounce, 0.10)
            j[7] = Joint(0.27, 0.44 + bounce, 0.10);  j[8] = Joint(0.36, 0.66 + bounce, 0.10)
        } else {
            // One fist pumping, the other arm easy at the side.
            let pump = (sin(t * 7) + 1) / 2 * 0.12
            j[7] = Joint(0.27, 0.40 + bounce, 0.10); j[8] = Joint(0.30, 0.56 + pump + bounce, 0.11)
        }
        return BodyPose(joints: j, form: 1, side: 0, label: "")
    }
}
