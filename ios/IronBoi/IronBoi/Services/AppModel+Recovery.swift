import Foundation

/// Recovery from Apple Health for the coach (Phase 4 of
/// docs/product/responsive-coach-plan.md): read on foreground and at
/// workout start, sent as `liveContext.recovery` and in the live voice
/// setup. When it's clearly low, the coach may offer a lighter session once
/// a day before the workout; the offer goes through adapt_plan's review
/// card or a banked alternative, never a silent change.
extension AppModel {
    /// Reads are cheap but not free: at most every 15 minutes unless forced.
    static let recoveryRefreshInterval: TimeInterval = 15 * 60
    private static let lighterOfferedKey = "recovery.lighterOfferedOn"

    func refreshRecovery(force: Bool = false, now: Date = Date()) async {
        let health = HealthSync.shared
        guard health.recoveryEnabled else {
            recovery = nil
            return
        }
        if !force, let at = recoveryReadAt, now.timeIntervalSince(at) < Self.recoveryRefreshInterval { return }
        recoveryReadAt = now
        recovery = await health.readRecovery(now: now)
    }

    /// The `liveContext.recovery` block, or nil (reads off, no data).
    func recoveryPayload() -> [String: Any]? {
        guard HealthSync.shared.recoveryEnabled, let recovery else { return nil }
        return RecoveryBaseline.payload(recovery, offerLighter: mayOfferLighterSession)
    }

    /// Low recovery, not offered yet today, a training day not yet trained,
    /// and the workout (if any) hasn't got past its first set.
    var mayOfferLighterSession: Bool {
        guard todayPlanDay != nil || activeWorkout != nil else { return false }
        let trainedToday = CoachContext.rhythm(logs: workoutLogs)["daysSinceLast"] as? Int == 0
        guard !trainedToday else { return false }
        let setsDone = activeWorkout.map { $0.exercises.reduce(0) { $0 + $1.completedSetCount } }
        return RecoveryBaseline.mayOfferLighter(
            summary: recovery,
            offeredOn: UserDefaults.standard.string(forKey: Self.lighterOfferedKey),
            today: todayISO,
            setsDone: setsDone)
    }

    func noteLighterOffered() {
        UserDefaults.standard.set(todayISO, forKey: Self.lighterOfferedKey)
    }
}
