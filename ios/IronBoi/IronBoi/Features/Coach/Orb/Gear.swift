import simd

/// What the coach holds while it demonstrates a lift. It grows out of the
/// body when the demonstration starts and melts back in when it ends — the
/// same soft material, so it reads as MYO making the thing it needs.
enum Gear: Equatable {
    case none
    /// One in each hand.
    case dumbbells
    /// One held in both hands: goblet squat, overhead extension.
    case dumbbell
    case barbell
    /// One in each hand, or one between them when the hands meet.
    case kettlebell
    /// A lat-pulldown bar on a cable.
    case cableBar
    /// A fixed bar; the body rises to it.
    case pullupBar

    /// From the exercise's name ("DB", "KB", "Barbell", "Goblet"…), else
    /// what the lift usually means in a gym.
    static func match(_ name: String, lift: Lift) -> Gear {
        let n = " " + name.lowercased().replacingOccurrences(of: "-", with: " ") + " "
        func has(_ words: String...) -> Bool { words.contains { n.contains($0) } }
        if has("bodyweight", "body weight", "air squat") { return .none }
        if has("kettlebell", " kb ") { return .kettlebell }
        if has("goblet") { return .dumbbell }
        if has("dumbbell", " db ", "arnold", "hammer") {
            return lift == .tricepExtension ? .dumbbell : .dumbbells
        }
        if has("barbell", " bb ", " ez ", "zercher") { return .barbell }
        if has("pull up", "pullup", "chin up", "chinup") { return .pullupBar }
        switch lift {
        case .squat: return .barbell
        case .lunge: return .none
        case .hinge, .benchPress, .skullCrusher: return .barbell
        case .overheadPress: return has("shoulder press") ? .dumbbells : .barbell
        case .lateralRaise, .curl: return .dumbbells
        case .tricepExtension: return .dumbbell
        case .swing: return .kettlebell
        case .pullDown: return .cableBar
        case .pushups, .plank: return .none
        }
    }
}

/// One piece of equipment geometry in the orb's joint space. The shader
/// reads 8 floats per shape: kind, a.x, a.y, b.x, b.y, r, angle, depth.
struct GearShape {
    enum Kind: Float {
        /// A stadium from `a` to `b`, radius `r` (a == b is a disc).
        case capsule = 0
        /// A rounded box centred on `a`, half-size `b`, corner `r`, turned by `angle`.
        case box = 1
        /// The upper half of a ring centred on `a`, radius `b.x`, thickness `r`.
        case handle = 2
    }

    var kind: Kind
    var a: SIMD2<Float>
    var b: SIMD2<Float>
    var r: Float
    var angle: Float = 0
    /// Where it sits against the body, front to back.
    var depth: Depth = .held

    enum Depth: Float {
        /// In front of everything, hands included — the near plate of a bar seen end-on.
        case front = 2
        /// In front of the body, behind the fingers wrapped round it.
        case held = 1
        /// Between the legs: behind the near leg (and the hands), in front of
        /// everything else — a kettlebell at the bottom of a swing.
        case between = 0.5
        /// Behind the body — the bench, the cable.
        case behind = -1
    }

    /// Grown out of `anchor`: at 0 it's a point inside the hand, at 1 full size.
    func grown(from anchor: SIMD2<Float>, by g: Float) -> GearShape {
        var out = self
        out.a = anchor + (a - anchor) * g
        switch kind {
        case .capsule: out.b = anchor + (b - anchor) * g
        case .box, .handle: out.b = b * g
        }
        out.r = r * g
        return out
    }

    func scaled(_ s: Float) -> GearShape {
        var out = self
        out.a *= s
        out.b *= s
        out.r *= s
        return out
    }

    var floats: [Float] { [kind.rawValue, a.x, a.y, b.x, b.y, r, angle, depth.rawValue] }

    // MARK: - Equipment

