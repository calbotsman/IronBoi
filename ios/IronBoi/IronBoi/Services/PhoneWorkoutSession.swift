import AVFoundation
import Foundation
import HealthKit

/// Heart rate from AirPods (AirPods Pro 3, Powerbeats Pro 2) with no Watch:
/// iOS 26 lets the iPhone run its own HKWorkoutSession + HKLiveWorkoutBuilder,
/// and heart rate from supported earbuds arrives through the live data source.
///
/// Used only when no Watch session is mirrored (a phone and a Watch session
/// for one workout would count twice) and Bluetooth audio is connected. If
/// no heart rate arrives within 20 s, the earbuds can't measure it: the
/// session is ended and its recording thrown away, and the workout carries
/// on as before. When it does stream, this session saves the workout to
/// Health (with heart rate) and the phone's plain HealthSync save is skipped.
///
/// compiler(>=6.2) ⇔ the Xcode 26 SDK, where these iOS APIs exist; CI's
/// older Xcode compiles the stub below instead.
/// docs/product/responsive-coach-plan.md §3.
@MainActor
final class PhoneWorkoutSession: NSObject, ObservableObject {
    static let shared = PhoneWorkoutSession()

    /// A phone session is running and heart rate has arrived from it.
    @Published private(set) var isStreaming = false

    private let store = HKHealthStore()
    private var session: AnyObject?
    private var builder: AnyObject?
    private var sessionId: String?
    private var gotHeartRate = false
    private var finishing: CheckedContinuation<Bool, Never>?
    private var endPlan: (save: Bool, name: String)?

    /// Whether this iPhone can run its own workout session.
    var isSupported: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return HKHealthStore.isHealthDataAvailable() }
        #endif
        return false
    }

    /// Headphones that might measure heart rate are connected (any Bluetooth
    /// output; whether they actually can is found out from the readings).
    static var bluetoothAudioConnected: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains($0.portType)
        }
    }

    /// Start, for the workout `sessionId`, if supported and nothing better
    /// is streaming.
    func startIfUseful(sessionId: String, activityType: HKWorkoutActivityType) {
        guard isSupported, session == nil, Self.bluetoothAudioConnected,
              !WatchWorkoutLink.shared.isMirroring else { return }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { Task { await begin(sessionId: sessionId, activityType: activityType) } }
        #endif
    }

    /// The workout ended. Returns true when this session saved it (so the
    /// phone mustn't save it again).
    func end(save: Bool, name: String) async -> Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let session = session as? HKWorkoutSession {
            guard gotHeartRate else {
                stop(discard: true)
                return false
            }
            endPlan = (save, name)
            return await withCheckedContinuation { continuation in
                finishing = continuation
                session.end()
            }
        }
        #endif
        return false
    }

    /// A Watch session showed up after all: it wins, this one goes.
    func yieldToWatch() {
        guard session != nil else { return }
        AudioHub.log("phone session: Watch took over")
        stop(discard: true)
    }

    private func stop(discard: Bool) {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            (session as? HKWorkoutSession)?.end()
            if discard { (builder as? HKLiveWorkoutBuilder)?.discardWorkout() }
        }
        #endif
        session = nil
        builder = nil
        sessionId = nil
        isStreaming = false
        gotHeartRate = false
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private func begin(sessionId: String, activityType: HKWorkoutActivityType) async {
        let heartRate = HKQuantityType(.heartRate)
        do {
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType(), heartRate], read: [heartRate])
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = activityType
            configuration.locationType = .indoor
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            self.sessionId = sessionId
            gotHeartRate = false
            let start = Date()
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
            AudioHub.log("phone session: started, waiting for heart rate")
        } catch {
            AudioHub.log("phone session: start failed: \(error.localizedDescription)")
            stop(discard: true)
            return
        }
        // No heart rate in 20 s: these earbuds don't measure it.
        try? await Task.sleep(nanoseconds: 20_000_000_000)
        if self.sessionId == sessionId, !gotHeartRate {
            AudioHub.log("phone session: no heart rate from headphones, stopping")
            stop(discard: true)
        }
    }

    @available(iOS 26.0, *)
    private func finish(at date: Date) async {
        guard let builder = builder as? HKLiveWorkoutBuilder, let sessionId else {
            finishing?.resume(returning: false)
            finishing = nil
            return
        }
        var saved = false
        do {
            try await builder.endCollection(at: date)
            if let plan = endPlan, plan.save {
                var metadata: [String: Any] = [
                    HKMetadataKeySyncIdentifier: sessionId,
                    // Above HealthSync's version 1: this one has heart rate.
                    HKMetadataKeySyncVersion: 2,
                ]
                if !plan.name.isEmpty { metadata[HKMetadataKeyWorkoutBrandName] = plan.name }
                try await builder.addMetadata(metadata)
                _ = try await builder.finishWorkout()
                saved = true
            } else {
                builder.discardWorkout()
                // Nothing to save, and nothing for HealthSync to save either.
                saved = true
            }
        } catch {
            AudioHub.log("phone session: save failed: \(error.localizedDescription)")
        }
        self.session = nil
        self.builder = nil
        self.sessionId = nil
        isStreaming = false
        gotHeartRate = false
        endPlan = nil
        finishing?.resume(returning: saved)
        finishing = nil
    }
    #endif
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
extension PhoneWorkoutSession: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended else { return }
        Task { @MainActor in
            guard workoutSession === self.session, self.finishing != nil else { return }
            await self.finish(at: date)
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in AudioHub.log("phone session failed: \(error.localizedDescription)") }
    }
}

@available(iOS 26.0, *)
extension PhoneWorkoutSession: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let heartRate = HKQuantityType(.heartRate)
        guard collectedTypes.contains(heartRate),
              let stats = workoutBuilder.statistics(for: heartRate),
              let quantity = stats.mostRecentQuantity() else { return }
        let bpm = Int(quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())).rounded())
        let at = stats.mostRecentQuantityDateInterval()?.end ?? Date()
        Task { @MainActor in
            guard workoutBuilder === self.builder else { return }
            self.gotHeartRate = true
            self.isStreaming = true
            HeartRateHub.shared.publish(HeartSample(bpm: bpm, at: at, source: .airpods))
        }
    }
}
#endif
