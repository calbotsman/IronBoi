import Foundation
import simd

/// What's around the coach on screen, in its own joint units (hips at the
/// origin, y up), so it can behave like it shares the space with the UI.
struct LifeContext {
    /// How far above the hips the nearest thing overhead is. A standing
    /// figure needs about 0.7; less and it crouches to fit under.
    var headroom: Float = .infinity
    /// Something worth looking at — a chip that just landed — if any.
    var gaze: SIMD2<Float>? = nil
    /// Bumped when something new appears above: duck, then look at it.
    var nudge: Int = 0
    /// Allowed to break into a big canned act now and then (home only).
    var showpieces = false
}

/// The coach standing around between conversations, generated rather than
/// keyframed: a few slow noise channels keep it breathing, swaying and
/// shifting its weight; every few seconds it settles into a new intention —
/// hands on hips, arms crossed, a hand at its chin, a stretch, a look round,
/// a little bounce — with its own random amounts and timing, and springs
/// between them, so no two minutes look alike. It reads the screen: it
/// crouches when something sits low overhead, ducks when something lands
/// above it, and turns its head toward what just appeared.
struct GenerativeLife {
    /// The figure's shape, as a handful of numbers Rig.front turns into joints.
    private struct Shape {
        var hip = SIMD2<Float>(0, 0.005)
        var lean: Float = 0
        var nod: Float = 0
        /// Right arm (upper, forearm) angles; the left mirrors its own pair.
        // Out from the sides like OneBodyMotion.standing: a front-on blob
        // only reads as arms where there's daylight between arm and body.
        var right = SIMD2<Float>(-0.9, -1.3)
        var left = SIMD2<Float>(-0.9, -1.3)
        var stance: Float = 0.14
        /// One heel up: -1 left, +1 right.
        var heel: Float = 0

        static func + (a: Shape, b: Shape) -> Shape {
            var s = a
            s.hip += b.hip; s.lean += b.lean; s.nod += b.nod
            s.right += b.right; s.left += b.left; s.stance += b.stance; s.heel += b.heel
            return s
        }
        static func - (a: Shape, b: Shape) -> Shape {
            var s = a
            s.hip -= b.hip; s.lean -= b.lean; s.nod -= b.nod
            s.right -= b.right; s.left -= b.left; s.stance -= b.stance; s.heel -= b.heel
            return s
        }
        static func * (a: Shape, k: Float) -> Shape {
            var s = a
            s.hip *= k; s.lean *= k; s.nod *= k
            s.right *= k; s.left *= k; s.stance *= k; s.heel *= k
            return s
        }
    }

    // Only shapes that read in silhouette: seen front-on, an arm in front
    // of the body vanishes into it, so nothing crosses the torso.
    private enum Intention: CaseIterable {
        case relaxed, handsOnHips, handOnHip, sideStretch, armsOut, stretch, lookAround, bounce, shiftWeight, shrug
    }

    /// Smooth, never-repeating wobble: a few sines at unrelated rates.
    private struct Noise {
        private let rates: [Float]
        private let phases: [Float]
        init() {
            rates = (0..<3).map { _ in Float.random(in: 0.13...0.9) }
            phases = (0..<3).map { _ in Float.random(in: 0...(2 * .pi)) }
        }
        func value(_ t: Float) -> Float {
            zip(rates, phases).reduce(0) { $0 + sin(t * $1.0 + $1.1) } / 3
        }
    }

    private var shape = Shape()
    private var velocity = Shape() * 0
    private var target = Shape()
    private var intention: Intention = .relaxed
    private var nextChange: Float = 1.5
    /// How snappy the current transition is — varies, like a person does.
    private var stiffness: Float = 7
    private var gazeAt = SIMD2<Float>(0, 0.4)
    private var gazeUntil: Float = 0
    private var lookAroundAt = SIMD2<Float>(0, 0)
    private var duck: Float = 0
    private var duckVelocity: Float = 0
    private var lastNudge = 0
    /// After something lands: point at it for a moment.
    private var pointUntil: Float = 0
    private var pointStarted: Float = 0
    private var crouch: Float = 0
    private let sway = Noise(), bob = Noise(), weight = Noise(), armDrift = Noise(), head = Noise()
    private var showpiece = AmbientLife()
    private var inShowpiece = false
    private var lastTime: Float?

