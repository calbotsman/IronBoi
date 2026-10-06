import Foundation
import simd

/// The coach's body vocabulary: moves it can step into and demonstrate.
/// A port of orb-lab's authored motion (src/variants/one-body-motion.ts).
/// Joint positions are in the orb's own space (blob centre at the origin,
/// y up); the shader blends the blob's distance field into this skeleton, so
/// it stays one soft material the whole time.
///
/// Joints: 0 head, 1 chest, 2 hips, 3–5 back arm (shoulder, elbow, hand),
/// 6–8 front arm, 9–10 one leg (knee, foot), 11–12 the other.
typealias Joint = SIMD3<Float> // x, y, radius

enum BodyMove: String, CaseIterable {
    case pushups
    case plank

    var name: String {
        switch self {
        case .pushups: return "Push-ups"
        case .plank: return "Plank"
        }
    }

    var duration: Float {
        switch self {
        case .pushups: return OneBodyMotion.pushupDuration
        case .plank: return OneBodyMotion.plankDuration
        }
    }

    func frame(at t: Float, reducedMotion: Bool) -> BodyPose {
        switch self {
        case .pushups: return OneBodyMotion.pushupFrame(t, reducedMotion: reducedMotion)
        case .plank: return OneBodyMotion.plankFrame(t, reducedMotion: reducedMotion)
        }
    }
}

struct BodyPose {
    var joints: [Joint]
    /// 0 = blob, 1 = person.
    var form: Float
    /// How side-on the figure is; drives the tucked-arm shading.
    var side: Float
    var label: String
    /// What's held, and whether there's a bench underneath.
    var gear: Gear = .none
    var bench = false
}

enum OneBodyMotion {
    static let pushupStart: Float = 5.2
    static let repDuration: Float = 2.6
    static let pushupEnd: Float = pushupStart + repDuration * 3
    static let pushupDuration: Float = 19.2
    static let plankHoldEnd: Float = 13.2
    static let plankDuration: Float = 19.2

    private static func smooth(_ x: Float) -> Float {
        let t = min(max(x, 0), 1)
        return min(max(t * t * t * (t * (t * 6 - 15) + 10), 0), 1)
    }

    private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

    static func standing(_ time: Float = 0) -> [Joint] {
        // Breathing in is quicker than breathing out, and the weight drifts
        // rather than swings: hips shift, the chest and head carry on past
        // them, and the hands don't hang in perfect step.
        let breath = breathing(time) * 0.016
        let sway = (sin(time * 0.85) * 0.6 + sin(time * 0.37 + 1.3) * 0.3 + sin(time * 1.9 + 0.4) * 0.1) * 0.02
        let drift = sin(time * 0.53 + 2.1) * 0.006
        return [
            Joint(sway * 1.3, 0.50 + breath, 0.165), Joint(sway, 0.26 + breath, 0.185), Joint(sway * 0.45, 0.005, 0.17),
            Joint(-0.16 + sway, 0.24 + breath, 0.10), Joint(-0.24 + sway * 0.5, 0.10, 0.105), Joint(-0.275 + drift, -0.065 + breath * 0.5, 0.10),
            Joint(0.16 + sway, 0.24 + breath, 0.10), Joint(0.25 + sway * 0.5, 0.10, 0.105), Joint(0.275 + drift * 0.6, -0.065 - breath * 0.4, 0.10),
            Joint(-0.13 + sway * 0.2, -0.19, 0.115), Joint(-0.15, -0.385, 0.11), Joint(0.13 + sway * 0.2, -0.19, 0.115), Joint(0.15, -0.385, 0.11),
        ]
    }

    /// -1…1 over a ~4.6 s breath: in over 40% of it, out over the rest.
    static func breathing(_ time: Float) -> Float {
        let x = time / 4.6 - floor(time / 4.6)
        return x < 0.4 ? smooth(x / 0.4) * 2 - 1 : 1 - smooth((x - 0.4) / 0.6) * 2
    }

    /// How far into one rep a lifter is (0 = start pose, 1 = end pose) at
    /// `x`, the fraction of the rep elapsed. The lowering is slow and
    /// controlled, there's a beat at the turn, and the drive is quicker —
    /// how a coach would show it, not a metronome. `variation` (0…1, one
    /// value per rep) nudges the timing so no two reps are identical.
    static func repTempo(_ x: Float, lowersFirst: Bool, variation: Float) -> Float {
        let v = variation - 0.5
        if lowersFirst {
            // Hold at the top, lower, pause at the bottom, drive, settle.
            let lowerEnd = 0.54 + v * 0.06
            let driveStart = lowerEnd + 0.08
            let driveEnd = driveStart + 0.25 + v * 0.05
            if x < 0.05 { return 0 }
            if x < lowerEnd { return smooth((x - 0.05) / (lowerEnd - 0.05)) }
            if x < driveStart { return 1 }
            if x < driveEnd { return 1 - drive((x - driveStart) / (driveEnd - driveStart)) }
            return 0
        }
        // Drive, squeeze at the top, lower slowly, a breath at the bottom.
        let driveEnd = 0.31 + v * 0.05
        let lowerStart = driveEnd + 0.10
        if x < 0.05 { return 0 }
        if x < driveEnd { return drive((x - 0.05) / (driveEnd - 0.05)) }
        if x < lowerStart { return 1 }
        if x < 0.93 { return 1 - smooth((x - lowerStart) / (0.93 - lowerStart)) }
        return 0
    }

