import SwiftUI
import simd
import QuartzCore

/// One voice's readings for a frame. Written from audio/speech callbacks,
/// read by the orb at display rate.
struct VoiceReading {
    /// 0…1 loudness, smoothed.
    var level: Float = 0
    /// 0…1, spikes on a syllable or word and decays.
    var peak: Float = 0
    /// Counts syllable/word onsets; the orb reacts to changes.
    var onsets: Int = 0
    /// Rough spectral shape driving the 2-, 3- and 7-lobe ripples.
    var bands = SIMD3<Float>(0, 0, 0)
    var active = false
    /// Smoothed 0…1 version of `active`.
    var presence: Float = 0
}

/// Thread-safe holder for a `VoiceReading`. Audio taps write on their own
/// thread; the orb reads on the main thread every frame. Deliberately not an
/// ObservableObject — publishing at audio rate would re-render SwiftUI.
final class VoiceMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = VoiceReading()
    private var lastOnsetAt: CFTimeInterval = 0

    /// The mic sets a full reading every analysis hop; the synthesizer
    /// only beats per word, so its peaks decay here between beats.
    private var continuous = false

    var reading: VoiceReading {
        lock.lock(); defer { lock.unlock() }
        if continuous { return value }
        var out = value
        let since = Float(CACurrentMediaTime() - lastOnsetAt)
        out.peak = value.peak * exp(-since * 7)
        out.level = value.active ? value.level : value.level * exp(-since * 3)
        return out
    }

    /// A full reading from the mic analyser.
    func set(_ reading: VoiceReading) {
        lock.lock(); defer { lock.unlock() }
        value = reading
        continuous = true
    }

    /// A discrete beat — a spoken word from the synthesizer.
    func pulse(strength: Float, bands: SIMD3<Float>) {
        lock.lock(); defer { lock.unlock() }
        value.onsets += 1
        value.peak = strength
        value.level = max(value.level * 0.6, strength * 0.8)
        value.bands = bands
        value.active = true
        continuous = false
        lastOnsetAt = CACurrentMediaTime()
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        value.level = 0
        value.peak = 0
        value.bands = .zero
        value.active = false
        value.presence = 0
    }
}

/// A lesson beat the body is acting out: ease from `from` into the cue's
/// position (or show reps) for this lift, starting at `startedAt`.
struct LessonCue: Equatable {
    let motion: ExerciseMotion
    let body: ExerciseLesson.BodyCue
    let from: Float
    let startedAt: CFTimeInterval
}

enum OrbPhase: Equatable {
    case rest, listening, thinking, speaking
}

/// The body's state between frames — springs, droplets, tint. A reference
/// type so `TimelineView` can advance it without re-rendering SwiftUI state.
/// A line-for-line port of One Body's frame() in orb-lab
/// (src/variants/one-body.ts) with its tuner defaults.
///
/// Coordinates match the shader: the view's short side spans -1…1, y up,
/// origin at the view's centre. The view covers the whole screen, so the
/// body sits at `anchor` and droplets start just below the bottom edge.
final class OrbModel {
    private static let maxDrops = 16
    /// MYO reads bigger than orb-lab's: the blob and the person it becomes
    /// scale together.
    private static let size: Float = 1.25
    private let baseR: Float = 0.36 * OrbModel.size, levelR: Float = 0.18
    private let lobeGains = SIMD3<Float>(0.10, 0.08, 0.03)
    private let lean: Float = 0.16, squashGain: Float = 0.1
    private let dropSize: Float = 0.05, dropSpeed: Float = 1.3
    private let tintGain: Float = 0.45, ease: Float = 0.12

    private var lastFrame: CFTimeInterval?
    private(set) var time: Float = 0
    private(set) var radius: Float = 0.36
    private(set) var center = SIMD2<Float>(0, 0.05)
    private var lift: Float = 0.05
    private(set) var squash: Float = 1
    private var squashVelocity: Float = 0
    /// The person is gathered into the blob's shape, ready to grow out of it.
    private var folded = false
    private(set) var lobes = SIMD3<Float>(0, 0, 0)
    private(set) var think: Float = 0
    /// The lobes' rotation angle, accumulated so a change in speed never
    /// jumps it.
    private(set) var spin: Float = 0
    private(set) var tint: Float = 0
    private var agentPresence: Float = 0
    private var agentLevelSlow: Float = 0

