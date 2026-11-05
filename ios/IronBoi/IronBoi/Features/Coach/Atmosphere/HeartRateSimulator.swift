#if DEBUG
import Foundation

/// A pretend wearable for the simulator (DEBUG only), so the atmosphere,
/// MYO's mood, the stats pill and "you're recovered" can be seen without a
/// Watch. Publishes into `HeartRateHub` exactly as a real source would.
///
/// MYO_HR_SIM=
///   calm     ~95 bpm, steady
///   pumped   ~85% of max, steady
///   follow   climbs during sets, falls during rest (the workout screen's timer)
///   wave     climbs for 50 s, falls for 50 s, on its own clock
///
/// The "IronBoi Heart" scheme in project.yml runs the preview with `wave`.
@MainActor
final class HeartRateSimulator {
    enum Mode: String { case calm, pumped, follow, wave }

    static let mode: Mode? = ProcessInfo.processInfo.environment["MYO_HR_SIM"].flatMap(Mode.init)

    private var bpm: Double = 78
    private let startedAt = Date()

    /// One reading, about a second after the last.
    func step(_ app: AppModel, now: Date = Date()) {
        guard let mode = Self.mode, app.activeWorkout != nil else { return }
        let maxHR = HeartZones.maxHR(ageYears: app.profile.ageYears, observedPeak: nil) ?? 185
        let target: Double
        var tau: Double = 20
        switch mode {
        case .calm:
            target = 95
            tau = 4
        case .pumped:
            target = 0.85 * maxHR
            tau = 4
        case .follow:
            if app.restEndsAt != nil {
                target = 0.57 * maxHR
                tau = 28
            } else {
                target = 0.86 * maxHR
                tau = 22
            }
        case .wave:
            let phase = now.timeIntervalSince(startedAt).truncatingRemainder(dividingBy: 100)
            target = phase < 50 ? 0.88 * maxHR : 0.56 * maxHR
            tau = phase < 50 ? 14 : 18
        }
        bpm += (target - bpm) * (1 - exp(-1 / tau))
        let jitter = Double.random(in: -1.5...1.5)
        let sample = HeartSample(bpm: Int((bpm + jitter).rounded()), at: now, source: .watch)
        HeartRateHub.shared.publish(sample)
    }
}
#endif
