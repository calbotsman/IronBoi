import Foundation
import simd

/// A move written as data rather than code: a few key poses, how it moves
/// between them, what it holds, and how Coach teaches it. The poses are in
/// `Rig` terms (where the hips are, how the spine leans, the arm angles or
/// where the hands go, where the feet are), so bone lengths always hold and
/// knees and elbows are solved, whoever wrote the numbers. Codable, so a
/// move can come from the server as well as from `MoveLibrary`.
///
/// Units are the body's joint space: hips near the origin, y up, the floor
/// at -0.385. Angles are degrees, 0 = +x on screen, 90 = up.
struct MoveSpec: Codable, Equatable {
    /// Seen from the side (facing +x) when the body travels, from the front
    /// when the arms or legs move across.
    enum View: String, Codable { case side, front }

    /// How a rep moves through the keys. `rep`: out and back with a lifter's
    /// tempo (a slow lowering, a beat at the turn, a quicker drive). `wave`:
    /// a smooth back-and-forth with no pauses — jacks, climbers, a carry.
    enum Tempo: String, Codable { case rep, wave }

    struct Key: Codable, Equatable {
        var hip: [Float]
        /// Spine angle from vertical, toward +x.
        var tilt: Float = 0
        /// The head's extra turn from the spine.
        var nod: Float? = nil
        /// (upper arm, forearm) angles per arm, back/left arm first. Front
        /// moves with `mirror` on give the left arm only.
        var arms: [[Float]]? = nil
        /// Or where the hands are, elbows solved and bending toward `bend`.
        var hands: [[Float]]? = nil
        var bend: [Float]? = nil
        /// Feet, back/left first. Knees are solved.
        var feet: [[Float]]
        /// Shoulders and arms raised this far (a shrug).
        var shrug: Float? = nil
    }

    struct Lesson: Codable, Equatable {
        var line: String
        /// Ease into this point of the rep and hold; nil = show reps.
        var at: Float? = nil
    }

    var id: String
    /// Phrases that mean this move, lowercase, matched as whole words.
    var names: [String]
    var view: View
    /// What it usually holds when the name doesn't say (see `Gear`).
    var gear: String = "none"
    /// False when the move can't hold what a name mentions (a bridge).
    var takesGear = true
    var seconds: Float
    var tempo: Tempo = .rep
    /// Rep moves: starts at the top and lowers first (a squat), else drives
    /// first (a curl).
    var lowersFirst = false
    /// Front moves: the right arm is the left arm's mirror image.
    var mirror = true
    /// A little hop at the middle of each rep (jumping jacks).
    var hop: Float? = nil
    /// Heavy enough to rest ninety seconds between sets, not sixty.
    var heavy = false
    var keys: [Key]
    var lesson: [Lesson]
    var cues: [String]

    static func == (a: MoveSpec, b: MoveSpec) -> Bool { a.id == b.id }

    var defaultGear: Gear {
        switch gear {
        case "dumbbells": return .dumbbells
        case "dumbbell": return .dumbbell
        case "barbell": return .barbell
        case "kettlebell": return .kettlebell
        default: return .none
        }
    }

    /// Whether the numbers describe a body that can be drawn: sane ranges,
    /// two to eight keys, feet on or above the floor. A move from outside
    /// the app is checked before it's used.
    var isValid: Bool {
        guard (2...8).contains(keys.count), (0.6...8).contains(seconds), !names.isEmpty,
              (1...6).contains(lesson.count), (1...6).contains(cues.count) else { return false }
        let armCount = view == .front && mirror ? 1 : 2
        func numbers(_ v: [Float]?, _ count: Int, within bound: Float) -> Bool {
            guard let v else { return true }
            return v.count == count && v.allSatisfy { $0.isFinite && abs($0) <= bound }
        }
        return keys.allSatisfy { key in
            guard numbers(key.hip, 2, within: 0.7), key.tilt.isFinite, abs(key.tilt) <= 200,
                  abs(key.nod ?? 0) <= 90, abs(key.shrug ?? 0) <= 0.1, numbers(key.bend, 2, within: 1),
                  key.feet.count == 2,
                  key.feet.allSatisfy({ numbers($0, 2, within: 0.9) && $0[1] >= Rig.floor - 0.01 })
            else { return false }
            if let arms = key.arms {
                return arms.count == armCount && arms.allSatisfy { numbers($0, 2, within: 360) }
            }
            if let hands = key.hands {
                return hands.count == armCount && hands.allSatisfy { numbers($0, 2, within: 0.9) }
            }
            return false
        }
    }

    // MARK: - Playing it

