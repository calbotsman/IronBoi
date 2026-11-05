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

    private let defaults = UserDefaults.standard
    private let store = HKHealthStore()
    private static let enabledKey = "health.saveWorkouts"

    private init() {
        enabled = HKHealthStore.isHealthDataAvailable() && defaults.bool(forKey: Self.enabledKey)
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
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])
        } catch {
            AudioHub.log("health auth failed: \(error.localizedDescription)")
            return false
        }
        let ok = store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
        set(enabled: ok)
        return ok
    }

    func disable() { set(enabled: false) }

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