    mutating func pose(time t: Float, context: LifeContext) -> BodyPose? {
        let dt = min(max(t - (lastTime ?? t), 0), 0.05)
        lastTime = t

        // Something landed overhead: drop fast, come back up with a little give.
        if context.nudge != lastNudge {
            lastNudge = context.nudge
            duckVelocity += 3.2
            if inShowpiece { inShowpiece = false }
            if let gaze = context.gaze {
                gazeAt = gaze
                gazeUntil = t + 2.4
                // Duck first, then point at it.
                pointStarted = t + 0.45
                pointUntil = t + 1.9
            }
        }
        duckVelocity += (-(14 * 14) * duck - 2 * 0.55 * 14 * duckVelocity) * dt
        duck = max(0, duck + duckVelocity * dt)

        // Low ceiling: settle lower until it fits (feet stay put, knees bend).
        let needed: Float = 0.7
        let wantCrouch = context.headroom.isFinite ? min(max((needed - context.headroom) / 0.2, 0), 1) : 0
        crouch += (wantCrouch - crouch) * min(1, dt * 3)

        if inShowpiece {
            if showpiece.isFinished(at: t) || crouch > 0.05 {
                inShowpiece = false
                nextChange = t + Float.random(in: 0.8...1.6)
            } else if let frame = showpiece.currentFrame(at: t) {
                return frame
            }
        }

        if t >= nextChange { choose(at: t, context: context) }

        // Spring toward the intention; stiffness varies per transition.
        let w = stiffness, z: Float = 0.78
        let accel = (target - shape) * (w * w) - velocity * (2 * z * w)
        velocity = velocity + accel * dt
        shape = shape + velocity * dt

        var s = shape
        // Alive on top: breath, sway, weight shift, loose arms.
        s.hip.y += 0.006 * sin(t * 1.7) + 0.006 * bob.value(t)
        s.hip.x += 0.018 * weight.value(t)
        s.lean += 0.035 * sway.value(t)
        s.right += SIMD2(0.08, 0.1) * armDrift.value(t + 3)
        s.left += SIMD2(0.08, 0.1) * armDrift.value(t)
        s.nod += 0.05 * head.value(t)
        if intention == .bounce {
            let b = abs(sin(t * .pi * 2.2))
            s.hip.y += 0.022 * b
            s.heel = 0
        }
        // Crouch and duck: hips down, knees out, head tucks a touch.
        let down = 0.17 * crouch + 0.13 * min(duck, 1.2)
        s.hip.y -= down
        s.stance += 0.05 * crouch + 0.03 * min(duck, 1)
        s.nod += 0.12 * min(duck, 1)
        if duck > 0.1 {
            // Arms out for balance as it drops — out to the sides, where they
            // read, not up over the head where they melt into it.
            let balance = min(duck, 1) * 0.7
            s.right = s.right + (SIMD2(-0.45, -0.2) - s.right) * balance
            s.left = s.left + (SIMD2(-0.45, -0.2) - s.left) * balance
        }

        // "That one." The arm on its side reaches toward what landed, eased
        // in and out so it never snaps.
        if t > pointStarted, t < pointUntil {
            let k = min(smooth((t - pointStarted) / 0.3), smooth((pointUntil - t) / 0.4))
            let useRight = gazeAt.x >= 0
            let shoulder = SIMD2<Float>(useRight ? 0.16 : -0.16, s.hip.y + 0.235)
            let to = gazeAt - shoulder
            let angle = atan2(to.y, to.x)
            // Left-arm numbers are mirrored (π − θ) when the joints are built.
            let aim = useRight ? SIMD2(angle, angle + 0.08) : SIMD2(Float.pi - angle, Float.pi - angle - 0.08)
            if useRight { s.right = s.right + (aim - s.right) * k } else { s.left = s.left + (aim - s.left) * k }
        }

        var joints = Rig.front(
            hip: s.hip, lean: s.lean, nod: s.nod,
            arms: [(Float.pi - s.left.x, Float.pi - s.left.y), (s.right.x, s.right.y)],
            feet: [SIMD2(-s.stance + s.hip.x * 0.3, Rig.floor + max(0, -s.heel) * 0.03),
                   SIMD2(s.stance + s.hip.x * 0.3, Rig.floor + max(0, s.heel) * 0.03)]
        )

        // Eyes first: the head turns toward what it's looking at.
        let looking = t < gazeUntil ? gazeAt : (intention == .lookAround ? lookAroundAt : nil)
        if let look = looking {
            let toward = look - SIMD2(joints[0].x, joints[0].y)
            let length = max(simd_length(toward), 0.001)
            let turn = toward / length
            joints[0].x += turn.x * 0.035
            joints[0].y += turn.y * 0.02
        }
        return BodyPose(joints: joints, form: 1, side: 0, label: "")
    }

