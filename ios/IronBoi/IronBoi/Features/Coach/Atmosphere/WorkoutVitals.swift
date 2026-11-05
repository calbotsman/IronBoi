import Foundation
import QuartzCore

/// The live numbers behind the workout screen's atmosphere and stats pill:
/// heart rate and zone, calories so far, time in the current zone during a
/// set, recovery during rest. Ticked once a second while a workout runs;
/// aims `EffortSignal` as it goes.
///
/// Reads `HeartRateHub.latest` (whatever wearable publishes into it) and
/// the workout's own state from AppModel. Owns no device.
@MainActor
final class WorkoutVitals: ObservableObject {
    /// One heart reading, fresh enough to show.
    struct Heart: Equatable {
        let bpm: Int
        let zone: Int?
    }

    /// The pill's third number: what matters for the part of the workout
    /// you're in.
    enum Context: Equatable {
        /// During a set: how long you've been in the zone you're in now.
        case inZone(zone: Int, seconds: Int)
        /// Resting with heart rate: beats dropped since the rest began.
        case recovering(drop: Int, seconds: Int)
        /// You're recovered (see `Recovery`).
        case recovered
        /// Resting without heart rate: what's left of the planned rest.
        case restLeft(seconds: Int)
        /// No heart rate, between rests: time into the workout.
        case elapsed(minutes: Int)
    }

    @Published private(set) var heart: Heart?
    /// Rounded to whole kcal, so the pill redraws once per calorie, not per
    /// tick. Only counted while there's heart rate; nil until then.
    @Published private(set) var kcal: Int?
    @Published private(set) var context: Context?
    /// Bumped once per rest when you're recovered; the screen says so.
    @Published private(set) var recoveredCount = 0

    /// A reading older than this is not "now".
    static let freshFor: TimeInterval = 15

    private var sessionId: String?
    private var kcalTotal: Double = 0
    private var hadCalories = false
    private var lastTick: Date?
    private var zoneSince: (zone: Int, at: Date)?
    private var restStartedAt: Date?
    private var restStartBpm: Int?
    private var recoveredReadings = 0
    private var recoveredThisRest = false
    private var lastReadingAt: Date?

    func tick(_ app: AppModel, now: Date = Date()) {
        let hub = HeartRateHub.shared
        guard let workout = app.activeWorkout else {
            if sessionId != nil { end() }
            return
        }
        if workout.sessionId != sessionId { begin(workout.sessionId, now: now) }
        let dt = min(max(now.timeIntervalSince(lastTick ?? now), 0), 5)
        lastTick = now

        let profile = app.profile
        let maxHR = HeartZones.maxHR(ageYears: profile.ageYears, observedPeak: hub.sessionPeak)
        let sample = hub.latest.flatMap { s -> HeartSample? in
            let age = now.timeIntervalSince(s.at)
            return age >= 0 && age <= Self.freshFor && (30...240).contains(s.bpm) ? s : nil
        }
        let newReading = sample.map { $0.at != lastReadingAt } ?? false
        lastReadingAt = sample?.at
        let zone = sample.flatMap { HeartZones.zone(bpm: $0.bpm, ageYears: profile.ageYears, observedPeak: hub.sessionPeak) }
        let shownHeart = sample.map { Heart(bpm: $0.bpm, zone: zone) }
        if heart != shownHeart { heart = shownHeart }

        if let rate = CalorieEstimate.perMinute(bpm: sample?.bpm, weightKg: profile.weightKg,
                                                ageYears: profile.ageYears, sex: profile.sexOrGender) {
            kcalTotal += rate * dt / 60
            hadCalories = true
        }
        let shownKcal = hadCalories ? Int(kcalTotal) : nil
        if kcal != shownKcal { kcal = shownKcal }

        // Rest starts and ends on the workout screen's timer.
        let resting = app.restEndsAt != nil
        if resting, restStartedAt == nil {
            restStartedAt = now
            restStartBpm = sample?.bpm
            recoveredReadings = 0
            recoveredThisRest = false
        } else if !resting, restStartedAt != nil {
            restStartedAt = nil
            restStartBpm = nil
        }
        // The rest began before a reading came in: the first one counts as its start.
        if resting, restStartBpm == nil { restStartBpm = sample?.bpm }

        if let zone, !resting {
            if zoneSince?.zone != zone { zoneSince = (zone, now) }
        } else {
            zoneSince = nil
        }

        var shownContext: Context?
        if resting, let started = restStartedAt {
            let restElapsed = now.timeIntervalSince(started)
            if let sample, let maxHR {
                if newReading,
                   Recovery.isRecovered(bpm: sample.bpm, restStartBpm: restStartBpm, maxHR: maxHR, restElapsed: restElapsed) {
                    recoveredReadings += 1
                } else if newReading {
                    recoveredReadings = 0
                }
                if recoveredReadings >= 2, !recoveredThisRest {
                    recoveredThisRest = true
                    recoveredCount += 1
                }
                if recoveredThisRest {
                    shownContext = .recovered
                } else {
                    // The wearable's own one-minute recovery when it sends one; else ours.
                    let drop = sample.recoveryDrop60 ?? restStartBpm.map { $0 - sample.bpm } ?? 0
                    shownContext = .recovering(drop: max(0, drop), seconds: Int(restElapsed))
                }
            } else if let ends = app.restEndsAt {
                shownContext = .restLeft(seconds: max(0, Int(ends.timeIntervalSince(now).rounded(.up))))
            }
        } else if let since = zoneSince {
            shownContext = .inZone(zone: since.zone, seconds: Int(now.timeIntervalSince(since.at)))
        } else if let started = AppModel.parseISO(workout.startedAt) {
            shownContext = .elapsed(minutes: max(0, Int(now.timeIntervalSince(started) / 60)))
        }
        if context != shownContext { context = shownContext }

        // Effort: heart rate when it's there and we know your max; the
        // workout's state when it isn't.
        let target: Float
        if let sample, let maxHR {
            target = EffortTarget.fromHeart(bpm: sample.bpm, maxHR: maxHR)
        } else if resting {
            target = EffortTarget.fromState(.resting)
        } else {
            let started = workout.exercises.contains { $0.completedSetCount > 0 } || app.timedBlock != nil
            target = EffortTarget.fromState(started ? .working : .warmingUp)
        }
        EffortSignal.shared.aim(at: target)
    }

    private func begin(_ id: String, now: Date) {
        sessionId = id
        kcalTotal = 0
        hadCalories = false
        lastTick = now
        zoneSince = nil
        restStartedAt = nil
        restStartBpm = nil
        recoveredReadings = 0
        recoveredThisRest = false
        EffortSignal.shared.reset(to: 0)
    }

    private func end() {
        sessionId = nil
        heart = nil
        kcal = nil
        context = nil
        lastTick = nil
        EffortSignal.shared.aim(at: 0)
    }
}
