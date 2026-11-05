import HealthKit
import SwiftUI
import WatchKit

@main
struct MYOWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: MYOWatchDelegate

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(WatchWorkoutManager.shared)
        }
    }
}

/// watchOS hands workout launches to the application delegate.
final class MYOWatchDelegate: NSObject, WKApplicationDelegate {
    /// The phone pressed Start: `HKHealthStore.startWatchApp(with:)` launched
    /// or woke this app with the workout's configuration.
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in WatchWorkoutManager.shared.start(configuration: workoutConfiguration) }
    }

    /// The app was relaunched while its workout session was still running.
    func handleActiveWorkoutRecovery() {
        Task { @MainActor in WatchWorkoutManager.shared.recover() }
    }
}
