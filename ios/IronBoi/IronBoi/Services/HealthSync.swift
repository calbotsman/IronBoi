import Foundation
import HealthKit

/// Saves finished workouts to Apple Health, when you've turned it on.
///
/// This is the phone's own save, for workouts without a Watch. When the
/// Watch ran the workout it saves it instead, with heart rate and energy,
/// and this is skipped (WatchWorkoutLink / AppModel+Watch). Each saved
/// workout carries the session id as its sync identifier, so Health replaces
/// rather than duplicates if the same app saves the same session twice.
///
/// No calories: MYO doesn't measure them, and Health would show a guess as
/// if it were a reading. Duration and the workout type are what we know.
@MainActor
final class HealthSync: ObservableObject {
    static let shared = HealthSync()

    @Published private(set) var enabled: Bool
    /// Reading recovery (resting heart rate, HRV, sleep) for the coach.
    /// Separate from saving workouts: its own switch, its own ask.
    @Published private(set) var recoveryEnabled: Bool

    private let defaults = UserDefaults.standard
    private let store = HKHealthStore()
    private static let enabledKey = "health.saveWorkouts"
    private static let recoveryKey = "health.readRecovery"

    private init() {
        enabled = HKHealthStore.isHealthDataAvailable() && defaults.bool(forKey: Self.enabledKey)
        recoveryEnabled = HKHealthStore.isHealthDataAvailable() && defaults.bool(forKey: Self.recoveryKey)
    }

    /// Health exists on this device (not on some iPads).
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Turns saving on. Asks iOS the first time; returns false if Health
    /// said no. iOS never reveals a refused write permission up front, so
    /// "no" here only covers the cases it does tell us.
    @discardableResult
    func enable() async -> Bool {
        guard isAvailable else { return false }
        do {
            // Workouts, plus heart rate: what a Watch or AirPods workout
            // reads live and saves with the workout (PhoneWorkoutSession
            // only runs when this was granted, so it never asks mid-workout).
            try await store.requestAuthorization(
                toShare: [HKObjectType.workoutType(), HKQuantityType(.heartRate)],
                read: [HKQuantityType(.heartRate)])
        } catch {
            AudioHub.log("health auth failed: \(error.localizedDescription)")
            return false
        }
        let ok = store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
        set(enabled: ok)
        return ok
    }

    func disable() { set(enabled: false) }

    // MARK: - Recovery reads (Phase 4)

    /// What recovery reads, and nothing else. Whoop, Oura and Garmin write
    /// these into Health too, so whatever the person wears shows up here.
    static let recoveryReadTypes: Set<HKObjectType> = [
        HKQuantityType(.restingHeartRate),
        HKQuantityType(.heartRateVariabilitySDNN),
        HKCategoryType(.sleepAnalysis),
    ]