    // x, y, radius, alive — the layout the shader reads.
    private var drops = [SIMD4<Float>](repeating: .zero, count: OrbModel.maxDrops)
    private var velocity = [Float](repeating: 0, count: OrbModel.maxDrops)
    private var nextDrop = 0
    private var lastYouOnsets = 0

    var dropArray: [Float] { drops.flatMap { [$0.x, $0.y, $0.z, $0.w] } }

    // The person the body becomes for a move — joints follow the authored
    // pose on springs, heavier joints slower, contact points quickest.
    private var joints = OneBodyMotion.standing()
    private var jointVelocity = [SIMD2<Float>](repeating: .zero, count: 13)
    // The equipment: what's out, whether side-on, and how far grown.
    private var gearShown: Gear = .none
    private var benchShown = false
    private var gearSideOn = false
    private var gearGrow: Float = 0
    private var gearGrowVelocity: Float = 0
    private static let maxGearShapes = 16
    /// 8 floats per shape, padded; kind -1 is skipped.
    private(set) var gearArray = [Float](repeating: -1, count: OrbModel.maxGearShapes * 8)
    /// How gooey the join between body and equipment is: stretched while it
    /// grows out, a slight fillet at the grip once it's out.
    private(set) var gearBlend: Float = 0.12
    private(set) var form: Float = 0
    private(set) var armDepth: Float = 0
    private var bodyScale: Float = 1
    private var life = WorkoutLife()
    private var ambientLife = AmbientLife()
    /// Scaled with the body, so the person shrinks with the blob when a card
    /// takes the space below.
    var jointArray: [Float] {
        let s = bodyScale * Self.size
        return joints.flatMap { [$0.x * s, $0.y * s, $0.z * s] }
    }