    /// The push: gets moving early and decelerates into lockout.
    private static func drive(_ x: Float) -> Float {
        smooth(pow(min(max(x, 0), 1), 0.75))
    }

    /// A stable 0…1 per rep, so each rep's variation holds still while it plays.
    static func variation(_ rep: Float) -> Float {
        let s = sin(rep * 12.9898 + 78.233) * 43758.5453
        return s - floor(s)
    }

    static func crouching() -> [Joint] {
        [
            Joint(0.23, 0.15, 0.165), Joint(0.075, -0.045, 0.18), Joint(-0.17, -0.13, 0.165),
            Joint(0.04, -0.025, 0.10), Joint(0.06, -0.18, 0.085), Joint(0.20, -0.385, 0.095),
            Joint(0.16, -0.045, 0.10), Joint(0.19, -0.19, 0.085), Joint(0.34, -0.385, 0.095),
            Joint(-0.31, -0.25, 0.11), Joint(-0.38, -0.385, 0.10), Joint(-0.055, -0.29, 0.11), Joint(0.04, -0.385, 0.10),
        ]
    }

    /// Two-bone IK: keeps upper arm and forearm lengths, bending rearward.
    private static func elbow(_ shoulder: Joint, _ hand: Joint) -> Joint {
        let dx = hand.x - shoulder.x, dy = hand.y - shoulder.y
        let distance = max(0.00001, hypot(dx, dy))
        let upper: Float = 0.235, forearm: Float = 0.22
        let reach = max(upper - forearm + 0.00001, min(upper + forearm - 0.00001, distance))
        let along = (upper * upper - forearm * forearm + reach * reach) / (2 * reach)
        let bend = sqrt(max(0, upper * upper - along * along))
        return Joint(shoulder.x + dx / distance * along + dy / distance * bend,
                     shoulder.y + dy / distance * along - dx / distance * bend, 0.075)
    }

    static func plank(_ depth: Float, hipDepth: Float? = nil, headDepth: Float? = nil) -> [Joint] {
        let hipDepth = hipDepth ?? depth, headDepth = headDepth ?? depth
        let y = mix(0.055, -0.13, depth)
        let hipY = mix(-0.065, -0.225, hipDepth)
        // A modest forward weight shift lets elbows fold toward the ribs.
        let shift = depth * 0.20 + sin(depth * .pi) * 0.01
        let backShoulder = Joint(0.18 + shift, y + 0.005, 0.10)
        let frontShoulder = Joint(0.275 + shift, y, 0.10)
        let backHand = Joint(0.20, -0.385, 0.095)
        let frontHand = Joint(0.34, -0.385, 0.095)
        return [
            Joint(0.46 + shift, mix(0.195, 0.015, headDepth), 0.16), Joint(0.225 + shift, y, 0.175), Joint(-0.20 + shift * 0.4, hipY, 0.155),
            backShoulder, elbow(backShoulder, backHand), backHand,
            frontShoulder, elbow(frontShoulder, frontHand), frontHand,
            Joint(-0.43, (hipY - 0.385) / 2 + 0.018, 0.11), Joint(-0.65, -0.385, 0.095),
            Joint(-0.35, (hipY - 0.385) / 2 + 0.018, 0.11), Joint(-0.54, -0.385, 0.095),
        ]
    }

    /// A continuous Catmull-Rom curve through poses. Going down, hands lead
    /// and the heavier middle and head follow; coming up, the reverse.
    static func flow(_ poses: [[Joint]], _ progress: Float, rising: Bool = false) -> [Joint] {
        let delays: [Float] = rising
            ? [0.075, 0.045, 0, 0.06, 0.08, 0.11, 0.06, 0.08, 0.11, 0.01, 0, 0.01, 0]
            : [0.055, 0.04, 0.08, 0.015, 0, 0, 0.015, 0, 0, 0.085, 0.095, 0.085, 0.095]
        return poses[0].indices.map { joint in
            let u = smooth((progress - delays[joint]) / (1 - delays[joint])) * Float(poses.count - 1)
            let segment = min(poses.count - 2, Int(u)), t = u - Float(segment)
            let a = poses[max(0, segment - 1)][joint], b = poses[segment][joint]
            let c = poses[segment + 1][joint], d = poses[min(poses.count - 1, segment + 2)][joint]
            let c1: Joint = c - a
            let c2: Joint = 2 * a - 5 * b + 4 * c - d
            let c3: Joint = 3 * b - a - 3 * c + d
            let t2: Float = t * t
            var result: Joint = 2 * b + c1 * t
            result += c2 * t2 + c3 * (t2 * t)
            result *= 0.5
            if [5, 8, 10, 12].contains(joint) { result.y = max(-0.385, result.y) }
            return result
        }
    }

