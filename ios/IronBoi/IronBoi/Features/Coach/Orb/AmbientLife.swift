import Foundation
import simd

/// What the coach does when nobody's talking and there's no workout: what a
/// good trainer does on the gym floor — walks around, bounces, throws a few
/// punches, drops for a push-up, jumps, dances, cheers you on. Every act,
/// its length and where it happens are picked fresh, and it rarely sits
/// still for long.
struct AmbientLife {
    private enum Act {
        case still(until: Float)
        case walk(start: Float, from: Float, to: Float, duration: Float)
        case squats(start: Float, reps: Int)
        case pushups(start: Float, reps: Int)
        case jump(start: Float, count: Int, star: Bool)
        case jacks(start: Float, count: Int)
        case shadowBox(start: Float, duration: Float, punches: [Punch])
        case dance(start: Float, duration: Float, style: Int)
        case highKnees(start: Float, duration: Float)
        case cheer(start: Float, style: Int)
        case wave(start: Float)
        // Back into the blob, with some style — each ends in the middle.
        case somersault(start: Float, from: Float)
        case cannonball(start: Float, from: Float)
        case dive(start: Float, from: Float)
        case melt(start: Float, from: Float)
    }

    private static let exits: Set<String> = ["somersault", "cannonball", "dive", "melt"]

    private struct Punch {
        let at: Float
        /// 1 = lead hand (jab), 0 = rear hand (cross).
        let arm: Int
    }

    private var act: Act = .still(until: 0.8)
    private var lastKind = "still"
    /// Where on the floor the coach is, across, in joint units.
    private var x: Float = 0
    /// +1 faces right, -1 faces left (side-on acts).
    private var facing: Float = 1

    private static let pushupEnter: Float = 1.3
    private static let pushupRep: Float = 2.4
    private static let jumpSeconds: Float = 1.3
    private static let jackSeconds: Float = 0.75

    mutating func pose(time t: Float) -> BodyPose? {
        if finished(at: t) { act = next(at: t) }
        return frame(at: t)
    }

    /// Talking, thinking, listening: be a blob, back in the middle, and pick
    /// back up a beat after.
    mutating func rest(until t: Float) {
        act = .still(until: t)
        x = 0
    }

    // MARK: - Choosing

    private func finished(at t: Float) -> Bool {
        switch act {
        case .still(let until): return t >= until
        case .walk(let start, _, _, let duration): return t - start >= duration
        case .squats(let start, let reps): return t - start >= Float(reps) * 3.2 + 0.3
        case .pushups(let start, let reps):
            return t - start >= Self.pushupEnter * 2 + Float(reps) * Self.pushupRep
        case .jump(let start, let count, _): return t - start >= Float(count) * Self.jumpSeconds
        case .jacks(let start, let count): return t - start >= Float(count) * Self.jackSeconds
        case .shadowBox(let start, let duration, _), .dance(let start, let duration, _),
             .highKnees(let start, let duration):
            return t - start >= duration
        case .cheer(let start, _): return t - start >= WorkoutLife.cheerSeconds
        case .wave(let start): return t - start >= 1.8
        // Each ends where the body gathers itself into the blob.
        case .somersault(let start, _): return t - start >= 1.35
        case .cannonball(let start, _): return t - start >= 1.05
        case .dive(let start, _): return t - start >= 1.0
        case .melt(let start, _): return t - start >= 1.25
        }
    }

    #if DEBUG
    /// MYO_REEL=1: the same stunts in the same order, forever, so a physics
    /// change can be judged against the last build. Each exit lands in the
    /// middle from a different direction and speed.
    private static let reel: [String] = [
        "walkLeft", "dive", "still", "walkRight", "cannonball", "still",
        "jump", "somersault", "still", "shadowBox", "melt", "still",
    ]
    private static let reelOn = ProcessInfo.processInfo.environment["MYO_REEL"] == "1"
    private var reelIndex = 0

