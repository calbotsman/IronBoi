import AVFoundation
import Foundation

/// The coach's live context: what it should know about you right now,
/// beyond the exercise you're on. Rest and session progress, heart rate
/// (when a wearable streams it), how training has gone lately, and how the
/// coach is being heard. Sent as `liveContext` with every text message and
/// pushed to the live voice coach as `[app] Context:` notes.
///
/// Mirrors `LiveCoachContext` in functions/src/contracts/coach-agent.ts —
/// keep the keys and bounds in step. Numbers only; the server turns them
/// into words and rules (functions/src/coach/liveWorkout.ts).
/// Plan: docs/product/responsive-coach-plan.md.
enum CoachContext {
    /// How training has gone lately, from finished workout logs (newest
    /// first, as AppModel holds them). Nil before the logs have loaded.
    static func rhythm(logs: [WorkoutLogSummary], now: Date = Date(), calendar: Calendar = .current) -> [String: Any] {
        let today = calendar.startOfDay(for: now)
        let days: [Int] = logs.compactMap { log in
            guard let day = log.day else { return nil }
            return calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: today).day
        }.filter { $0 >= 0 }
        var rhythm: [String: Any] = [
            "sessionsLast7d": min(days.filter { $0 < 7 }.count, 50),
            "sessionsLast28d": min(days.filter { $0 < 28 }.count, 200),
        ]
        if let last = days.min() { rhythm["daysSinceLast"] = min(last, 3650) }
        let efforts = logs.compactMap { $0.perceivedEffort.map(effortRating) }.prefix(3)
        if !efforts.isEmpty { rhythm["recentEfforts"] = Array(efforts) }
        return rhythm
    }

    /// The 1–10 score the server stores for "How did that feel?" (easy 4,
    /// about right 6, too much 9 — activeWorkout.ts) back to its answer.
    static func effortRating(_ score: Int) -> String {
        switch score {
        case ...5: return "easy"
        case 6...8: return "about_right"
        default: return "too_much"
        }
    }

    /// How the coach is being heard: voice on or read on screen, and
    /// whether your own music is playing under it.
    /// Reads the Sound settings (CoachMix): voice on/off and the music dip.
    static func delivery() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        return [
            "speaksReplies": CoachMix.voiceOn,
            "musicPlaying": session.isOtherAudioPlaying || session.secondaryAudioShouldBeSilencedHint,
            "musicDip": CoachMix.dip.rawValue,
        ]
    }

    /// The live heart rate, if one is fresh enough to send at all.
    static func heart(_ sample: HeartSample?, ageYears: Int?, peak: Int?, now: Date = Date()) -> [String: Any]? {
        guard let sample else { return nil }
        let age = Int(now.timeIntervalSince(sample.at).rounded())
        guard age >= 0, age <= 600, (30...240).contains(sample.bpm) else { return nil }
        var heart: [String: Any] = ["source": sample.source.rawValue, "bpm": sample.bpm, "ageSec": age]
        if let zone = HeartZones.zone(bpm: sample.bpm, ageYears: ageYears, observedPeak: peak) { heart["zone"] = zone }
        if let trend = sample.trend { heart["trend"] = trend.rawValue }
        if let drop = sample.recoveryDrop60 { heart["recoveryDrop60"] = max(-60, min(drop, 120)) }
        if let peak, (30...240).contains(peak) { heart["sessionPeak"] = peak }
        return heart
    }

    /// One line for the live voice coach. Coarse on purpose (heart rate to
    /// the nearest 5, no ticking rest seconds), so it only changes when
    /// something worth knowing does.
    static func voiceNote(_ context: [String: Any]) -> String? {
        var parts: [String] = []
        if let session = context["session"] as? [String: Any] {
            if let sets = session["setsDone"] as? Int, let minutes = session["minutesIn"] as? Int {
                parts.append("\(minutes) min in, \(sets) sets done")
            }
            if let planned = session["restPlannedSec"] as? Int, session["restElapsedSec"] != nil {
                parts.append("resting (\(planned) s planned)")
            }
            // Whole minutes for cardio, so the note changes once a minute, not every second.
            if let timed = session["timed"] as? [String: Any], let planned = timed["plannedSec"] as? Int {
                if timed["kind"] as? String == "cardio", let elapsed = timed["elapsedSec"] as? Int {
                    parts.append("on cardio, \(elapsed / 60) of \(max(1, planned / 60)) min")
                } else {
                    parts.append("holding (\(planned) s)")
                }
            }
        }
        if let heart = context["heart"] as? [String: Any], let bpm = heart["bpm"] as? Int,
           let age = heart["ageSec"] as? Int, age <= 15 {
            var line = "heart rate about \(Int((Double(bpm) / 5).rounded()) * 5)"
            if let zone = heart["zone"] as? Int { line += ", zone \(zone)" }
            if let trend = heart["trend"] as? String { line += ", \(trend)" }
            parts.append(line)
        }
        if let rhythm = context["rhythm"] as? [String: Any], let week = rhythm["sessionsLast7d"] as? Int {
            var line = "\(week) workouts this week"
            if let days = rhythm["daysSinceLast"] as? Int { line += ", last one \(days == 0 ? "earlier today" : "\(days) days ago")" }
            if let efforts = rhythm["recentEfforts"] as? [String], !efforts.isEmpty {
                line += ", recent efforts \(efforts.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", "))"
            }
            parts.append(line)
        }
        if let delivery = context["delivery"] as? [String: Any] {
            if delivery["speaksReplies"] as? Bool == false { parts.append("they read you on screen, voice off") }
            if delivery["musicPlaying"] as? Bool == true {
                parts.append(delivery["musicDip"] as? String == "none" ? "their music is on and not lowered for you" : "their music is on")
            }
        }
        return parts.isEmpty ? nil : "Context: " + parts.joined(separator: "; ") + "."
    }
}

// MARK: - Heart rate

/// One heart-rate reading from whatever wearable is streaming.
struct HeartSample: Equatable {
    enum Source: String { case watch, strap, airpods }
    enum Trend: String { case rising, steady, falling }
    let bpm: Int
    let at: Date
    let source: Source
    var trend: Trend?
    /// Beats dropped in the first minute of the current rest.
    var recoveryDrop60: Int?
}

/// Where live heart rate lands, whichever device sends it. Empty until a
/// source exists: the Watch app (Phase 2), a Bluetooth strap or AirPods
/// (Phase 3). The coach context reads `latest`; nothing reads a device.
@MainActor
final class HeartRateHub: ObservableObject {
    static let shared = HeartRateHub()
    @Published private(set) var latest: HeartSample?
    /// Highest reading this workout.
    @Published private(set) var sessionPeak: Int?

    func publish(_ sample: HeartSample) {
        latest = sample
        sessionPeak = max(sessionPeak ?? 0, sample.bpm)
    }

    /// A new workout: forget the last one's readings.
    func reset() {
        latest = nil
        sessionPeak = nil
    }
}

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
