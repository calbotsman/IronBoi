import SwiftUI
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
    private(set) var form: Float = 0
    private(set) var armDepth: Float = 0
    private var bodyScale: Float = 1
    private var life = WorkoutLife()
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
              demo: ExerciseMotion? = nil, spawnY: Float? = nil,
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
        squash += (1 - you.presence * squashGain + agentPresence * (pitch - 0.5) * 0.2 - squash) * k
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
        let listening = phase == .listening
        if listening { life.rest(until: time + 2) }
        let blob = BodyPose(joints: OneBodyMotion.standing(reduceMotion ? 0 : time), form: 0, side: 0, label: "")
        var pose = blob
        if !listening {
            if let shaped = move?.frame(at: moveTime, reducedMotion: reduceMotion) {
                pose = shaped
            } else if let demo, !reduceMotion {
                pose = demo.frame(at: time)
            } else if inWorkout, !reduceMotion,
                      let alive = life.pose(motion: loop, setsDone: setsDone, time: time) {
                pose = alive
            }
        }
        let motionEase = reduceMotion ? 1 : 1 - exp(-dt * 7)
        form += (pose.form - form) * motionEase
        for i in joints.indices {
            let rate: Float = i == 0 ? 8 : [5, 8, 10, 12].contains(i) ? 16 : 10
            let follow = reduceMotion ? 1 : 1 - exp(-dt * rate)
            joints[i] += (pose.joints[i] - joints[i]) * follow
        }
        armDepth = form * pose.side
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
                        .float(model.armDepth)
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
    private static let lifts: [ExerciseMotion] = [.squat, .overheadPress, .curl, .lateralRaise]

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