    private mutating func nextFromReel(at t: Float) -> Act {
        if case .walk(_, _, let to, _) = act { x = to }
        // Every exit ends in the middle — that's where the blob is.
        if Self.exits.contains(lastKind) { x = 0 }
        let kind = Self.reel[reelIndex % Self.reel.count]
        reelIndex += 1
        lastKind = kind
        switch kind {
        case "walkLeft":
            facing = -1
            return .walk(start: t, from: x, to: -0.28, duration: max(1.4, abs(-0.28 - x) / 0.22 + 0.5))
        case "walkRight":
            facing = 1
            return .walk(start: t, from: x, to: 0.28, duration: max(1.4, abs(0.28 - x) / 0.22 + 0.5))
        case "dive": facing = x > 0 ? -1 : 1; return .dive(start: t, from: x)
        case "cannonball": facing = x > 0 ? -1 : 1; return .cannonball(start: t, from: x)
        case "somersault": facing = 1; return .somersault(start: t, from: x)
        case "melt": return .melt(start: t, from: x)
        case "jump": return .jump(start: t, count: 2, star: false)
        case "shadowBox":
            return .shadowBox(start: t, duration: 3.2, punches: [
                Punch(at: 0.5, arm: 1), Punch(at: 0.72, arm: 0), Punch(at: 1.6, arm: 1),
                Punch(at: 1.82, arm: 1), Punch(at: 2.04, arm: 0),
            ])
        default:
            return .still(until: t + 1.8)
        }
    }
    #endif

    private mutating func next(at t: Float) -> Act {
        #if DEBUG
        if Self.reelOn { return nextFromReel(at: t) }
        #endif
        if case .walk(_, _, let to, _) = act { x = to }
        // Just went back into the blob: stay one for a beat, in the middle.
        if Self.exits.contains(lastKind) {
            x = 0
            lastKind = "still"
            return .still(until: t + Float.random(in: 1.5...3))
        }
        let menu: [(String, Float)] = [
            ("walk", 22), ("squats", 9), ("pushups", 7), ("jump", 9), ("jacks", 9),
            ("shadowBox", 11), ("dance", 11), ("highKnees", 7), ("cheer", 6), ("wave", 5), ("still", 3),
            ("exit", 14),
        ]
        let choices = menu.filter { $0.0 != lastKind }
        var roll = Float.random(in: 0..<choices.reduce(0) { $0 + $1.1 })
        var kind = choices[0].0
        for (name, weight) in choices {
            if roll < weight { kind = name; break }
            roll -= weight
        }
        #if DEBUG
        // MYO_AMBIENT=dive: always pick this act, to tune it.
        if let forced = ProcessInfo.processInfo.environment["MYO_AMBIENT"], !forced.isEmpty {
            kind = forced == "dive" && abs(x) < 0.15 ? "walk" : forced
        }
        #endif
        if kind == "exit" {
            kind = (["somersault", "cannonball", "melt"] + (abs(x) >= 0.15 ? ["dive", "dive"] : [])).randomElement()!
            // Head for the middle — that's where the blob is.
            facing = abs(x) > 0.05 ? (x > 0 ? -1 : 1) : (Bool.random() ? 1 : -1)
        } else if Bool.random() {
            facing = -facing
        }
        lastKind = kind

        switch kind {
        case "walk":
            // Stays well inside the screen, so a dive from the edge fits too.
            var to = Float.random(in: -0.25...0.25)
            if abs(to - x) < 0.15 { to = x > 0 ? x - 0.25 : x + 0.25 }
            facing = to > x ? 1 : -1
            return .walk(start: t, from: x, to: to, duration: max(1.4, abs(to - x) / 0.22 + 0.5))
        case "squats": return .squats(start: t, reps: Int.random(in: 2...3))
        case "pushups": return .pushups(start: t, reps: Int.random(in: 1...2))
        case "jump": return .jump(start: t, count: Int.random(in: 1...2), star: Bool.random())
        case "jacks": return .jacks(start: t, count: Int.random(in: 4...7))
        case "shadowBox":
            let duration = Float.random(in: 3.2...4.5)
            return .shadowBox(start: t, duration: duration, punches: Self.combos(lasting: duration))
        case "dance": return .dance(start: t, duration: Float.random(in: 3.5...5), style: Int.random(in: 0...1))
        case "highKnees": return .highKnees(start: t, duration: Float.random(in: 2...3))
        case "cheer": return .cheer(start: t, style: Int.random(in: 0...1))
        case "wave": return .wave(start: t)
        case "somersault": return .somersault(start: t, from: x)
        case "cannonball": return .cannonball(start: t, from: x)
        case "dive": return .dive(start: t, from: x)
        case "melt": return .melt(start: t, from: x)
        default: return .still(until: t + Float.random(in: 1.2...2.5))
        }
    }