    /// Talking, listening, thinking: the blob takes over; start fresh after.
    mutating func rest(until t: Float) {
        nextChange = max(nextChange, t)
        inShowpiece = false
    }

    private mutating func choose(at t: Float, context: LifeContext) {
        // Now and then on home, a proper act (a walk, a jump, a dance) — rare,
        // so it's a treat, not the routine.
        if context.showpieces, crouch < 0.05, Float.random(in: 0...1) < 0.12 {
            showpiece.startAct(at: t)
            inShowpiece = true
            return
        }
        let options = Intention.allCases.filter { $0 != intention }
        let weights: [Intention: Float] = [
            .relaxed: 4, .handsOnHips: 2.5, .handOnHip: 2.5, .sideStretch: 1, .armsOut: 0.8, .stretch: 1,
            .lookAround: 2.5, .bounce: 1.5, .shiftWeight: 3, .shrug: 1,
        ]
        var roll = Float.random(in: 0..<options.reduce(0) { $0 + (weights[$1] ?? 1) })
        var pick = options[0]
        for option in options {
            roll -= weights[option] ?? 1
            if roll < 0 { pick = option; break }
        }
        intention = pick
        target = shape(for: pick)
        stiffness = Float.random(in: 4.5...9)
        let brief: Set<Intention> = [.stretch, .shrug, .sideStretch, .armsOut]
        let hold: ClosedRange<Float> = brief.contains(pick) ? 1.4...2.4 : 2.2...5.5
        nextChange = t + Float.random(in: hold)
        if pick == .lookAround {
            lookAroundAt = SIMD2(Float.random(in: -1...1) > 0 ? 0.9 : -0.9, Float.random(in: 0.2...0.8))
        }
    }

    /// Where each intention sits, with fresh amounts every time.
    private func shape(for intention: Intention) -> Shape {
        var s = Shape()
        let jitter = { (r: Float) in Float.random(in: -r...r) }
        s.stance = 0.14 + jitter(0.03)
        let relaxed = { SIMD2<Float>(-0.9 + jitter(0.1), -1.3 + jitter(0.12)) }
        let onHip = { SIMD2<Float>(-0.75 + jitter(0.08), -2.5 + jitter(0.1)) }
        let side: Float = Bool.random() ? 1 : -1
        switch intention {
        case .relaxed:
            s.right = relaxed()
            s.left = relaxed()
        case .handsOnHips:
            s.right = onHip()
            s.left = onHip()
            s.stance = 0.17 + jitter(0.02)
            s.lean = jitter(0.04)
        case .handOnHip:
            // One hand on the hip, weight into that side.
            if side > 0 { s.right = onHip(); s.left = relaxed() } else { s.left = onHip(); s.right = relaxed() }
            s.hip.x = 0.03 * side
            s.lean = -0.04 * side
            s.heel = -side
        case .sideStretch:
            // One arm up and over, leaning away from it.
            let over = SIMD2<Float>(1.75 + jitter(0.1), 2.55 + jitter(0.12))
            if side > 0 { s.right = over; s.left = relaxed() } else { s.left = over; s.right = relaxed() }
            s.lean = -0.16 * side
        case .armsOut:
            s.right = SIMD2(0.05 + jitter(0.08), 0.1 + jitter(0.1))
            s.left = SIMD2(0.05 + jitter(0.08), 0.1 + jitter(0.1))
            s.hip.y = 0.012
        case .stretch:
            let up: Float = 1.45 + jitter(0.1)
            s.right = SIMD2(up, up + 0.1)
            s.left = SIMD2(up, up + 0.1)
            s.hip.y = 0.025
            s.lean = jitter(0.12)
        case .lookAround:
            s.right = relaxed()
            s.left = relaxed()
        case .bounce:
            // Fists up by the shoulders, ready.
            s.right = SIMD2(-0.55 + jitter(0.1), 1.55 + jitter(0.15))
            s.left = SIMD2(-0.55 + jitter(0.1), 1.55 + jitter(0.15))
        case .shiftWeight:
            s.hip.x = 0.045 * side
            s.lean = -0.06 * side
            s.heel = -side
            s.right = relaxed()
            s.left = relaxed()
        case .shrug:
            s.right = SIMD2(-0.55 + jitter(0.1), 0.45 + jitter(0.2))
            s.left = SIMD2(-0.55 + jitter(0.1), 0.45 + jitter(0.2))
            s.hip.y = 0.012
            s.nod = -0.04
        }
        return s
    }

    private func smooth(_ x: Float) -> Float {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
