import Foundation
import simd

/// During a workout the coach's body demonstrates the exercise you're on, as
/// a slow looping rep, holding the equipment it needs. An exercise is matched
/// by name to a movement family and its equipment; anything unmatched leaves
/// the body a blob.
struct ExerciseMotion: Equatable {
    let lift: Lift
    let gear: Gear

    init(_ lift: Lift, _ gear: Gear) {
        self.lift = lift
        self.gear = gear
    }

    /// Best guess from an exercise name, or nil when nothing fits.
    static func match(_ name: String) -> ExerciseMotion? {
        guard let lift = Lift.match(name) else { return nil }
        return ExerciseMotion(lift, Gear.match(name, lift: lift))
    }

    var repDuration: Float { lift.repDuration }

    func frame(at t: Float) -> BodyPose { lift.frame(at: t, gear: gear) }

    func frame(holding p: Float, time t: Float) -> BodyPose { lift.frame(holding: p, time: t, gear: gear) }
}

/// One movement family. Same joint space as OneBodyMotion (blob centre at
/// the origin, y up, 13 joints). Lifts read best from the side when the
/// body travels (squat, hinge, bench) and from the front when the arms do.
enum Lift: Equatable {
    case overheadPress, lateralRaise, squat, curl, tricepExtension, pullDown
    case hinge, swing, benchPress, skullCrusher, pushups, plank

    static func match(_ name: String) -> Lift? {
        let n = name.lowercased()
        func has(_ words: String...) -> Bool { words.contains { n.contains($0) } }
        if has("push-up", "pushup", "push up") { return .pushups }
        if has("plank") { return .plank }
        if has("skull", "lying tricep", "lying extension") { return .skullCrusher }
        if has("tricep", "overhead extension", "french press") { return .tricepExtension }
        if has("curl") { return .curl }
        if has("lateral raise", "side raise") { return .lateralRaise }
        if has("bench", "chest press", "floor press", "incline", "decline") { return .benchPress }
        if has("overhead press", "shoulder press", "military", "arnold", "push press", "ohp") { return .overheadPress }
        if has("pull-up", "pullup", "pull up", "chin-up", "chinup", "pulldown", "pull-down", "lat ") { return .pullDown }
        if has("swing") { return .swing }
        if has("deadlift", "rdl", "romanian", "good morning", "hinge") { return .hinge }
        if has("squat", "lunge", "leg press", "step-up", "step up") { return .squat }
        return nil
    }

    /// Seconds per rep: a slow, readable demonstration tempo.
    var repDuration: Float { repSeconds }

    private var repSeconds: Float {
        switch self {
        case .plank: return 4.5
        case .swing: return 1.9
        case .squat, .hinge, .pushups: return 3.2
        default: return 2.8
        }
    }

    /// Side-on lifts get the tucked-arm contact shading.
    private var side: Float {
        switch self {
        case .squat, .hinge, .swing, .benchPress, .skullCrusher, .pushups, .plank: return 1
        default: return 0
        }
    }

    /// Lifts that start at the top and lower first (squat, bench); the rest
    /// start at rest and drive first (curl, press).
    private var lowersFirst: Bool {
        switch self {
        case .squat, .hinge, .benchPress, .skullCrusher, .pushups: return true
        default: return false
        }
    }

    /// Lifts whose arms move across the screen rather than toward you: the
    /// hands travel on arcs around the shoulder and elbow. A curl seen from
    /// the front comes straight at you, so it stays a straight line.
    private var armsSwing: Bool {
        switch self {
        case .overheadPress, .lateralRaise, .pullDown, .benchPress, .skullCrusher: return true
        default: return false
        }
    }

    /// 0 = start pose, 1 = end pose, `t` seconds in.
    private func progress(at t: Float) -> Float {
        let cycle = max(t, 0) / repSeconds
        let rep = floor(cycle)
        return OneBodyMotion.repTempo(cycle - rep, lowersFirst: lowersFirst,
                                      variation: OneBodyMotion.variation(rep))
    }

    func frame(at t: Float, gear: Gear) -> BodyPose {
        if self == .swing {
            // A pendulum, not a lift: the hips snap the bell up to chest
            // height and it falls back between the legs on its own.
            return pose(time: t, gear: gear) { lag in (1 - cos((t - lag) / repSeconds * 2 * .pi)) / 2 }
        }
        return pose(time: t, gear: gear) { lag in progress(at: t - lag) }
    }

    /// Held still at `p` (0 = start, 1 = end of the rep) — a coach pausing
    /// in a position to point something out. Still breathing.
    func frame(holding p: Float, time t: Float, gear: Gear) -> BodyPose {
        pose(time: t, gear: gear) { _ in min(max(p, 0), 1) }
    }

