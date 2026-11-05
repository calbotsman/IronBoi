import Foundation
import HealthKit
import WatchKit

/// Runs the Watch side of a MYO workout: the HKWorkoutSession and its live
/// builder, mirrored to the phone.
///
/// The phone starts it (`HKHealthStore.startWatchApp(with:)` → the app
/// delegate's `handle(_:)`), sends what to show as `WatchMessage.state`, and
/// ends it with `.end`. This side streams heart rate and active energy back,
/// and saves the HKWorkout (with heart rate and energy) to Health.
/// docs/product/responsive-coach-plan.md §2.
@MainActor
final class WatchWorkoutManager: NSObject, ObservableObject {
    static let shared = WatchWorkoutManager()

    enum Phase: Equatable {
        case idle
        case starting
        case running
        case paused
        case ending
        case ended(saved: Bool)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// The latest heart rate from the session, and when it was measured.
    @Published private(set) var bpm: Int?
    @Published private(set) var bpmAt: Date?
    @Published private(set) var peakBpm: Int?
    /// What the phone says to show. Nil until the phone's first message.
    @Published private(set) var state: WatchWorkoutState?

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    /// What the phone asked for at the end: save or discard.
    private var endRequest: (sessionId: String, save: Bool)?
    private var lastHeartSentAt: Date?
    private var restHapticTask: Task<Void, Never>?

    private static let heartRate = HKQuantityType(.heartRate)
    private static let activeEnergy = HKQuantityType(.activeEnergyBurned)

    // MARK: - Start

    /// The phone pressed Start. Creates the session, mirrors it, starts it.
    func start(configuration: HKWorkoutConfiguration) {
        if session != nil, phase == .running || phase == .paused || phase == .starting { return }
        phase = .starting
        bpm = nil
        bpmAt = nil
        peakBpm = nil
        state = nil
        endRequest = nil
        Task { await begin(configuration: configuration) }
    }

    private func begin(configuration: HKWorkoutConfiguration) async {
        do {
            try await store.requestAuthorization(
                toShare: [HKObjectType.workoutType(), Self.heartRate, Self.activeEnergy],
                read: [Self.heartRate, Self.activeEnergy])
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            // Mirror before starting, so the phone sees the whole session.
            try await session.startMirroringToCompanionDevice()
            let start = Date()
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
            phase = .running
        } catch {
            log("start failed: \(error.localizedDescription)")
            session?.end()
            phase = .failed(error.localizedDescription)
        }
    }

    /// The app was relaunched mid-workout (watchOS calls
    /// `handleActiveWorkoutRecovery`): pick the session back up.
    func recover() {
        store.recoverActiveWorkoutSession { session, error in
            Task { @MainActor in
                guard let session else {
                    if let error { self.log("recovery failed: \(error.localizedDescription)") }
                    return
                }
                self.attach(recovered: session)
            }
        }
    }