    /// Turns recovery reads on, asking iOS the first time (from the switch
    /// in You → Training, never at launch). iOS never says whether reads
    /// were allowed: a "no" just means the queries come back empty, and
    /// then the coach has nothing to say about recovery.
    @discardableResult
    func enableRecovery() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: Self.recoveryReadTypes)
        } catch {
            AudioHub.log("health recovery auth failed: \(error.localizedDescription)")
            return false
        }
        recoveryEnabled = true
        defaults.set(true, forKey: Self.recoveryKey)
        return true
    }

    func disableRecovery() {
        recoveryEnabled = false
        defaults.set(false, forKey: Self.recoveryKey)
    }

    /// The last 24 h of resting HR, HRV and sleep against the 28 days
    /// before (RecoveryBaseline). Nil when off or Health has nothing.
    /// Never throws: a failed read just means no recovery today.
    func readRecovery(now: Date = Date()) async -> RecoveryBaseline.Summary? {
        guard recoveryEnabled, isAvailable else { return nil }
        async let restingHr = dailyAverages(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), now: now)
        async let hrv = dailyAverages(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), now: now)
        async let sleep = lastDaySleepHours(now: now)
        let summary = RecoveryBaseline.summarize(restingHr: await restingHr, hrv: await hrv, sleepHours: await sleep)
        return summary.hasData ? summary : nil
    }

    /// One average per 24 h window ending now (daysAgo 0 = the last 24 h),
    /// over the baseline window plus today. Health's statistics merge
    /// sources by the person's own priority order, so a Watch and an Oura
    /// both writing resting HR don't double-count.
    private func dailyAverages(_ id: HKQuantityTypeIdentifier, unit: HKUnit, now: Date) async -> [RecoveryBaseline.Daily] {
        let calendar = Calendar.current
        guard let start = calendar.date(byAdding: .day, value: -(RecoveryBaseline.windowDays + 1), to: now) else { return [] }
        let type = HKQuantityType(id)
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: start, end: now)),
            options: .discreteAverage,
            anchorDate: now,
            intervalComponents: DateComponents(day: 1))
        do {
            let collection = try await descriptor.result(for: store)
            var out: [RecoveryBaseline.Daily] = []
            collection.enumerateStatistics(from: start, to: now) { stats, _ in
                guard let value = stats.averageQuantity()?.doubleValue(for: unit) else { return }
                let daysAgo = Int((now.timeIntervalSince(stats.endDate) / 86_400).rounded())
                out.append(.init(daysAgo: daysAgo, value: value))
            }
            return out
        } catch {
            AudioHub.log("health recovery read failed (\(id.rawValue)): \(error.localizedDescription)")
            return []
        }
    }

    /// Hours asleep in the last 24 h (any asleep stage; in bed and awake
    /// don't count), overlapping sources merged.
    private func lastDaySleepHours(now: Date) async -> Double? {
        let window = DateInterval(start: now.addingTimeInterval(-86_400), end: now)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis),
                                         predicate: HKQuery.predicateForSamples(withStart: window.start, end: window.end))],
            sortDescriptors: [])
        do {
            let asleep = HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue)
            let intervals = try await descriptor.result(for: store)
                .filter { asleep.contains($0.value) }
                .map { DateInterval(start: $0.startDate, end: max($0.startDate, $0.endDate)) }
            return RecoveryBaseline.sleepHours(asleep: intervals, in: window)
        } catch {
            AudioHub.log("health sleep read failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func set(enabled on: Bool) {
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
    }

    /// Saves one finished session. Quietly does nothing when off, and never
    /// throws: a workout that didn't reach Health isn't worth an error card.
    func saveWorkout(sessionId: String, name: String, activity: String? = nil, start: Date, end: Date) async {
        guard enabled, end > start,
              store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = Self.activityType(for: name, activity: activity)
        configuration.locationType = activity.map { ["running", "walking", "cycling", "hiking"].contains($0) } == true ? .unknown : .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        do {
            try await builder.beginCollection(at: start)
            try await builder.addMetadata([
                HKMetadataKeySyncIdentifier: sessionId,
                HKMetadataKeySyncVersion: 1,
                HKMetadataKeyWorkoutBrandName: name,
            ])
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
        } catch {
            AudioHub.log("health save failed: \(error.localizedDescription)")
        }
    }

    /// A switched session says what it was ("running", "yoga"; the server's
    /// SessionActivity). Otherwise the plan names its mobility days and
    /// everything else MYO builds is strength.
    static func activityType(for name: String, activity: String? = nil) -> HKWorkoutActivityType {
        switch activity {
        case "running": return .running
        case "walking": return .walking
        case "cycling": return .cycling
        case "rowing": return .rowing
        case "swimming": return .swimming
        case "hiking": return .hiking
        case "yoga": return .yoga
        case "flexibility": return .flexibility
        case "strength": return .traditionalStrengthTraining
        default:
            return name.localizedCaseInsensitiveContains("mobility") ? .flexibility : .traditionalStrengthTraining
        }
    }
}