    /// `anchor`: where the body rests, in shader units. `move`/`moveTime`:
    /// the demonstration playing, if any, and how far into it.
    func step(phase: OrbPhase, you: VoiceReading, agent: VoiceReading,
              size: CGSize, anchor: SIMD2<Float>, move: BodyMove?, moveTime: Float,
              loop: ExerciseMotion? = nil, inWorkout: Bool = false, setsDone: Int = 0,
              demo: ExerciseMotion? = nil, ambient: Bool = false,
              lesson: LessonCue? = nil, counting: Bool = false, youTalking: Bool = false,
              spawnY: Float? = nil,
              scale: Float = 1, reduceMotion: Bool) {
        bodyScale += (scale - bodyScale) * 0.15
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - (lastFrame ?? now), 0), 0.05))
        lastFrame = now
        time += reduceMotion ? dt * 0.25 : dt
        let k = 1 - pow(1 - ease, dt * 60)

        // The synthesizer has no analyser, so the agent's presence and slow
        // level come from the phase and the word beats.
        agentPresence += (((phase == .speaking) ? 1 : 0) - agentPresence) * k
        agentLevelSlow += (agent.level * agentPresence - agentLevelSlow) * k * 0.5

        let breathe: Float = reduceMotion ? 0 : 0.012 * sin(time * 0.9)
        // `scale` shrinks the body when a card takes the space below it.
        radius += ((baseR + agentLevelSlow * levelR + agent.peak * agentPresence * 0.05 + breathe) * scale - radius) * k
        // Leans down toward you and squashes only while you're actually talking.
        lift += ((0.05 - you.presence * lean) * scale - lift) * k
        center = anchor + SIMD2(0, lift)
        let pitch: Float = 0.5 + (agent.bands.y - 0.5) * 0.4
        let squashBase = 1 - you.presence * squashGain + agentPresence * (pitch - 0.5) * 0.2
        let lobeTarget = agent.bands * lobeGains * agentPresence + SIMD3(repeating: agent.peak * agentPresence * 0.02)
        lobes += (lobeTarget - lobes) * k
        think += (((phase == .thinking) ? 1 : 0) - think) * k * 0.5
        spin += dt * (0.25 + think * 1.2) * (reduceMotion ? 0.25 : 1)
        if spin > 2 * .pi * 1000 { spin -= 2 * .pi * 1000 }

        // Your syllables → droplets rising from just below the screen.
        let bottom = spawnY ?? -Float(size.height / max(min(size.width, size.height), 1)) - 0.1
        if you.onsets != lastYouOnsets {
            if you.active, !reduceMotion {
                drops[nextDrop] = SIMD4(anchor.x + Float.random(in: -0.5...0.5) * 0.9, bottom,
                                        dropSize * (0.6 + you.peak * 1.2), 1)
                velocity[nextDrop] = 0
                nextDrop = (nextDrop + 1) % Self.maxDrops
            }
            lastYouOnsets = you.onsets
        }
        for i in drops.indices where drops[i].z > 0 {
            // Accelerate toward the body's centre; absorbed once inside.
            velocity[i] = min(dropSpeed, velocity[i] + dt * dropSpeed * 2)
            let dx = center.x - drops[i].x
            let dy = center.y - drops[i].y
            let dist = max(hypot(dx, dy), 0.0001)
            drops[i].x += dx / dist * velocity[i] * dt * 0.6
            drops[i].y += dy / dist * velocity[i] * dt
            // Blue in flight; the instant it touches the body it's amber.
            // Any blend between the two passes through grey.
            // "Touch" is where the soft bridge starts: the edges within the fuse
            // distance (0.16), not the centres.
            let warm: Float = dist > radius + drops[i].z + 0.2 ? 1 : 0
            drops[i].w = min(drops[i].w, warm)
            if dist < radius * 0.6 {
                drops[i].z *= pow(0.85, dt * 60)
                tint = min(1, tint + dt * 3 * tintGain)
                if drops[i].z < 0.004 { drops[i] = .zero }
            }
        }
        tint *= pow(0.985, dt * 60)

        // While you talk (mic on) the coach is a blob — that's how it
        // listens. A named move beats the workout cycle; with neither, blob.
        // Mid-workout the mic stays open the whole time, so there it's a
        // blob only while words are actually being heard — not for gym
        // noise, not while you count (it does the reps with you), and not
        // mid-lesson.
        let listening = phase == .listening && !counting && lesson == nil && (!inWorkout || youTalking)
        if listening { life.rest(until: time + 2) }
        if phase != .rest { ambientLife.rest(until: time + 1.2) }
        let blob = BodyPose(joints: OneBodyMotion.standing(reduceMotion ? 0 : time), form: 0, side: 0, label: "")
        var pose = blob
        if !listening {
            if let shaped = move?.frame(at: moveTime, reducedMotion: reduceMotion) {
                pose = shaped
            } else if let demo, !reduceMotion {
                pose = demo.frame(at: time)
            } else if let lesson {
                let elapsed = Float(CACurrentMediaTime() - lesson.startedAt)
                switch lesson.body {
                case .hold(let depth):
                    // A slow, deliberate move into the position, then still.
                    let x = min(max(elapsed / 1.4, 0), 1)
                    let eased = x * x * (3 - 2 * x)
                    pose = lesson.motion.frame(holding: lesson.from + (depth - lesson.from) * eased, time: time)
                case .reps:
                    pose = lesson.motion.frame(at: elapsed)
                }
            } else if counting, let loop, !reduceMotion {
                pose = loop.frame(at: time)
            } else if inWorkout {
                if !reduceMotion, let alive = life.pose(motion: loop, setsDone: setsDone, time: time) {
                    pose = alive
                }
            } else if ambient, phase == .rest, !reduceMotion, let alive = ambientLife.pose(time: time) {
                pose = alive
            }
        }
        // The blob, as a person: every joint at its centre, as wide as it
        // is. A person in this pose has exactly the blob's outline, so the
        // two trade places without a visible crossfade.
        let sphereRadius = radius / max(bodyScale * Self.size, 0.01)
        let sphere = [Joint](repeating: Joint(0, 0, sphereRadius), count: joints.count)
        if reduceMotion {
            form += (pose.form - form)
            moveJoints(toward: pose.joints, dt: dt, reduceMotion: true)
        } else if pose.form < 0.01 {
            if form > 0 {
                // Becoming the blob: gather into its shape first, then hand
                // over — with a little plop.
                moveJoints(toward: sphere, dt: dt, reduceMotion: false, stiffness: 1.5)
                let spread = joints.map { simd_length(SIMD2($0.x, $0.y)) + abs($0.z - sphereRadius) }.max() ?? 0
                if spread < 0.09 {
                    form = max(0, form - dt * 7)
                    if form == 0 {
                        squashVelocity -= 2.4
                        folded = true
                    }
                }
            } else {
                joints = sphere
                jointVelocity = jointVelocity.map { _ in .zero }
                folded = true
            }
        } else {
            // Taking shape: start as the blob's exact outline and grow out of it.
            if folded {
                joints = sphere
                jointVelocity = jointVelocity.map { _ in .zero }
                folded = false
            }
            form += (pose.form - form) * (1 - exp(-dt * 14))
            moveJoints(toward: pose.joints, dt: dt, reduceMotion: false)
        }
        // The blob's squash is a loose spring: a landing presses it flat and
        // it wobbles back round.
        let squashTarget = pose.squash ?? squashBase
        if reduceMotion {
            squash += (squashTarget - squash) * k
        } else {
            squashVelocity += (-(13 * 13) * (squash - squashTarget) - 2 * 0.35 * 13 * squashVelocity) * dt
            squash = min(max(squash + squashVelocity * dt, 0.55), 1.4)
        }
        updateGear(for: pose, dt: dt, reduceMotion: reduceMotion)
        // Eased: acts switch between side-on and front-on.
        armDepth += (form * pose.side - armDepth) * (reduceMotion ? 1 : 1 - exp(-dt * 6))
    }
}