    static func pushupFrame(_ t: Float, reducedMotion: Bool) -> BodyPose {
        let stand = standing(t)
        if reducedMotion {
            return BodyPose(joints: standing(), form: 1, side: 0, label: "Push-ups · motion reduced")
        }
        let form = smooth(t / 2) * (1 - smooth((t - 16.2) / 3))
        if t < 1.8 { return BodyPose(joints: stand, form: form, side: 0, label: "Taking shape") }
        if t < pushupStart {
            let progress = (t - 1.8) / (pushupStart - 1.8)
            return BodyPose(joints: flow([stand, crouching(), plank(0)], progress), form: form,
                            side: smooth(progress), label: progress < 0.5 ? "Hands down" : "Find a plank")
        }
        if t < pushupEnd {
            let cycle = (t - pushupStart) / repDuration
            let depth = repTempo(cycle - floor(cycle), lowersFirst: true, variation: variation(floor(cycle)))
            // A small wave travels through the mass while contacts stay planted.
            let envelope = pow(sin(cycle * .pi / 3), 2)
            let wave = sin(cycle * .pi * 2) * envelope
            let hip = min(max(depth - wave * 0.065, 0), 1)
            let head = min(max(depth - wave * 0.11, 0), 1)
            let rep = min(3, Int(cycle) + 1)
            let phase = cycle.truncatingRemainder(dividingBy: 1) < 0.58 ? "Lower" : "Push away"
            return BodyPose(joints: plank(depth, hipDepth: hip, headDepth: head), form: form, side: 1,
                            label: "\(rep) / 3 · \(phase)")
        }
        if t < 16.8 {
            let progress = (t - pushupEnd) / (16.8 - pushupEnd)
            return BodyPose(joints: flow([plank(0), crouching(), stand], progress, rising: true), form: form,
                            side: 1 - smooth(progress), label: "And back up")
        }
        return BodyPose(joints: stand, form: form, side: 0, label: "Back to a blob")
    }

    /// The push-up's way in and out, with an eight-second breathing hold.
    static func plankFrame(_ t: Float, reducedMotion: Bool) -> BodyPose {
        let stand = standing(t)
        if reducedMotion {
            return BodyPose(joints: standing(), form: 1, side: 0, label: "Plank · motion reduced")
        }
        let form = smooth(t / 2) * (1 - smooth((t - 16.2) / 3))
        if t < 1.8 { return BodyPose(joints: stand, form: form, side: 0, label: "Taking shape") }
        if t < pushupStart {
            let progress = (t - 1.8) / (pushupStart - 1.8)
            return BodyPose(joints: flow([stand, crouching(), plank(0)], progress), form: form,
                            side: smooth(progress), label: progress < 0.5 ? "Hands down" : "Find a plank")
        }
        if t < plankHoldEnd {
            // Long and still; only the breath moves, a little sag and lift.
            let breath = (breathing(t - pushupStart) + 1) / 2 * 0.05
            let left = Int(ceil(plankHoldEnd - t))
            return BodyPose(joints: plank(0, hipDepth: breath, headDepth: breath * 0.5), form: form, side: 1,
                            label: "Hold · \(left)")
        }
        if t < 16.8 {
            let progress = (t - plankHoldEnd) / (16.8 - plankHoldEnd)
            return BodyPose(joints: flow([plank(0), crouching(), stand], progress, rising: true), form: form,
                            side: 1 - smooth(progress), label: "And back up")
        }
        return BodyPose(joints: stand, form: form, side: 0, label: "Back to a blob")
    }
}

/// Finds a move worth demonstrating in what was said — yours or Coach's.
/// Port of orb-lab's BodyCue: only an affirmative, instructional sentence
/// fires ("let's do push-ups", "show me a plank"); negated or conditional
/// mentions ("don't do push-ups", "if you can plank") never do.
enum MoveCue {
    private static let patterns: [(BodyMove, String)] = [
        // Push-ups first: a push-up instruction mentions "plank" too.
        (.pushups, #"\bpush[\s-]*ups?\b"#),
        (.plank, #"\bplanks?\b"#),
    ]
    private static let negation = #"\b(not|no|never|avoid|skip|stop|don't|dont|cannot|can't|shouldn't|shouldnt|won't|wouldn't|if|whether)\b"#
    private static let affirmative = #"\b(let'?s|let us|do|try|show|start|begin|demonstrate|how)\b"#

    static func move(in text: String) -> BodyMove? {
        let normalized = text.lowercased().replacingOccurrences(of: "[’‘]", with: "'", options: .regularExpression)
        var sentences: [String] = []
        normalized.enumerateSubstrings(in: normalized.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence { sentences.append(sentence) }
        }
        for sentence in sentences {
            guard matches(sentence, negation) == false, matches(sentence, affirmative) else { continue }
            if let move = patterns.first(where: { matches(sentence, $0.1) })?.0 { return move }
        }
        return nil
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