    private func attach(recovered session: HKWorkoutSession) {
        let builder = session.associatedWorkoutBuilder()
        session.delegate = self
        builder.delegate = self
        self.session = session
        self.builder = builder
        phase = session.state == .paused ? .paused : .running
        // Mirroring stops when the app dies; ask again so the phone hears us.
        Task {
            do { try await session.startMirroringToCompanionDevice() } catch {
                log("re-mirror failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Controls

    func setDone() {
        send(.setDone)
        WKInterfaceDevice.current().play(.click)
    }

    func togglePause() {
        guard let session else { return }
        switch session.state {
        case .running: session.pause()
        case .paused: session.resume()
        default: break
        }
    }

    /// The End button. The phone owns the workout (it logs it to the
    /// backend), so the Watch asks it to finish; the phone answers `.end`.
    /// Without a phone to answer, the Watch ends and saves on its own.
    func requestEnd() {
        guard let session, phase == .running || phase == .paused else { return }
        send(.endRequested)
        phase = .ending
        Task {
            // The phone normally answers within a second or two.
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard self.phase == .ending, self.session === session else { return }
            self.log("phone didn't answer End; ending on the Watch")
            self.endRequest = self.state.map { ($0.sessionId, $0.saveToHealth) }
            session.end()
        }
    }

    // MARK: - From the phone

    func receive(_ message: WatchMessage) {
        switch message {
        case .state(let next):
            let previous = state
            state = next
            scheduleRestHaptic(previous: previous?.restEndsAt, next: next.restEndsAt)
            // A tap when the coach asks something, so you look at the Watch.
            if let caption = next.caption, caption != previous?.caption, caption.hasSuffix("?") {
                WKInterfaceDevice.current().play(.notification)
            }
        case .end(let sessionId, let save):
            endRequest = (sessionId, save)
            phase = .ending
            session?.end()
        case .heart, .setDone, .endRequested:
            break // Watch → phone only.
        }
    }

    private func scheduleRestHaptic(previous: Date?, next: Date?) {
        guard next != previous else { return }
        restHapticTask?.cancel()
        guard let ends = next, ends > Date() else { return }
        restHapticTask = Task {
            let wait = ends.timeIntervalSinceNow
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            guard !Task.isCancelled, self.state?.restEndsAt == ends else { return }
            WKInterfaceDevice.current().play(.start)
        }
    }

    // MARK: - To the phone

    private func send(_ message: WatchMessage) {
        guard let session, let data = message.encoded() else { return }
        session.sendToRemoteWorkoutSession(data: data) { success, error in
            if !success { Task { @MainActor in self.log("send failed: \(error?.localizedDescription ?? "unknown")") } }
        }
    }

    // MARK: - End and save

    /// The session ended: stop collecting, then save or discard the workout.
    private func finish(at date: Date) async {
        guard let builder else { return }
        let request = endRequest ?? state.map { ($0.sessionId, $0.saveToHealth) }
        do {
            try await builder.endCollection(at: date)
            if let request, request.save {
                var metadata: [String: Any] = [
                    // The phone's session id, so this workout and any the phone
                    // saved for the same session are one workout to Health.
                    HKMetadataKeySyncIdentifier: request.sessionId,
                    // Above the phone's own save (version 1): this one has heart rate.
                    HKMetadataKeySyncVersion: 2,
                ]
                if let name = state?.workoutName, !name.isEmpty { metadata[HKMetadataKeyWorkoutBrandName] = name }
                try await builder.addMetadata(metadata)
                _ = try await builder.finishWorkout()
                phase = .ended(saved: true)
            } else {
                // Health saving is off on the phone, or the phone never sent
                // which workout this was: keep nothing.
                builder.discardWorkout()
                phase = .ended(saved: false)
            }
        } catch {
            log("finish failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
        restHapticTask?.cancel()
        session = nil
        self.builder = nil
    }

    private func log(_ line: String) {
        print("[MYOWatch] \(line)")
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in
            guard workoutSession === self.session else { return }
            switch toState {
            case .running: self.phase = .running
            case .paused: self.phase = .paused
            case .ended: await self.finish(at: date)
            default: break
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.log("session failed: \(error.localizedDescription)") }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        let messages = data.compactMap(WatchMessage.decode)
        Task { @MainActor in messages.forEach(self.receive) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        Task { @MainActor in self.log("phone disconnected: \(error?.localizedDescription ?? "no error")") }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let heartRate = HKQuantityType(.heartRate)
        guard collectedTypes.contains(heartRate) else { return }
        let perMinute = HKUnit.count().unitDivided(by: .minute())
        let stats = workoutBuilder.statistics(for: heartRate)
        guard let quantity = stats?.mostRecentQuantity() else { return }
        let bpm = Int(quantity.doubleValue(for: perMinute).rounded())
        let at = stats?.mostRecentQuantityDateInterval()?.end ?? Date()
        let energy = workoutBuilder.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        Task { @MainActor in self.collected(bpm: bpm, at: at, energy: energy) }
    }

    private func collected(bpm: Int, at: Date, energy: Double?) {
        self.bpm = bpm
        bpmAt = at
        peakBpm = max(peakBpm ?? 0, bpm)
        // About every 5 s to the phone; the Watch screen updates on every reading.
        if let last = lastHeartSentAt, Date().timeIntervalSince(last) < 4.5 { return }
        lastHeartSentAt = Date()
        send(.heart(bpm: bpm, at: at, activeEnergyKcal: energy))
    }
}