extension OrbModel {
    /// Each joint is a damped spring with its own weight: the hips and chest
    /// are heavy and settle without fuss, elbows and hands are light and
    /// carry on a little past where they're going, the head nods after the
    /// body stops. Feet, and hands on the floor, stay planted. This is what
    /// stops a demonstration looking like poses being swapped.
    fileprivate static func spring(_ joint: Int, planted: Bool) -> (stiffness: Float, damping: Float) {
        if planted { return (24, 1) }
        switch joint {
        case 0: return (11, 0.55)       // head
        case 1: return (10, 0.75)       // chest
        case 2: return (8.5, 0.85)      // hips
        case 3, 6: return (11, 0.75)    // shoulders
        case 4, 7: return (13, 0.62)    // elbows
        case 5, 8: return (15, 0.58)    // hands
        case 9, 11: return (12, 0.8)    // knees
        default: return (24, 1)         // feet
        }
    }

    /// Equipment grows out of the hands once the body has taken shape and
    /// melts back in before it goes back to a blob. Switching lifts melts
    /// the old gear first, then grows the new.
    fileprivate func updateGear(for pose: BodyPose, dt: Float, reduceMotion: Bool) {
        let wanted = pose.form > 0.5 ? pose.gear : .none
        let wantsBench = pose.form > 0.5 && pose.bench
        let changing = wanted != gearShown || wantsBench != benchShown
        if changing, gearGrow < 0.04 {
            gearShown = wanted
            benchShown = wantsBench
            gearSideOn = pose.side > 0.5
        }
        let hasGear = gearShown != .none || benchShown
        let target: Float = !changing && hasGear && form > 0.75 ? 1 : 0
        if reduceMotion {
            gearGrow = target
            gearGrowVelocity = 0
        } else {
            // A little overshoot: it pops out, then settles.
            let (w, z): (Float, Float) = target > 0 ? (9, 0.5) : (11, 0.9)
            let steps = max(1, Int((dt / (1 / 240)).rounded(.up)))
            let h = dt / Float(steps)
            for _ in 0..<steps {
                gearGrowVelocity += (-(w * w) * (gearGrow - target) - 2 * z * w * gearGrowVelocity) * h
                gearGrow += gearGrowVelocity * h
            }
            if gearGrow < 0 { gearGrow = 0; gearGrowVelocity = max(0, gearGrowVelocity) }
        }

        gearBlend = 0.02 + 0.11 * (1 - min(gearGrow, 1))
        var flat = [Float](repeating: -1, count: Self.maxGearShapes * 8)
        if gearGrow > 0.02 {
            let s = bodyScale * Self.size
            let shapes = GearShape.build(gear: gearShown, bench: benchShown, sideOn: gearSideOn,
                                         joints: joints, grow: gearGrow)
            for (i, shape) in shapes.prefix(Self.maxGearShapes).enumerated() {
                flat.replaceSubrange(i * 8 ..< i * 8 + 8, with: shape.scaled(s).floats)
            }
        }
        gearArray = flat
    }

