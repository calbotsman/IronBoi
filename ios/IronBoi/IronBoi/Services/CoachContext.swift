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
    /// `zone` is the hub's smoothed, hysteresis-held zone (HeartRateHub.zone).
    static func heart(_ sample: HeartSample?, zone: Int?, peak: Int?, now: Date = Date()) -> [String: Any]? {
        guard let sample else { return nil }
        let age = Int(now.timeIntervalSince(sample.at).rounded())
        guard age >= 0, age <= 600, (30...240).contains(sample.bpm) else { return nil }
        var heart: [String: Any] = ["source": sample.source.rawValue, "bpm": sample.bpm, "ageSec": age]
        if let zone, (1...5).contains(zone) { heart["zone"] = zone }
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
        // Recovery changes once a day at most; only the verdict, no numbers.
        if let recovery = context["recovery"] as? [String: Any], recovery["low"] as? Bool == true {
            let signals = (recovery["signals"] as? [String] ?? []).map { $0.replacingOccurrences(of: "_", with: " ") }
            parts.append("recovery low today (\(signals.joined(separator: ", ")))")
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

/// Where live heart rate lands, whichever device sends it: the Watch app
/// (WatchWorkoutLink), a Bluetooth strap (HeartStrapConnector) or AirPods
/// through an iPhone workout session (PhoneWorkoutSession, iOS 26). The
/// coach context reads `latest`; nothing reads a device directly.
///
/// When several stream at once the best live one wins: Watch > strap >
/// AirPods. A source counts as live while its last reading is under
/// `liveWindow` old; readings from a lower source are ignored meanwhile.
///
/// Interface other code relies on (the atmosphere visuals read it): `latest`,
/// `sessionPeak`, `zone`, `activeEnergyKcal`, `publish(_:)`, `reset()`. `latest`
/// carries `trend` and `recoveryDrop60`, computed here when the source
/// doesn't send them.
@MainActor
final class HeartRateHub: ObservableObject {
    static let shared = HeartRateHub()
    @Published private(set) var latest: HeartSample?
    /// Highest reading this workout.
    @Published private(set) var sessionPeak: Int?
    /// Heart-rate zone 1–5, from the last 10 s averaged and held 15 s
    /// before it changes (ZoneTracker), so wrist noise doesn't flip it.
    /// Nil without an age on the profile.
    @Published private(set) var zone: Int?
    /// From the profile, for zones (kept current by WatchWorkoutLink).
    var ageYears: Int?
    private var zoneTracker = ZoneTracker()
    /// Active energy this workout so far, as the Watch measures it. Kept
    /// for the coach and visuals; not shown as a number in the app.
    @Published private(set) var activeEnergyKcal: Double?

    /// Best first.
    static let priority: [HeartSample.Source] = [.watch, .strap, .airpods]
    /// The Watch sends about every 5 s; a gap of 12 s means it dropped.
    static let liveWindow: TimeInterval = 12
    private var lastSeen: [HeartSample.Source: Date] = [:]

    /// The last 60 s of readings, oldest first, for the trend.
    private var recent: [(at: Date, bpm: Int)] = []
    /// The reading when the current rest began, for the recovery drop.
    private var restStart: (at: Date, bpm: Int)?
    private var restDrop60: Int?

    func publish(_ sample: HeartSample) {
        lastSeen[sample.source] = sample.at
        let best = Self.priority.first { source in
            lastSeen[source].map { sample.at.timeIntervalSince($0) <= Self.liveWindow } ?? false
        }
        guard best == sample.source else { return }
        // A new source: its readings don't trend against the last one's.
        if let current = latest?.source, current != sample.source { recent = [] }
        recent.append((sample.at, sample.bpm))
        recent.removeAll { sample.at.timeIntervalSince($0.at) > 60 }
        var sample = sample
        if sample.trend == nil { sample.trend = trend(now: sample.at) }
        if sample.recoveryDrop60 == nil { sample.recoveryDrop60 = recoveryDrop(sample) }
        latest = sample
        sessionPeak = max(sessionPeak ?? 0, sample.bpm)
        zone = zoneTracker.add(bpm: sample.bpm, at: sample.at, ageYears: ageYears, observedPeak: sessionPeak)
    }

    func publishActiveEnergy(kcal: Double) {
        guard kcal.isFinite, kcal >= 0 else { return }
        activeEnergyKcal = kcal
    }

    /// The rest timer started (a date) or ended (nil). The drop in the first
    /// minute of rest is how fast the heart comes down.
    func noteRest(startedAt: Date?) {
        restDrop60 = nil
        guard let startedAt, let bpm = latest?.bpm, let at = latest?.at,
              startedAt.timeIntervalSince(at) < 15 else {
            restStart = nil
            return
        }
        restStart = (startedAt, bpm)
    }

    /// A new workout: forget the last one's readings.
    func reset() {
        latest = nil
        sessionPeak = nil
        activeEnergyKcal = nil
        zone = nil
        zoneTracker.reset()
        lastSeen = [:]
        recent = []
        restStart = nil
        restDrop60 = nil
    }

    /// Rising or falling: the last 10 s against 20–30 s before, by 5 bpm or
    /// more. Nil until there's half a minute of readings.
    private func trend(now: Date) -> HeartSample.Trend? {
        func mean(_ range: ClosedRange<TimeInterval>) -> Double? {
            let values = recent.filter { range.contains(now.timeIntervalSince($0.at)) }.map(\.bpm)
            return values.isEmpty ? nil : Double(values.reduce(0, +)) / Double(values.count)
        }
        guard let late = mean(0...10), let early = mean(20...30) else { return nil }
        let change = late - early
        return change >= 5 ? .rising : change <= -5 ? .falling : .steady
    }

    /// Beats dropped once a minute of rest has passed (fixed from then on).
    private func recoveryDrop(_ sample: HeartSample) -> Int? {
        if let restDrop60 { return restDrop60 }
        guard let start = restStart, sample.at.timeIntervalSince(start.at) >= 60 else { return nil }
        restDrop60 = start.bpm - sample.bpm
        return restDrop60
    }
}

// HeartZones lives in MYOShared/HeartZones.swift: the Watch colors its BPM with it too.