    /// Everything held and stood on for this pose, each piece grown `g` of
    /// the way out of the hand (or the back, for the bench) it comes from.
    static func build(gear: Gear, bench: Bool, sideOn: Bool, joints: [Joint], grow g: Float) -> [GearShape] {
        let left = SIMD2(joints[5].x, joints[5].y), right = SIMD2(joints[8].x, joints[8].y)
        let middle = (left + right) / 2
        var out: [GearShape] = []

        switch gear {
        case .none:
            break
        case .dumbbells:
            for hand in [left, right] {
                out += dumbbell(at: hand, axis: SIMD2(1, 0)).map { $0.grown(from: hand, by: g) }
            }
        case .dumbbell:
            out += dumbbell(at: middle, axis: SIMD2(0, 1)).map { $0.grown(from: middle, by: g) }
        case .barbell:
            if sideOn {
                // End-on: what you see is the plate.
                out.append(GearShape(kind: .capsule, a: middle, b: middle, r: 0.125, depth: .front)
                    .grown(from: middle, by: g))
            } else {
                out += barbell(left, right).map { $0.grown(from: middle, by: g) }
            }
        case .kettlebell:
            let hands = simd_distance(left, right) < 0.12 ? [middle] : [left, right]
            // The bell carries on along the forearm, so it swings with the
            // arms instead of dangling; low and side-on it passes between
            // the legs.
            let elbow = (SIMD2(joints[4].x, joints[4].y) + SIMD2(joints[7].x, joints[7].y)) / 2
            let along = direction(elbow, middle)
            let low = sideOn && middle.y < joints[2].y
            for hand in hands {
                out += kettlebell(at: hand, along: along, depth: low ? .between : .held)
                    .map { $0.grown(from: hand, by: g) }
            }
        case .cableBar, .pullupBar:
            let axis = direction(left, right)
            let reach: Float = gear == .pullupBar ? 0.62 : 0.16
            let ends = (left - axis * reach, right + axis * reach)
            out.append(GearShape(kind: .capsule, a: ends.0, b: ends.1, r: 0.016).grown(from: middle, by: g))
            if gear == .cableBar {
                // The cable runs up off the top of the screen.
                out.append(GearShape(kind: .capsule, a: middle, b: middle + SIMD2(0, 3), r: 0.006, depth: .behind)
                    .grown(from: middle, by: g))
            }
        }

        if bench {
            // Grows down out of the back it's under.
            let back = SIMD2<Float>(-0.16, -0.22)
            out += [
                GearShape(kind: .box, a: SIMD2(-0.16, -0.315), b: SIMD2(0.36, 0.032), r: 0.025, depth: .behind),
                GearShape(kind: .capsule, a: SIMD2(-0.42, -0.33), b: SIMD2(-0.42, -0.48), r: 0.022, depth: .behind),
                GearShape(kind: .capsule, a: SIMD2(0.10, -0.33), b: SIMD2(0.10, -0.48), r: 0.022, depth: .behind),
            ].map { $0.grown(from: back, by: g) }
        }
        return out
    }

    private static func direction(_ from: SIMD2<Float>, _ to: SIMD2<Float>) -> SIMD2<Float> {
        let d = to - from
        let length = simd_length(d)
        return length > 0.05 ? d / length : SIMD2(1, 0)
    }

    /// The icon everyone reads: a short handle with a head at each end.
    private static func dumbbell(at hand: SIMD2<Float>, axis: SIMD2<Float>) -> [GearShape] {
        // Wider than the hand, so the heads stand clear of the fist.
        let half: Float = 0.145
        let angle = atan2(axis.y, axis.x)
        return [
            GearShape(kind: .capsule, a: hand - axis * half, b: hand + axis * half, r: 0.017),
            GearShape(kind: .box, a: hand - axis * half, b: SIMD2(0.036, 0.08), r: 0.02, angle: angle),
            GearShape(kind: .box, a: hand + axis * half, b: SIMD2(0.036, 0.08), r: 0.02, angle: angle),
        ]
    }

    /// Face-on: a long bar through both hands with a big and a small plate
    /// at each end. It tilts if one hand runs ahead of the other.
    private static func barbell(_ left: SIMD2<Float>, _ right: SIMD2<Float>) -> [GearShape] {
        let axis = direction(left, right)
        let middle = (left + right) / 2
        let angle = atan2(axis.y, axis.x)
        var out = [GearShape(kind: .capsule, a: middle - axis * 0.64, b: middle + axis * 0.64, r: 0.015)]
        for side: Float in [-1, 1] {
            out.append(GearShape(kind: .box, a: middle + axis * (0.50 * side), b: SIMD2(0.028, 0.13), r: 0.02, angle: angle))
            out.append(GearShape(kind: .box, a: middle + axis * (0.555 * side), b: SIMD2(0.02, 0.09), r: 0.015, angle: angle))
        }
        return out
    }

    /// A round bell under its handle, hanging along `along` (down, at rest).
    private static func kettlebell(at hand: SIMD2<Float>, along: SIMD2<Float>, depth: Depth) -> [GearShape] {
        // The handle's arch faces back toward the hand.
        let angle = atan2(-along.y, -along.x) - .pi / 2
        let bell = hand + along * 0.16
        var handle = GearShape(kind: .handle, a: hand + along * 0.06, b: SIMD2(0.07, 0), r: 0.018, angle: angle)
        handle.depth = depth
        return [handle, GearShape(kind: .capsule, a: bell, b: bell, r: 0.105, depth: depth)]
    }
}
