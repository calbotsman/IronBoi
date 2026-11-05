import Combine
import Foundation
import HealthKit
import WatchConnectivity

/// The phone's side of a Watch workout (the Peloton moment): Start on the
/// phone opens MYO on the Watch, which runs the HKWorkoutSession and
/// mirrors it here.
///
/// - Start: `HKHealthStore.startWatchApp(with:)` when a Watch is paired and
///   has MYO installed. If that fails (Watch locked, off-wrist, out of
///   range) the workout carries on phone-only; nothing waits on it.
/// - Live: the mirrored session (`workoutSessionMirroringStartHandler`, set
///   at launch) carries `WatchMessage`s. Heart rate and active energy go to
///   `HeartRateHub`; Set done and End go to the workout; the phone sends the
///   workout state back for the Watch to show.
/// - End: the phone sends `.end`; the Watch saves the HKWorkout, so the
///   phone's own `HealthSync.saveWorkout` is skipped.
///
/// docs/product/responsive-coach-plan.md §2.
@MainActor
final class WatchWorkoutLink: NSObject, ObservableObject {
    static let shared = WatchWorkoutLink()

    /// A Watch session is mirrored to this phone right now.
    @Published private(set) var isMirroring = false
    /// Set done was pressed on the Watch. The coach screen takes it (and
    /// clears it) so the set is logged the way a spoken "set done" is; if
    /// nothing takes it, `AppModel` logs the set itself.
    @Published var setDoneRequest: UUID?

    private let store = HKHealthStore()
    private var mirrored: HKWorkoutSession?
    /// The phone workout the mirrored session belongs to.
    private var mirroredWorkoutId: String?
    private var lastSent: WatchWorkoutState?
    /// The phone workout whose Watch session ended on the Watch's side (the
    /// Watch's own End fallback). The Watch saved or discarded it already,
    /// by the same Health setting the phone would use.
    private var watchEndedWorkoutId: String?
    private var bindings: Set<AnyCancellable> = []
    private weak var appModel: AppModel?

    private static let heartRate = HKQuantityType(.heartRate)
    private static let activeEnergy = HKQuantityType(.activeEnergyBurned)

    // MARK: - Launch

    /// Call from `App.init`. The mirroring handler must be in place before
    /// the Watch starts mirroring, including when iOS launches the app in
    /// the background for a mirrored session (no UI, no AppModel yet).
    ///
    /// Never reads the property back: on Josh's iPhone (iOS 26.6) the
    /// getter isn't there — `-[HKHealthStore workoutSessionMirroringStartHandler]`
    /// was an unrecognized selector and the app aborted at launch
    /// (2026-11-05 crash log). A flag tracks it, and the setter is checked
    /// before use, so a device without it simply has no Watch mirroring.
    private var mirroringHandlerInstalled = false
    func installMirroringHandler() {
        guard HKHealthStore.isHealthDataAvailable(), !mirroringHandlerInstalled else { return }
        guard store.responds(to: NSSelectorFromString("setWorkoutSessionMirroringStartHandler:")) else {
            AudioHub.log("watch: this iOS has no workout mirroring handler")
            return
        }
        store.workoutSessionMirroringStartHandler = { session in
            Task { @MainActor in WatchWorkoutLink.shared.attach(session) }
        }
        mirroringHandlerInstalled = true
    }

    /// Call when the app model starts: Set done and End need it, and the
    /// Watch's screen is drawn from it.
    func configure(appModel: AppModel) {
        guard self.appModel == nil else { return }
        self.appModel = appModel
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        bind(appModel)
        // A session may have arrived before the UI did.
        pushState()
    }