    /// Jab, jab-cross, jab-jab-cross… with a breath between combos.
    private static func combos(lasting duration: Float) -> [Punch] {
        let patterns: [[Int]] = [[1], [1, 0], [1, 1, 0], [1, 0, 1]]
        var out: [Punch] = []
        var at: Float = 0.5
        while at < duration - 0.5 {
            for arm in patterns.randomElement()! {
                out.append(Punch(at: at, arm: arm))
                at += 0.22
            }
            at += Float.random(in: 0.5...0.9)
        }
        return out
    }

    // MARK: - Acts

    private func frame(at t: Float) -> BodyPose? {
        switch act {
        case .still:
            return nil
        case .walk(let start, let from, let to, let duration):
            let s = smooth((t - start) / duration)
            let joints = Self.walking(t - start, duration: duration, distance: abs(to - from) * s)
            return place(joints, at: from + (to - from) * s, side: true)
        case .squats(let start, _):
            return place(ExerciseMotion(.squat, .none).frame(at: t - start).joints, side: true)
        case .pushups(let start, let reps):
            return place(Self.pushups(t - start, reps: reps, time: t), side: true)
        case .jump(let start, _, let star):
            let u = (t - start).truncatingRemainder(dividingBy: Self.jumpSeconds)
            return place(Self.jumping(u, star: star, time: t), side: false)
        case .jacks(let start, _):
            return place(Self.jacks(t - start), side: false)
        case .shadowBox(let start, _, let punches):
            return place(Self.boxing(t - start, punches: punches), side: true)
        case .dance(let start, _, let style):
            return place(Self.dancing(t - start, style: style), side: false)
        case .highKnees(let start, _):
            return place(Self.highKnees(t - start, time: t), side: false)
        case .cheer(let start, let style):
            return place(WorkoutLife.cheer(at: t - start, style: style).joints, side: false)
        case .wave(let start):
            return place(Self.waving(t - start, time: t), side: false)
        case .somersault(let start, let from):
            return exit(Self.somersault(t - start, travel: abs(from), time: t), from: from, side: true)
        case .cannonball(let start, let from):
            return exit(Self.cannonball(t - start, travel: abs(from), time: t), from: from, side: true)
        case .dive(let start, let from):
            return exit(Self.dive(t - start, travel: abs(from)), from: from, side: true)
        case .melt(let start, let from):
            return exit(Self.melt(t - start, time: t), from: from, side: false, slide: true)
        }
    }

    /// Mirrors side-on acts to face the way the coach is facing, and moves
    /// the whole figure to where it's standing.
    private func place(_ joints: [Joint], at position: Float? = nil, side: Bool) -> BodyPose {
        let across = position ?? x
        let flip: Float = side ? facing : 1
        let placed = joints.map { Joint($0.x * flip + across, $0.y, $0.z) }
        return BodyPose(joints: placed, form: 1, side: side ? 1 : 0, label: "")
    }

    /// An exit's frame: joints (side-on ones travel forward toward the
    /// middle), how much person is left, and any squash for the landing.
    private struct ExitFrame {
        var joints: [Joint]
        var form: Float
        var squash: Float?
        /// 0…1, how far across to the middle (front-on exits slide there).
        var across: Float = 0
    }