    /// How far into the rep the body is (0 = the first key, 1 = the last)
    /// `t` seconds in.
    func progress(at t: Float) -> Float {
        switch tempo {
        case .wave:
            return (1 - cos(max(t, 0) / seconds * 2 * .pi)) / 2
        case .rep:
            let cycle = max(t, 0) / seconds
            let rep = floor(cycle)
            return OneBodyMotion.repTempo(cycle - rep, lowersFirst: lowersFirst,
                                          variation: OneBodyMotion.variation(rep))
        }
    }

    func pose(progress p: Float, time t: Float, gear: Gear) -> BodyPose {
        let p = min(max(p, 0), 1)
        let u = p * Float(keys.count - 1)
        let index = min(Int(u), keys.count - 2)
        var joints = joints(for: Self.blend(keys[index], keys[index + 1], u - Float(index)))
        // Still breathing underneath.
        let breath = OneBodyMotion.breathing(t) * 0.012
        for i in [0, 1, 3, 4, 5, 6, 7, 8] { joints[i].y += breath }
        if let hop {
            let up = sin(p * .pi) * hop
            for i in joints.indices { joints[i].y += up }
        }
        return BodyPose(joints: joints, form: 1, side: view == .side ? 1 : 0, label: "", gear: gear)
    }

    /// Positions blend straight; angles take the short way round, so arms
    /// draw arcs and keep their length.
    private static func blend(_ a: Key, _ b: Key, _ t: Float) -> Key {
        func mix(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        func angle(_ x: Float, _ y: Float) -> Float {
            var d = (y - x).truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 } else if d < -180 { d += 360 }
            return x + d * t
        }
        func pairs(_ x: [[Float]]?, _ y: [[Float]]?, _ f: (Float, Float) -> Float) -> [[Float]]? {
            guard let x, let y, x.count == y.count else { return x ?? y }
            return zip(x, y).map { zip($0, $1).map(f) }
        }
        var out = a
        out.hip = zip(a.hip, b.hip).map(mix)
        out.tilt = angle(a.tilt, b.tilt)
        out.nod = mix(a.nod ?? 0, b.nod ?? 0)
        out.arms = pairs(a.arms, b.arms, angle)
        out.hands = pairs(a.hands, b.hands, mix)
        out.bend = pairs(a.bend.map { [$0] }, b.bend.map { [$0] }, mix)?.first
        out.feet = pairs(a.feet, b.feet, mix) ?? a.feet
        out.shrug = mix(a.shrug ?? 0, b.shrug ?? 0)
        return out
    }

    private func joints(for key: Key) -> [Joint] {
        func rad(_ degrees: Float) -> Float { degrees * .pi / 180 }
        let hip = SIMD2(key.hip[0], key.hip[1])
        let feet = key.feet.map { SIMD2($0[0], max($0[1], Rig.floor)) }
        var arms: [(Float, Float)] = (key.arms ?? [[-90, -90], [-90, -90]]).map { (rad($0[0]), rad($0[1])) }
        if arms.count == 1 { arms.append((.pi - arms[0].0, .pi - arms[0].1)) }
        var j = view == .side
            ? Rig.side(hip: hip, tilt: rad(key.tilt), nod: rad(key.nod ?? 0), arms: arms, feet: feet)
            : Rig.front(hip: hip, lean: rad(key.tilt), nod: key.nod ?? 0, arms: arms, feet: feet)
        if var hands = key.hands?.map({ SIMD2($0[0], $0[1]) }) {
            if hands.count == 1 { hands.append(SIMD2(-hands[0].x, hands[0].y)) }
            let bend = key.bend.map { SIMD2($0[0], $0[1]) } ?? (view == .side ? SIMD2(-1, -0.3) : SIMD2(-1, 0))
            let (upper, lower): (Float, Float) = view == .side ? (0.2, 0.19) : (0.17, 0.17)
            for (k, base) in [3, 6].enumerated() {
                let shoulder = SIMD2(j[base].x, j[base].y)
                // The right arm bends the mirror way.
                let toward = view == .front && k == 1 ? SIMD2(-bend.x, bend.y) : bend
                // A hand out of reach goes as far as the arm does.
                let reach = hands[k] - shoulder
                let hand = simd_length(reach) > upper + lower - 0.001
                    ? shoulder + simd_normalize(reach) * (upper + lower - 0.001) : hands[k]
                let elbow = Rig.middle(shoulder, hand, upper, lower, toward: toward)
                j[base + 1] = Joint(elbow.x, elbow.y, j[base + 1].z)
                j[base + 2] = Joint(hand.x, hand.y, j[base + 2].z)
            }
        }
        if let shrug = key.shrug, shrug != 0 {
            for i in 3...8 { j[i].y += shrug }
        }
        return j
    }
}