    /// The pose for `depth(lag)`: how far into the rep the body was `lag`
    /// seconds ago (0 = now) — trailing parts look back a little.
    private func pose(time t: Float, gear: Gear, depth: (Float) -> Float) -> BodyPose {
        let p = depth(0)
        var joints: [Joint]
        switch self {
        case .pushups:
            // The chest leads; hips and head follow a beat behind.
            joints = OneBodyMotion.plank(p, hipDepth: depth(0.06), headDepth: depth(0.1))
        case .plank:
            let breath = (OneBodyMotion.breathing(t) + 1) / 2 * 0.05
            joints = OneBodyMotion.plank(0, hipDepth: breath, headDepth: breath * 0.5)
        case .squat:
            // Built at the exact depth rather than blended, so the torso
            // rotates and the legs fold instead of shrinking.
            joints = Self.squatPose(depth: p, lag: depth(0.08), gear: gear)
        case .hinge:
            joints = Self.hingePose(depth: p)
        case .swing:
            // At the bottom the arms hike back through the thighs.
            joints = Self.hingePose(depth: p * 0.8, armAngle: -0.15 - depth(0.076) * 2.15)
        default:
            let (a, b) = poses(at: t)
            var j = blend(a, b, p)
            if side == 0 {
                // Two arms are never in perfect step.
                let trailing = blend(a, b, depth(0.05))
                for i in 6...8 { j[i] = trailing[i] }
            }
            joints = j
        }
        if gear == .pullupBar {
            // The bar stays put and the body rises to it.
            let grip = (joints[5].y + joints[8].y) / 2
            let rise = 0.66 - grip
            for i in joints.indices { joints[i].y += rise }
        }
        return BodyPose(joints: joints, form: 1, side: side, label: "",
                        gear: gear, bench: self == .benchPress || self == .skullCrusher)
    }

    /// Straight-line blend for the body; for swinging arms, each bone turns
    /// the short way round instead, so arm lengths hold and hands draw arcs.
    private func blend(_ a: [Joint], _ b: [Joint], _ p: Float) -> [Joint] {
        var out = zip(a, b).map { $0 + ($1 - $0) * p }
        guard armsSwing else { return out }
        for (shoulder, elbow, hand) in [(3, 4, 5), (6, 7, 8)] {
            let upper = Self.swing(a[elbow] - a[shoulder], b[elbow] - b[shoulder], p)
            let fore = Self.swing(a[hand] - a[elbow], b[hand] - b[elbow], p)
            out[elbow] = Joint(out[shoulder].x + upper.x, out[shoulder].y + upper.y, out[elbow].z)
            out[hand] = Joint(out[elbow].x + fore.x, out[elbow].y + fore.y, out[hand].z)
        }
        return out
    }

    private static func swing(_ from: Joint, _ to: Joint, _ p: Float) -> SIMD2<Float> {
        let start = atan2(from.y, from.x)
        var turn = atan2(to.y, to.x) - start
        if turn > .pi { turn -= 2 * .pi } else if turn < -.pi { turn += 2 * .pi }
        let angle = start + turn * p
        let length = hypot(from.x, from.y) + (hypot(to.x, to.y) - hypot(from.x, from.y)) * p
        return SIMD2(cos(angle), sin(angle)) * length
    }

    /// (start, end) of one rep. Standing lifts keep breathing underneath.
    private func poses(at t: Float) -> ([Joint], [Joint]) {
        switch self {
        case .overheadPress:
            return (front(t, elbow: [-0.30, 0.10], hand: [-0.30, 0.30]),
                    front(t, elbow: [-0.22, 0.46], hand: [-0.19, 0.68], tall: 0.012))
        case .lateralRaise:
            return (front(t, elbow: [-0.22, 0.08], hand: [-0.25, -0.08]),
                    front(t, elbow: [-0.38, 0.25], hand: [-0.59, 0.25]))
        case .curl:
            return (front(t, elbow: [-0.21, 0.06], hand: [-0.23, -0.13]),
                    front(t, elbow: [-0.20, 0.07], hand: [-0.20, 0.25]))
        case .tricepExtension:
            return (front(t, elbow: [-0.13, 0.48], hand: [-0.10, 0.30]),
                    front(t, elbow: [-0.13, 0.48], hand: [-0.11, 0.70], tall: 0.008))
        case .pullDown:
            return (front(t, elbow: [-0.30, 0.45], hand: [-0.36, 0.66]),
                    front(t, elbow: [-0.37, 0.15], hand: [-0.32, 0.36], tall: -0.012))
        case .squat:
            return (Self.squatPose(depth: 0, lag: 0, gear: .none), Self.squatPose(depth: 1, lag: 1, gear: .none))
        case .hinge, .swing:
            return (Self.hingePose(depth: 0), Self.hingePose(depth: 1))
        case .benchPress:
            return (lying(elbow: [-0.21, 0.10], hand: [-0.20, 0.32]),
                    lying(elbow: [-0.27, -0.06], hand: [-0.18, 0.02]))
        case .skullCrusher:
            return (lying(elbow: [-0.22, 0.20], hand: [-0.21, 0.42]),
                    lying(elbow: [-0.20, 0.21], hand: [-0.37, 0.10]))
        case .pushups, .plank:
            return (OneBodyMotion.plank(0), OneBodyMotion.plank(0))
        }
    }