    private func exit(_ frame: ExitFrame, from: Float, side: Bool, slide: Bool = false) -> BodyPose {
        var pose = place(frame.joints, at: slide ? from * (1 - frame.across) : from, side: side)
        pose.form = frame.form
        pose.squash = frame.squash
        return pose
    }

    /// Tuck and roll forward into the middle; the body then gathers into
    /// the blob from wherever the roll ends.
    private static func somersault(_ t: Float, travel: Float, time: Float) -> ExitFrame {
        let stand = Rig.side(hip: SIMD2(0, 0.005), tilt: 0.05,
                             arms: [(-Float.pi / 2 + 0.1, -Float.pi / 2 + 0.25), (-Float.pi / 2 + 0.15, -Float.pi / 2 + 0.3)],
                             feet: [SIMD2(-0.02, Rig.floor), SIMD2(0.03, Rig.floor)])
        let ball = OneBodyMotion.tucked()
        let ground: Float = -0.22
        if t < 0.45 {
            let u = smooth(t / 0.45)
            let tuck = OneBodyMotion.turned(ball, by: 0, offset: SIMD2(0, ground))
            return ExitFrame(joints: zip(stand, tuck).map { $0 + ($1 - $0) * u }, form: 1)
        }
        let u = min((t - 0.45) / 0.9, 1)
        let eased = u * u * (3 - 2 * u)
        // Rolls up off the floor into the middle as it comes round.
        let center = SIMD2<Float>(travel * eased, ground + 0.22 * eased * eased)
        return ExitFrame(joints: OneBodyMotion.turned(ball, by: -2 * .pi * eased, offset: center), form: 1)
    }

    /// Load, spring up into a tuck, and drop into the middle.
    private static func cannonball(_ t: Float, travel: Float, time: Float) -> ExitFrame {
        let crouch = ExerciseMotion(.squat, .none).frame(holding: 0.7, time: time).joints
        let ball = OneBodyMotion.tucked()
        if t < 0.3 {
            return ExitFrame(joints: crouch, form: 1)
        }
        let u = min((t - 0.3) / 0.75, 1)
        let curl = smooth(u / 0.35)
        // Up and over, falling into the blob's centre.
        let center = SIMD2<Float>(travel * smooth(u), -0.15 * (1 - u) + sin(u * .pi) * 0.38)
        let tuck = OneBodyMotion.turned(ball, by: -0.9 * u, offset: center)
        return ExitFrame(joints: zip(crouch, tuck).map { $0 + ($1 - $0) * curl }, form: 1)
    }

    /// Wind up, then a head-first dive into the middle — kept steep and
    /// short so it never leaves the screen.
    private static func dive(_ t: Float, travel: Float) -> ExitFrame {
        if t < 0.35 {
            let u = smooth(t / 0.35)
            return ExitFrame(joints: Rig.side(hip: SIMD2(0, -0.08 * u), tilt: 0.35 * u,
                                              arms: [(-Float.pi / 2 - 0.8 * u, -Float.pi / 2 - 0.7 * u),
                                                     (-Float.pi / 2 - 0.75 * u, -Float.pi / 2 - 0.65 * u)],
                                              feet: [SIMD2(-0.06, Rig.floor), SIMD2(0.05, Rig.floor)]), form: 1)
        }
        // Long and straight, arms reaching past the head.
        let superman = Rig.side(hip: .zero, tilt: 0,
                                arms: [(Float.pi / 2 - 0.05, Float.pi / 2 - 0.05), (Float.pi / 2 - 0.12, Float.pi / 2 - 0.12)],
                                feet: [SIMD2(-0.02, -0.39), SIMD2(0.02, -0.39)])
        let u = min((t - 0.35) / 0.65, 1)
        let eased = smooth(u)
        let angle = -(0.35 + 0.95 * eased)
        let center = SIMD2<Float>(travel * 0.8 * eased, -0.04 + 0.16 * sin(u * .pi))
        let straight = OneBodyMotion.turned(superman, by: angle, offset: center)
        // A diver tucks on the way in: over the second half of the flight the
        // long body curls into a ball that keeps rolling forward, so it
        // arrives at the middle already round and the blob has nothing to
        // gather. Without this it landed as a rod and every joint sprang to
        // the centre on its own schedule — rod, lumps, ball.
        let curl = smooth((u - 0.45) / 0.55)
        let ball = OneBodyMotion.turned(OneBodyMotion.tucked(), by: angle - 1.6 * curl, offset: center)
        return ExitFrame(joints: zip(straight, ball).map { $0 + ($1 - $0) * curl }, form: 1)
    }