    /// Re-send the Watch's view of the workout whenever what it shows changes.
    private func bind(_ appModel: AppModel) {
        Publishers.MergeMany(
            appModel.$activeWorkout.map { _ in () }.eraseToAnyPublisher(),
            appModel.$restEndsAt.map { _ in () }.eraseToAnyPublisher(),
            appModel.$messages.map { _ in () }.eraseToAnyPublisher(),
            appModel.$focusedExerciseIndex.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
        .sink { [weak self] in self?.pushState() }
        .store(in: &bindings)
        // Heart-rate zones need the profile's age, whichever device streams.
        appModel.$profile
            .map(\.ageYears)
            .removeDuplicates()
            .sink { HeartRateHub.shared.ageYears = $0 }
            .store(in: &bindings)
    }

    // MARK: - Start

    /// Opens MYO on the Watch for the workout that just started. Returns at
    /// once; the Watch shows up (or doesn't) on its own time.
    func startWatchWorkout(activityType: HKWorkoutActivityType) {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        if WCSession.isSupported(), WCSession.default.activationState == .activated,
           !WCSession.default.isPaired || !WCSession.default.isWatchAppInstalled {
            return // No Watch, or MYO isn't on it: phone-only, as before.
        }
        Task {
            // Asked here, at the first Watch workout, not at onboarding.
            // iOS shows the sheet once; after that this returns at once.
            do {
                // The same set the Watch asks for, so the Watch's own request
                // finds nothing new to ask and doesn't stall on its screen.
                try await store.requestAuthorization(
                    toShare: [HKObjectType.workoutType(), Self.heartRate, Self.activeEnergy],
                    read: [Self.heartRate, Self.activeEnergy])
            } catch {
                AudioHub.log("watch: health auth failed: \(error.localizedDescription)")
            }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = activityType
            configuration.locationType = .indoor
            store.startWatchApp(with: configuration) { success, error in
                if !success {
                    // Locked, off-wrist, out of range: the workout goes on without it.
                    Task { @MainActor in AudioHub.log("watch: start failed: \(error?.localizedDescription ?? "unknown")") }
                }
            }
        }
    }

    // MARK: - Mirrored session

    private func attach(_ session: HKWorkoutSession) {
        mirrored = session
        session.delegate = self
        // The Watch is the best heart-rate source; an iPhone session would double-count.
        PhoneWorkoutSession.shared.yieldToWatch()
        mirroredWorkoutId = appModel?.activeWorkout?.sessionId
        isMirroring = true
        lastSent = nil
        AudioHub.log("watch: mirrored session attached")
        pushState()
    }

    private func detach() {
        mirrored = nil
        mirroredWorkoutId = nil
        isMirroring = false
        lastSent = nil
    }

    private func receive(_ message: WatchMessage) {
        switch message {
        case .heart(let bpm, let at, let energy):
            HeartRateHub.shared.publish(HeartSample(bpm: bpm, at: at, source: .watch))
            if let energy { HeartRateHub.shared.publishActiveEnergy(kcal: energy) }
        case .setDone:
            let request = UUID()
            setDoneRequest = request
            // The coach screen normally takes it at once. If it isn't on
            // screen, log the set here so the Watch button always works.
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard self.setDoneRequest == request else { return }
                self.setDoneRequest = nil
                self.appModel?.logSetFromWatch()
            }
        case .endRequested:
            guard let appModel, appModel.activeWorkout != nil else { return }
            // Tell the Watch at once; the finish below waits on the backend.
            send(.endAccepted)
            Task { await appModel.finishActiveWorkout() }
        case .state, .end, .endAccepted:
            break // Phone → Watch only.
        }
    }

    // MARK: - To the Watch

    private func pushState() {
        guard isMirroring, let state = appModel?.watchState(), state != lastSent else { return }
        if mirroredWorkoutId == nil { mirroredWorkoutId = state.sessionId }
        lastSent = state
        send(.state(state))
    }

    private func send(_ message: WatchMessage) {
        guard let mirrored, let data = message.encoded() else { return }
        mirrored.sendToRemoteWorkoutSession(data: data) { success, error in
            if !success { Task { @MainActor in AudioHub.log("watch: send failed: \(error?.localizedDescription ?? "unknown")") } }
        }
    }

    /// The workout finished (save) or was thrown away (no save). Returns
    /// true when the Watch takes care of Health: it was running this
    /// workout and got the message, so the phone must not save it too.
    func endWorkout(sessionId: String, save: Bool) async -> Bool {
        // The Watch already ended this one itself and took care of Health.
        if watchEndedWorkoutId == sessionId { return true }
        guard let mirrored, isMirroring, mirroredWorkoutId == nil || mirroredWorkoutId == sessionId,
              let data = WatchMessage.end(sessionId: sessionId, save: save).encoded() else { return false }
        do {
            try await mirrored.sendToRemoteWorkoutSession(data: data)
            return true
        } catch {
            AudioHub.log("watch: end not delivered, phone saves instead: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - HKWorkoutSessionDelegate (the mirrored session)

extension WatchWorkoutLink: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended else { return }
        Task { @MainActor in
            guard workoutSession === self.mirrored else { return }
            self.watchEndedWorkoutId = self.mirroredWorkoutId
            self.detach()
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in AudioHub.log("watch: mirrored session failed: \(error.localizedDescription)") }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        let messages = data.compactMap(WatchMessage.decode)
        Task { @MainActor in messages.forEach(self.receive) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        Task { @MainActor in
            AudioHub.log("watch: disconnected: \(error?.localizedDescription ?? "no error")")
            if workoutSession === self.mirrored { self.detach() }
        }
    }
}

// MARK: - WCSessionDelegate (only to read isPaired / isWatchAppInstalled)

extension WatchWorkoutLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // A different Watch was paired: activate for the new one.
        session.activate()
    }
}