    // MARK: - Pose builders

    /// Standing, front-on, breathing, with both arms set symmetrically from
    /// the left arm's elbow and hand. `tall` lifts the chest and head a touch
    /// as the lift braces (or sinks them on a pull).
    private func front(_ t: Float, elbow: [Float], hand: [Float], tall: Float = 0) -> [Joint] {
        var j = OneBodyMotion.standing(t)
        j[0].y += tall; j[1].y += tall * 0.6
        j[4] = Joint(elbow[0], elbow[1], 0.105)
        j[5] = Joint(hand[0], hand[1], 0.10)
        j[7] = Joint(-elbow[0], elbow[1], 0.105)
        j[8] = Joint(-hand[0], hand[1], 0.10)
        return j
    }

    /// Side-on squat, the way a coach shows it: hips sit back and down to
    /// parallel, knees travel forward over the toes, heels stay down, the
    /// chest leans in. The arms depend on what's held: reaching forward for
    /// balance with nothing (a beat behind the hips — `lag` is the depth a
    /// moment ago), a bar across the upper back, a bell at the chest, or
    /// dumbbells hanging at the sides.
    private static func squatPose(depth d: Float, lag: Float, gear: Gear) -> [Joint] {
        func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
        let hip = SIMD2<Float>(mix(-0.02, -0.16, d), mix(0.005, -0.20, d))
        let tilt = mix(0.06, 0.62, d)
        let spine = SIMD2<Float>(sin(tilt), cos(tilt))
        let forward = SIMD2<Float>(spine.y, -spine.x)
        func along(_ length: Float) -> SIMD2<Float> { hip + spine * length }
        let chest = along(0.255), head = along(0.49), shoulder = along(0.235)
        func arm(_ offset: Float) -> (Joint, Joint, Joint) {
            let s = shoulder + SIMD2(offset, 0)
            let elbow: SIMD2<Float>, hand: SIMD2<Float>
            switch gear {
            case .barbell:
                // Hands on the bar just behind the neck, elbows down.
                hand = s - forward * 0.07 + spine * 0.03
                elbow = s - forward * 0.05 - spine * 0.17
            case .dumbbell, .kettlebell:
                // Goblet: the bell held at the chest, elbows tucked under.
                hand = s + forward * 0.13 - spine * 0.06
                elbow = s + forward * 0.06 - spine * 0.17
            case .dumbbells:
                // Hanging straight down at the sides.
                elbow = s + SIMD2(0.01, -0.18)
                hand = s + SIMD2(0.02, -0.35)
            default:
                // Hanging (-90°) to reaching straight ahead.
                let reach = mix(-1.5, -0.08, lag)
                elbow = s + SIMD2(cos(reach), sin(reach)) * 0.2
                hand = elbow + SIMD2(cos(reach + 0.12), sin(reach + 0.12)) * 0.19
            }
            return (Joint(s.x, s.y, 0.10), Joint(elbow.x, elbow.y, 0.085), Joint(hand.x, hand.y, 0.09))
        }
        let back = arm(0), front = arm(0.03)
        let backKnee = knee(hip: hip, foot: SIMD2(0.0, -0.385))
        let frontKnee = knee(hip: hip, foot: SIMD2(0.04, -0.385))
        return [
            Joint(head.x, head.y, 0.165), Joint(chest.x, chest.y, 0.185), Joint(hip.x, hip.y, 0.17),
            back.0, back.1, back.2,
            front.0, front.1, front.2,
            Joint(backKnee.x, backKnee.y, 0.115), Joint(0.0, -0.385, 0.11),
            Joint(frontKnee.x, frontKnee.y, 0.115), Joint(0.04, -0.385, 0.11),
        ]
    }