    /// Knees go, then everything slumps into a puddle — which then pulls
    /// itself up into the blob.
    private static func melt(_ t: Float, time: Float) -> ExitFrame {
        var j = OneBodyMotion.standing(time)
        if t < 0.35 {
            let wobble = sin(t * 34) * 0.012 * t / 0.35
            for i in 0...8 { j[i].y -= 0.05 * smooth(t / 0.35); j[i].x += wobble }
            return ExitFrame(joints: j, form: 1)
        }
        let u = smooth((t - 0.35) / 0.9)
        for i in j.indices {
            let floorY = -0.32 + (j[i].y - Rig.floor) * 0.22
            j[i] = Joint(j[i].x * (1 + 0.6 * u), j[i].y + (floorY - j[i].y) * u, j[i].z * (1 + 0.35 * u))
        }
        return ExitFrame(joints: j, form: 1, across: u)
    }

    /// Side-on, facing +x. Steps come from distance covered, so the legs
    /// slow down as the walk eases in and out.
    private static func walking(_ t: Float, duration: Float, distance: Float) -> [Joint] {
        let phase = distance / 0.32 * 2 * .pi
        let amp = max(0, min(1, t / 0.35, (duration - t) / 0.35))
        let bob = cos(phase * 2) * 0.012 * amp
        func foot(_ p: Float) -> SIMD2<Float> {
            SIMD2(0.11 * sin(p) * amp, Rig.floor + max(0, cos(p)) * 0.07 * amp)
        }
        // Each arm swings against its leg.
        let swing = 0.5 * sin(phase) * amp
        return Rig.side(hip: SIMD2(0, bob - 0.01 * amp), tilt: 0.07 * amp, nod: bob,
                        arms: [(-.pi / 2 - swing, -.pi / 2 - swing + 0.35),
                               (-.pi / 2 + swing, -.pi / 2 + swing + 0.35)],
                        feet: [foot(phase), foot(phase + .pi)])
    }

    /// Down into a plank, a rep or two, back up.
    private static func pushups(_ t: Float, reps: Int, time: Float) -> [Joint] {
        let enter = pushupEnter, rep = pushupRep
        let stand = OneBodyMotion.standing(time), crouch = OneBodyMotion.crouching()
        if t < enter {
            return OneBodyMotion.flow([stand, crouch, OneBodyMotion.plank(0)], t / enter)
        }
        let working = t - enter
        if working < Float(reps) * rep {
            let cycle = working / rep
            func depth(_ c: Float) -> Float {
                OneBodyMotion.repTempo(c - floor(c), lowersFirst: true, variation: OneBodyMotion.variation(floor(c)))
            }
            return OneBodyMotion.plank(depth(cycle), hipDepth: depth(max(0, cycle - 0.025)),
                                       headDepth: depth(max(0, cycle - 0.04)))
        }
        let rising = (working - Float(reps) * rep) / enter
        return OneBodyMotion.flow([OneBodyMotion.plank(0), crouch, stand], min(rising, 1), rising: true)
    }

