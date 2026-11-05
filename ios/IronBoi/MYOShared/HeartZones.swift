import Foundation

/// Heart-rate zones, shared by the phone (coach context) and the Watch
/// (the color of the big BPM number).
enum HeartZones {
    /// 1–5 as a share of max heart rate (50/60/70/80/90%). Max is the
    /// age-predicted 208 − 0.7 × age, raised to the highest reading seen if
    /// that's higher. Nil without an age: a peak alone would call the first
    /// reading of the day zone 5.
    static func zone(bpm: Int, ageYears: Int?, observedPeak: Int?) -> Int? {
        guard let max = maxHR(ageYears: ageYears, observedPeak: observedPeak) else { return nil }
        let share = Double(bpm) / max
        switch share {
        case ..<0.6: return 1
        case ..<0.7: return 2
        case ..<0.8: return 3
        case ..<0.9: return 4
        default: return 5
        }
    }

    /// The max heart rate the zones are shares of (see `zone`).
    static func maxHR(ageYears: Int?, observedPeak: Int?) -> Double? {
        guard let age = ageYears, (10...100).contains(age) else { return nil }
        return Swift.max(208 - 0.7 * Double(age), Double(observedPeak ?? 0))
    }
}

/// A heart-rate zone that doesn't flicker. Optical heart rate during
/// lifting is noisy (wrist flexion on presses), so the zone comes from the
/// last 10 s of readings averaged, and only changes once the new zone has
/// held for 15 s. The first zone of a workout is taken at once.
/// docs/product/responsive-coach-plan.md, Risks: "Coach overreacting to HR".
struct ZoneTracker {
    static let smoothing: TimeInterval = 10
    static let hysteresis: TimeInterval = 15

    private(set) var zone: Int?
    private var window: [(at: Date, bpm: Int)] = []
    private var candidate: (zone: Int, since: Date)?

    /// The last 10 s of readings, averaged. Nil before any reading.
    var smoothedBpm: Int? {
        guard !window.isEmpty else { return nil }
        return Int((Double(window.map(\.bpm).reduce(0, +)) / Double(window.count)).rounded())
    }

    /// Adds a reading; returns the (possibly unchanged) zone.
    @discardableResult
    mutating func add(bpm: Int, at: Date, ageYears: Int?, observedPeak: Int?) -> Int? {
        window.append((at, bpm))
        window.removeAll { at.timeIntervalSince($0.at) > Self.smoothing }
        guard let smoothed = smoothedBpm,
              let next = HeartZones.zone(bpm: smoothed, ageYears: ageYears, observedPeak: observedPeak) else {
            return zone
        }
        guard let current = zone else {
            zone = next
            return zone
        }
        if next == current {
            candidate = nil
        } else if let pending = candidate, pending.zone == next {
            if at.timeIntervalSince(pending.since) >= Self.hysteresis {
                zone = next
                candidate = nil
            }
        } else {
            candidate = (next, at)
        }
        return zone
    }

    mutating func reset() { self = ZoneTracker() }
}