    /// Side-on hip hinge: the hips push back and the torso tips forward
    /// around them as one rigid piece, knees soft, arms hanging straight
    /// down to mid-shin. Bone lengths hold at every depth.
    private static func hingePose(depth d: Float, armAngle: Float? = nil) -> [Joint] {
        func mix(_ a: Float, _ b: Float) -> Float { a + (b - a) * d }
        let hip = SIMD2<Float>(mix(-0.02, -0.13), mix(0.005, -0.035))
        let tilt = mix(0.06, 1.12)
        let spine = SIMD2<Float>(sin(tilt), cos(tilt))
        func along(_ length: Float) -> SIMD2<Float> { hip + spine * length }
        let chest = along(0.255), head = along(0.49), shoulder = along(0.235)
        func leg(_ foot: SIMD2<Float>) -> Joint {
            let knee = knee(hip: hip, foot: foot)
            return Joint(knee.x, knee.y, 0.115)
        }
        // Straight arms at `armAngle` (a swing), or hanging plumb.
        let angle = armAngle ?? -Float.pi / 2 + 0.06
        let elbowAt = SIMD2<Float>(cos(angle), sin(angle)) * 0.18
        let handAt = SIMD2<Float>(cos(angle + 0.04), sin(angle + 0.04)) * 0.35
        return [
            Joint(head.x + 0.02 * d, head.y, 0.165),
            Joint(chest.x, chest.y, 0.185),
            Joint(hip.x, hip.y, 0.17),
            Joint(shoulder.x, shoulder.y, 0.10),
            Joint(shoulder.x + elbowAt.x, shoulder.y + elbowAt.y, 0.085),
            Joint(shoulder.x + handAt.x, shoulder.y + handAt.y, 0.09),
            Joint(shoulder.x + 0.03, shoulder.y, 0.10),
            Joint(shoulder.x + 0.03 + elbowAt.x, shoulder.y + elbowAt.y, 0.085),
            Joint(shoulder.x + 0.03 + handAt.x, shoulder.y + handAt.y, 0.09),
            leg(SIMD2(0.0, -0.385)), Joint(0.0, -0.385, 0.11),
            leg(SIMD2(0.04, -0.385)), Joint(0.04, -0.385, 0.11),
        ]
    }

    /// Two-bone leg IK, knee bending forward, thigh and shin 0.2 each.
    private static func knee(hip: SIMD2<Float>, foot: SIMD2<Float>) -> SIMD2<Float> {
        let bone: Float = 0.2
        let delta = foot - hip
        let distance = min(max(simd_length(delta), 0.0001), bone * 2 - 0.0001)
        let direction = delta / max(simd_length(delta), 0.0001)
        let bend = sqrt(max(0, bone * bone - distance * distance / 4))
        // Perpendicular pointing forward (+x) for a downward leg.
        let forward = SIMD2<Float>(-direction.y, direction.x)
        return hip + direction * (distance / 2) + forward * bend
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
    static let cheerSeconds: Float = 2.8

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

    /// A quick dip to wind up, then arms up in a V with a couple of hops
    /// that die away, or a fist pumped twice. The body's springs supply the
    /// overshoot; these are just the targets.
    static func cheer(at t: Float, style: Int) -> BodyPose {
        var j = OneBodyMotion.standing(t)
        let windUp: Float = 0.22
        if t < windUp {
            let dip = sin(t / windUp * .pi / 2) * 0.05
            for i in 0...8 { j[i].y -= dip }
            j[9].x -= dip * 0.4; j[11].x += dip * 0.4
            j[9].y -= dip * 0.4; j[11].y -= dip * 0.4
            j[5] = Joint(-0.30, -0.10 - dip, 0.10); j[8] = Joint(0.30, -0.10 - dip, 0.10)
            return BodyPose(joints: j, form: 1, side: 0, label: "")
        }
        let s = t - windUp
        let decay = exp(-s * 1.5)
        let wave = sin(s * 8.5)
        // Off the ground on the up half, knees soaking it up on the landing.
        let hop = max(0, wave) * 0.045 * decay
        let land = min(0, wave) * 0.025 * decay
        for i in j.indices { j[i].y += hop }
        for i in 0...8 { j[i].y += land }
        if style == 0 {
            // Both arms up — "yes!"
            j[4] = Joint(-0.27, 0.44 + hop + land, 0.10); j[5] = Joint(-0.36, 0.66 + hop + land, 0.10)
            j[7] = Joint(0.27, 0.44 + hop + land, 0.10);  j[8] = Joint(0.36, 0.66 + hop + land, 0.10)
        } else {
            // A fist punched up twice — quick up, easing back — the other
            // arm tucked in.
            let beat = s * 1.7
            let x = beat - floor(beat)
            let punch = (x < 0.22 ? sin(x / 0.22 * .pi / 2) : 1 - (x - 0.22) / 0.78 * 0.8) * (beat < 2 ? 1 : 0.6)
            j[7] = Joint(0.26, 0.30 + punch * 0.12 + land, 0.10)
            j[8] = Joint(0.29, 0.42 + punch * 0.22 + land, 0.11)
            j[4] = Joint(-0.24, 0.08 + land, 0.105); j[5] = Joint(-0.19, 0.16 + land, 0.10)
        }
        return BodyPose(joints: j, form: 1, side: 0, label: "")
    }
}