    /// Front-on: load, explode, land soft. A tuck jump or a star.
    private static func jumping(_ u: Float, star: Bool, time: Float) -> [Joint] {
        let floor = Rig.floor
        var hip = SIMD2<Float>(0, 0.005)
        var feet = [SIMD2<Float>(-0.15, floor), SIMD2<Float>(0.15, floor)]
        var reach: Float = -1.35 // arms: right-arm angle; left mirrors it
        if u < 0.32 {
            let load = smooth(u / 0.32)
            hip.y -= 0.09 * load
            reach = -1.35 - 0.35 * load
        } else if u < 0.8 {
            let a = (u - 0.32) / 0.48
            let height = sin(a * .pi) * 0.26
            hip.y += height
            for i in feet.indices { feet[i].y += height }
            if star {
                feet[0].x = -0.15 - 0.15 * sin(a * .pi); feet[1].x = 0.15 + 0.15 * sin(a * .pi)
                reach = 0.55
            } else {
                for i in feet.indices { feet[i].y += 0.09 * sin(a * .pi) }
                reach = 1.25
            }
        } else {
            let land = (u - 0.8) / 0.5
            hip.y -= 0.08 * sin(min(land, 1) * .pi)
            reach = -1.35 + 0.5 * (1 - smooth(land * 1.5))
        }
        return Rig.front(hip: hip, lean: 0, arms: [(.pi - reach, .pi - reach - 0.1), (reach, reach + 0.1)],
                         feet: feet)
    }

    private static func jacks(_ t: Float) -> [Joint] {
        let c = t / jackSeconds
        let open = (1 - cos(c * 2 * .pi)) / 2
        let hop = abs(sin(c * 2 * .pi)) * 0.035
        let wide = 0.15 + 0.18 * open
        let arm = -1.35 + 2.7 * open
        return Rig.front(hip: SIMD2(0, 0.005 + hop - 0.03 * open), lean: 0,
                         arms: [(.pi - arm, .pi - arm - 0.05), (arm, arm + 0.05)],
                         feet: [SIMD2(-wide, Rig.floor + hop), SIMD2(wide, Rig.floor + hop)])
    }

    /// Side-on boxing stance, bouncing on the balls of the feet, hands up;
    /// punches snap out and come back slower.
    private static func boxing(_ t: Float, punches: [Punch]) -> [Joint] {
        var extend: [Float] = [0, 0]
        for punch in punches {
            let since = t - punch.at
            guard since >= 0, since < 0.3 else { continue }
            let e = since < 0.09 ? smooth(since / 0.09) : 1 - smooth((since - 0.09) / 0.2)
            extend[punch.arm] = max(extend[punch.arm], e)
        }
        let bounce = abs(sin(t * .pi * 2.3)) * 0.02
        func arm(_ e: Float) -> (Float, Float) {
            // Guard: elbow down, fist by the chin. Punch: straight out.
            (-1.25 + 1.33 * e, 1.45 - 1.37 * e)
        }
        let cross = extend[0]
        return Rig.side(hip: SIMD2(0.02 * cross, -0.035 + bounce), tilt: 0.12 + 0.06 * cross, nod: -0.05,
                        arms: [arm(extend[0]), arm(extend[1])],
                        feet: [SIMD2(-0.13, Rig.floor + bounce * 0.6), SIMD2(0.11, Rig.floor + bounce * 0.6)])
    }