    fileprivate func moveJoints(toward targets: [Joint], dt: Float, reduceMotion: Bool, stiffness: Float = 1) {
        guard !reduceMotion else {
            joints = targets
            jointVelocity = jointVelocity.map { _ in .zero }
            return
        }
        let floor: Float = -0.385
        // Small fixed substeps keep the springs stable on a slow frame.
        let steps = max(1, Int((dt / (1 / 240)).rounded(.up)))
        let h = dt / Float(steps)
        for i in joints.indices {
            let target = targets[i]
            let planted = [5, 8].contains(i) && target.y <= floor + 0.01
            let (base, z) = Self.spring(i, planted: planted)
            let w = base * stiffness
            var position = SIMD2(joints[i].x, joints[i].y)
            var velocity = jointVelocity[i]
            let goal = SIMD2(target.x, target.y)
            for _ in 0..<steps {
                velocity += (-(w * w) * (position - goal) - 2 * z * w * velocity) * h
                position += velocity * h
            }
            if [5, 8, 10, 12].contains(i), position.y < floor {
                position.y = floor
                velocity.y = max(0, velocity.y)
            }
            jointVelocity[i] = velocity
            joints[i] = Joint(position.x, position.y, joints[i].z + (target.z - joints[i].z) * (1 - exp(-dt * 10)))
        }
    }
}

