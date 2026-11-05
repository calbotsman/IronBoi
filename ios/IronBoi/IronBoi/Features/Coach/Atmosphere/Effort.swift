import Foundation
import QuartzCore

/// How hard you're working right now, 0 (calm) … 1 (pumping), eased so the
/// screen and MYO drift with you instead of flashing on a spike.
///
/// Read every frame by the atmosphere shader and the orb, written about once
/// a second by `WorkoutVitals`. Like `VoiceMeter`, deliberately not an
/// ObservableObject: it changes continuously and SwiftUI shouldn't re-render
/// for it. The easing is computed on read from the elapsed time, so it's
/// smooth at any frame rate and costs nothing between reads.
final class EffortSignal: @unchecked Sendable {
    static let shared = EffortSignal()

    /// Exponential time constant. Three of them (~10 s) covers 95% of a
    /// change: the "blend over about ten seconds" in docs/product/ideas.md.
    static let timeConstant: Double = 10.0 / 3

    private let lock = NSLock()
    private var from: Float = 0
    private var target: Float = 0
    private var changedAt: CFTimeInterval = CACurrentMediaTime()

    /// The eased value now.
    func current(now: CFTimeInterval = CACurrentMediaTime()) -> Float {
        lock.lock(); defer { lock.unlock() }
        return Self.eased(from: from, to: target, elapsed: now - changedAt)
    }

    /// Where it's heading. Re-aiming starts from wherever the ease has got
    /// to, so a new target never jumps the value.
    func aim(at newTarget: Float, now: CFTimeInterval = CACurrentMediaTime()) {
        lock.lock(); defer { lock.unlock() }
        let clamped = min(max(newTarget, 0), 1)
        guard clamped != target else { return }
        from = Self.eased(from: from, to: target, elapsed: now - changedAt)
        target = clamped
        changedAt = now
    }

    /// Jump straight there: a new workout starts calm, not mid-fade from the last.
    func reset(to value: Float = 0) {
        lock.lock(); defer { lock.unlock() }
        from = value
        target = value
        changedAt = CACurrentMediaTime()
    }

    static func eased(from: Float, to: Float, elapsed: Double) -> Float {
        let k = Float(exp(-max(elapsed, 0) / timeConstant))
        return to + (from - to) * k
    }
}

/// Where effort is heading, from heart rate when there is one and from the
/// workout's own state when there isn't.
enum EffortTarget {
    /// The share of max heart rate that reads as fully calm, and fully pumping.
    /// 55% sits low in zone 1; 90% is the top of zone 4.
    static let calmShare = 0.55
    static let pumpedShare = 0.90

    /// What the workout itself says, with no heart rate: a working set
    /// reads as effort, rest as calm. Values sit inside the heart-rate
    /// range rather than at its ends, because state alone can't tell an
    /// easy set from a brutal one.
    enum State { case warmingUp, working, resting }
    static func fromState(_ state: State) -> Float {
        switch state {
        case .warmingUp: return 0.35
        case .working: return 0.65
        case .resting: return 0.2
        }
    }

    static func fromHeart(bpm: Int, maxHR: Double) -> Float {
        let share = Double(bpm) / maxHR
        return Float(min(max((share - calmShare) / (pumpedShare - calmShare), 0), 1))
    }
}

/// Calories from heart rate (Keytel et al. 2005, J Sports Sci 23:289),
/// the same kind of estimate a watch makes. Nil without a fresh heart rate,
/// your weight and age: no flat guess from time alone.
enum CalorieEstimate {
    /// kcal per minute.
    static func perMinute(bpm: Int?, weightKg: Double?, ageYears: Int?, sex: UserSex?) -> Double? {
        guard let bpm, let weightKg, (25...300).contains(weightKg),
              let age = ageYears, (10...100).contains(age) else { return nil }
        let hr = Double(bpm), w = weightKg, a = Double(age)
        // kJ/min → kcal/min. Without a stated male or female, the mean of the two.
        let male = (-55.0969 + 0.6309 * hr + 0.1988 * w + 0.2017 * a) / 4.184
        let female = (-20.4022 + 0.4472 * hr - 0.1263 * w + 0.074 * a) / 4.184
        let kcal: Double
        switch sex {
        case .male: kcal = male
        case .female: kcal = female
        default: kcal = (male + female) / 2
        }
        // The formula runs negative near resting heart rate, where it
        // wasn't fitted; never below sitting still (~1.3 MET: kcal/min =
        // MET × 3.5 × kg / 200).
        return max(kcal, 1.3 * 3.5 * w / 200)
    }
}

/// When a rest counts as recovered: your heart rate is back under 65% of
/// max (the middle of zone 2) having been above 70% when the rest started,
/// for two readings in a row, at least 20 seconds in.
enum Recovery {
    static let recoveredShare = 0.65
    static let elevatedShare = 0.70
    static let minimumRest: TimeInterval = 20

    static func isRecovered(bpm: Int, restStartBpm: Int?, maxHR: Double, restElapsed: TimeInterval) -> Bool {
        guard restElapsed >= minimumRest, let start = restStartBpm,
              Double(start) / maxHR >= elevatedShare else { return false }
        return Double(bpm) / maxHR <= recoveredShare
    }
}