    /// Front-on, on a ~126 bpm beat: raise-the-roof bounce, or disco points.
    private static func dancing(_ t: Float, style: Int) -> [Joint] {
        let beat = t * 2.1
        let groove = abs(sin(beat * .pi)) // 0 on the beat
        let sway = sin(beat * .pi)
        let hip = SIMD2<Float>(0.035 * sway, 0.005 - 0.035 * (1 - groove))
        let ground = Rig.floor
        if style == 0 {
            let push = 0.1 + 0.35 * (1 - groove)
            return Rig.front(hip: hip, lean: -0.08 * sway, nod: 0.08 * (1 - groove),
                             arms: [(.pi - push, .pi - Float(1.45)), (push, Float(1.45))],
                             feet: [SIMD2(-0.15, ground), SIMD2(0.15, ground)])
        }
        let even = Int(beat) % 2 == 0
        let snap = smooth((beat - floor(beat)) / 0.35)
        let point: (Float, Float) = even ? (0.95, 1.0) : (-2.3, -2.4)
        let previous: (Float, Float) = even ? (-2.3, -2.4) : (0.95, 1.0)
        let right = (previous.0 + (point.0 - previous.0) * snap, previous.1 + (point.1 - previous.1) * snap)
        let tap: Float = 0.07
        return Rig.front(hip: hip, lean: -0.06 * sway, nod: 0,
                         arms: [(3.74, -0.6), right],
                         feet: [SIMD2(-0.15 - (even ? 0 : tap), ground + (even ? 0 : 0.02)),
                                SIMD2(0.15 + (even ? tap : 0), ground + (even ? 0.02 : 0))])
    }

    /// Front-on: knees driving up in turn, arms pumping against them.
    private static func highKnees(_ t: Float, time: Float) -> [Joint] {
        var j = OneBodyMotion.standing(time)
        let phase = t * 2 * .pi * 1.7
        let left = max(0, sin(phase)), right = max(0, -sin(phase))
        let bounce = abs(sin(phase)) * 0.02
        for i in j.indices { j[i].y += bounce }
        j[9] = Joint(-0.12, -0.19 + 0.17 * left + bounce, 0.115)
        j[10] = Joint(-0.14, Rig.floor + 0.17 * left + bounce, 0.11)
        j[11] = Joint(0.12, -0.19 + 0.17 * right + bounce, 0.115)
        j[12] = Joint(0.14, Rig.floor + 0.17 * right + bounce, 0.11)
        // Elbows bent at the sides; each hand rises with the other knee.
        j[4] = Joint(-0.23, 0.08 + bounce, 0.105); j[5] = Joint(-0.21, 0.02 + 0.2 * right + bounce, 0.10)
        j[7] = Joint(0.23, 0.08 + bounce, 0.105);  j[8] = Joint(0.21, 0.02 + 0.2 * left + bounce, 0.10)
        return j
    }

    /// "Hey — over here!" One arm up, waving, a little lift on the toes.
    private static func waving(_ t: Float, time: Float) -> [Joint] {
        var j = OneBodyMotion.standing(time)
        let lift = sin(min(t / 0.3, 1) * .pi / 2) * 0.015
        for i in j.indices where i != 10 && i != 12 { j[i].y += lift }
        let shoulder = SIMD2(j[6].x, j[6].y)
        let upper: Float = 1.05
        let fore = 1.55 + 0.45 * sin(t * 9)
        let elbow = shoulder + SIMD2(cos(upper), sin(upper)) * 0.19
        let hand = elbow + SIMD2(cos(fore), sin(fore)) * 0.18
        j[7] = Joint(elbow.x, elbow.y, 0.105)
        j[8] = Joint(hand.x, hand.y, 0.10)
        return j
    }

    private static func smooth(_ x: Float) -> Float {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }
    private func smooth(_ x: Float) -> Float { Self.smooth(x) }
}

/// Builds a whole figure from a few numbers — hips, lean, arm angles, feet —
/// with bone lengths held and knees solved, in the same joint space as
/// OneBodyMotion.
enum Rig {
    static let floor: Float = -0.385

    /// The middle joint of a two-bone chain, bent toward `toward`.
    static func middle(_ root: SIMD2<Float>, _ end: SIMD2<Float>, _ upper: Float, _ lower: Float,
                       toward: SIMD2<Float>) -> SIMD2<Float> {
        let delta = end - root
        let length = max(simd_length(delta), 0.0001)
        let distance = min(max(length, abs(upper - lower) + 0.0001), upper + lower - 0.0001)
        let direction = delta / length
        let along = (upper * upper - lower * lower + distance * distance) / (2 * distance)
        let bend = sqrt(max(0, upper * upper - along * along))
        var perpendicular = SIMD2<Float>(-direction.y, direction.x)
        if simd_dot(perpendicular, toward) < 0 { perpendicular = -perpendicular }
        return root + direction * along + perpendicular * bend
    }