/// The coach's body. Covers the whole screen — the paper shows through
/// everywhere but the body — so droplets can arrive from beyond the edges.
/// `focus` is where the body rests, in this view's own coordinates.
struct OrbView: View {
    let phase: OrbPhase
    let you: VoiceMeter
    let agent: VoiceMeter
    let focus: CGPoint?
    let director: BodyDirector
    var scale: CGFloat = 1
    /// The exercise being demonstrated during a workout, if any.
    var loop: ExerciseMotion? = nil
    var inWorkout = false
    /// A lift to show right now, continuously (the intro's choreography).
    var demo: ExerciseMotion? = nil
    /// Keep busy between conversations, like a trainer on the floor.
    var ambient = false
    /// A lesson beat to act out right now.
    var lesson: LessonCue? = nil
    /// You're counting reps out loud: do them with you.
    var counting = false
    /// Words are being heard right now (not just sound).
    var youTalking = false
    /// Where bloops start, in points from the top. Default: below the screen.
    var bloopStart: CGFloat? = nil
    var setsDone = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(YouColor.storageKey) private var youHex = YouColor.defaultHex
    @State private var model = OrbModel()

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { _ in
                let size = geo.size
                let _ = model.step(phase: phase, you: you.reading, agent: agent.reading,
                                   size: size, anchor: anchor(in: size),
                                   move: director.move, moveTime: director.elapsed,
                                   loop: loop, inWorkout: inWorkout, setsDone: setsDone, demo: demo,
                                   ambient: ambient, lesson: lesson, counting: counting, youTalking: youTalking,
                                   spawnY: bloopStart.map { -Float(($0 - size.height / 2) / (min(size.width, size.height) / 2)) },
                                   scale: Float(scale), reduceMotion: reduceMotion)
                Rectangle()
                    .fill(Color.white)
                    .colorEffect(ShaderLibrary.oneBody(
                        .float2(size),
                        .float(model.time),
                        .float(model.radius),
                        .float(model.squash),
                        .float2(model.center.x, model.center.y),
                        .float3(model.lobes.x, model.lobes.y, model.lobes.z),
                        .float(model.spin),
                        .float(0),  // the body stays amber; absorbed words warm to amber first
                        .float(0.16),
                        .float(0.025),
                        .float(0.14),
                        .float(0.05),
                        .color(MyoTheme.Colors.coachAmber),
                        .color(Color(hex: youHex)),
                        .floatArray(model.dropArray),
                        .floatArray(model.jointArray),
                        .float(model.form),
                        .float(model.armDepth),
                        .floatArray(model.gearArray),
                        .float(model.gearBlend)
                    ))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Converts the resting point from points to shader units.
    private func anchor(in size: CGSize) -> SIMD2<Float> {
        guard let focus, size.width > 0, size.height > 0 else { return .zero }
        let half = Float(min(size.width, size.height)) / 2
        return SIMD2(Float(focus.x - size.width / 2) / half,
                     -Float(focus.y - size.height / 2) / half)
    }
}

/// Which move the body is demonstrating, and since when. One move at a time;
/// it ends on its own when the choreography finishes, or on `rest()`.
@MainActor
final class BodyDirector: ObservableObject {
    @Published private(set) var move: BodyMove?
    private var startedAt: CFTimeInterval = 0

    var elapsed: Float { Float(CACurrentMediaTime() - startedAt) }

    /// The demonstration's current caption ("2 / 3 · Push away").
    var label: String? {
        move?.frame(at: elapsed, reducedMotion: false).label
    }

    func perform(_ next: BodyMove) {
        guard move == nil else { return }
        move = next
        let start = CACurrentMediaTime()
        startedAt = start
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(next.duration * 1_000_000_000))
            guard let self, self.startedAt == start else { return }
            self.move = nil
        }
    }

    func rest() {
        move = nil
        startedAt = 0
    }
}

/// The intro's choreography: words arrive as bloops and merge in, MYO
/// stands up into a lift for a couple of reps, melts back to a blob, more
/// bloops, a different lift. Loops for as long as the screen is up.
@MainActor
final class IntroChoreography: ObservableObject {
    @Published private(set) var demo: ExerciseMotion?
    let you = VoiceMeter()
    private var task: Task<Void, Never>?
    private static let lifts: [ExerciseMotion] = [
        ExerciseMotion(.squat, .dumbbell), ExerciseMotion(.overheadPress, .barbell),
        ExerciseMotion(.curl, .dumbbells), ExerciseMotion(.swing, .kettlebell),
    ]

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            var round = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.bloops(count: Int.random(in: 6...9))
                try? await Task.sleep(nanoseconds: 700_000_000)
                let lift = Self.lifts[round % Self.lifts.count]
                self.demo = lift
                try? await Task.sleep(nanoseconds: UInt64(lift.repDuration * 2.2 * 1_000_000_000))
                self.demo = nil
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                round += 1
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        demo = nil
        you.reset()
    }

    /// A short burst of syllables, as if someone were talking to it.
    private func bloops(count: Int) async {
        var reading = VoiceReading()
        reading.active = true
        for _ in 0..<count {
            guard !Task.isCancelled else { return }
            reading.onsets += 1
            reading.peak = Float.random(in: 0.45...0.95)
            reading.level = 0.5
            reading.presence = min(1, reading.presence + 0.35)
            you.set(reading)
            try? await Task.sleep(nanoseconds: UInt64.random(in: 180_000_000...380_000_000))
        }
        // Let the last bloops land, then let go of the lean.
        try? await Task.sleep(nanoseconds: 900_000_000)
        reading.active = false
        reading.presence = 0
        you.set(reading)
    }
}