    /// Side-on, facing +x. Arms are (upper arm, forearm) angles in radians
    /// (0 = straight ahead), back arm first; feet back leg first.
    static func side(hip: SIMD2<Float>, tilt: Float, nod: Float = 0,
                     arms: [(Float, Float)], feet: [SIMD2<Float>]) -> [Joint] {
        let spine = SIMD2<Float>(sin(tilt), cos(tilt))
        let chest = hip + spine * 0.255
        let head = hip + SIMD2(sin(tilt + nod), cos(tilt + nod)) * 0.49
        let shoulder = hip + spine * 0.235
        var j = [Joint](repeating: .zero, count: 13)
        j[0] = Joint(head.x, head.y, 0.165)
        j[1] = Joint(chest.x, chest.y, 0.185)
        j[2] = Joint(hip.x, hip.y, 0.17)
        for (k, base) in [3, 6].enumerated() {
            let s = shoulder + SIMD2(Float(k) * 0.03, 0)
            let (upper, fore) = arms[k]
            let elbow = s + SIMD2(cos(upper), sin(upper)) * 0.2
            let hand = elbow + SIMD2(cos(fore), sin(fore)) * 0.19
            j[base] = Joint(s.x, s.y, 0.10)
            j[base + 1] = Joint(elbow.x, elbow.y, 0.085)
            j[base + 2] = Joint(hand.x, hand.y, 0.09)
        }
        for (k, base) in [9, 11].enumerated() {
            let knee = middle(hip, feet[k], 0.2, 0.2, toward: SIMD2(1, 0))
            j[base] = Joint(knee.x, knee.y, 0.115)
            j[base + 1] = Joint(feet[k].x, feet[k].y, 0.11)
        }
        return j
    }

    /// Front-on. Arms are (upper arm, forearm) angles in radians (0 = to
    /// the coach's left on screen, i.e. +x), left arm first; feet left first.
    /// Knees bend outward. `lean` tips the spine sideways.
    static func front(hip: SIMD2<Float>, lean: Float, nod: Float = 0,
                      arms: [(Float, Float)], feet: [SIMD2<Float>]) -> [Joint] {
        let spine = SIMD2<Float>(sin(lean), cos(lean))
        let across = SIMD2<Float>(spine.y, -spine.x)
        let chest = hip + spine * 0.255
        let head = hip + spine * 0.495 + SIMD2(0, -0.02 * nod)
        let shoulders = hip + spine * 0.235
        var j = [Joint](repeating: .zero, count: 13)
        j[0] = Joint(head.x, head.y, 0.165)
        j[1] = Joint(chest.x, chest.y, 0.185)
        j[2] = Joint(hip.x, hip.y, 0.17)
        for (k, base) in [3, 6].enumerated() {
            let s = shoulders + across * (k == 0 ? -0.16 : 0.16)
            let (upper, fore) = arms[k]
            let elbow = s + SIMD2(cos(upper), sin(upper)) * 0.17
            let hand = elbow + SIMD2(cos(fore), sin(fore)) * 0.17
            j[base] = Joint(s.x, s.y, 0.10)
            j[base + 1] = Joint(elbow.x, elbow.y, 0.105)
            j[base + 2] = Joint(hand.x, hand.y, 0.10)
        }
        for (k, base) in [9, 11].enumerated() {
            let knee = middle(hip, feet[k], 0.23, 0.2, toward: SIMD2(k == 0 ? -1 : 1, 0))
            j[base] = Joint(knee.x, knee.y, 0.115)
            j[base + 1] = Joint(feet[k].x, feet[k].y, 0.11)
        }
        return j
    }
}
