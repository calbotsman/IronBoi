import XCTest

/// The live-voice reconnect rules: the mic on always means something is
/// listening, a drop puts the regular coach straight back, and live is
/// retried with backoff.
final class LiveVoicePolicyTests: XCTestCase {
    func testMicOnOpensRegularMicAtOnceAndConnectsLiveBehindIt() {
        var policy = LiveVoicePolicy()
        XCTAssertEqual(policy.micOn(liveWanted: true), [.openRegularMic, .connectLive])
        XCTAssertEqual(policy.mode, .regular)
        XCTAssertTrue(policy.liveInFlight)
    }

    func testMicOnWithoutLiveIsJustTheRegularCoach() {
        var policy = LiveVoicePolicy()
        XCTAssertEqual(policy.micOn(liveWanted: false), [.openRegularMic])
        XCTAssertEqual(policy.liveEnded(.closed), [])
        XCTAssertEqual(policy.retryDue(), [])
    }

    func testReadyHandsOverThenLiveHasTheMic() {
        var policy = LiveVoicePolicy()
        _ = policy.micOn(liveWanted: true)
        XCTAssertEqual(policy.liveReady(), [.handOverWhenIdle])
        policy.handedOver()
        XCTAssertEqual(policy.mode, .live)
        XCTAssertFalse(policy.liveInFlight)
    }

    func testDropWhileLiveHasTheMicReopensRegularAndSchedulesRetry() {
        var policy = LiveVoicePolicy()
        _ = policy.micOn(liveWanted: true)
        _ = policy.liveReady()
        policy.handedOver()
        XCTAssertEqual(policy.liveEnded(.network), [.openRegularMic, .scheduleRetry(after: 2)])
        XCTAssertEqual(policy.mode, .regular)
        XCTAssertEqual(policy.retryDue(), [.connectLive])
    }

    func testFailureWhileConnectingKeepsRegularWithoutReopening() {
        // Today's log: the regular coach is already listening, so a failed
        // connect must not restart its mic — only schedule another try.
        var policy = LiveVoicePolicy()
        _ = policy.micOn(liveWanted: true)
        XCTAssertEqual(policy.liveEnded(.connectFailed), [.scheduleRetry(after: 2)])
        XCTAssertEqual(policy.mode, .regular)
    }

    func testBackoffGrowsAndCaps() {
        var policy = LiveVoicePolicy()
        _ = policy.micOn(liveWanted: true)
        var waits: [TimeInterval] = []
        for _ in 0..<(LiveVoicePolicy.maxFailures - 1) {
            for effect in policy.liveEnded(.closed) {
                if case .scheduleRetry(let after) = effect { waits.append(after) }
            }
            XCTAssertEqual(policy.retryDue(), [.connectLive])
        }
        XCTAssertEqual(waits, [2, 4, 8, 15, 30])
        // The last allowed failure settles on the regular coach.
        XCTAssertEqual(policy.liveEnded(.closed), [])
        XCTAssertEqual(policy.retryDue(), [])
        XCTAssertEqual(policy.mode, .regular)
    }

    func testReadyThenDropStillCountsTowardTheCap() {
        // F27/B5: a session that reaches ready and then dies must not reset
        // the backoff, or it retries forever, minting each time.
        var policy = LiveVoicePolicy()
        _ = policy.micOn(liveWanted: true)
        var waits: [TimeInterval] = []
        for _ in 0..<(LiveVoicePolicy.maxFailures - 1) {
            _ = policy.liveReady()
            policy.handedOver()
            for effect in policy.liveEnded(.closed) {
                if case .scheduleRetry(let after) = effect { waits.append(after) }
            }
            _ = policy.retryDue()
        }
        XCTAssertEqual(waits, [2, 4, 8, 15, 30])
        _ = policy.liveReady()
        policy.handedOver()
        XCTAssertEqual(policy.liveEnded(.closed), [.openRegularMic])
        XCTAssertEqual(policy.retryDue(), [])
    }

    func testHealthyLiveResetsTheBackoff() {
        var policy = LiveVoicePolicy()
        _ = policy.micOn(liveWanted: true)
        _ = policy.liveEnded(.closed)
        _ = policy.retryDue()
        _ = policy.liveReady()
        policy.handedOver()
        policy.liveHealthy()
        XCTAssertEqual(policy.liveEnded(.closed), [.openRegularMic, .scheduleRetry(after: 2)])
    }

    func testMicOffDropsEverythingAndLateEventsDoNothing() {
        var policy = LiveVoicePolicy()
        _ = policy.micOn(liveWanted: true)
        XCTAssertEqual(policy.micOff(), [.cancelRetry, .dropLive, .closeRegularMic])
        XCTAssertEqual(policy.mode, .off)
        XCTAssertEqual(policy.liveReady(), [])
        XCTAssertEqual(policy.liveEnded(.closed), [])
        XCTAssertEqual(policy.retryDue(), [])
        XCTAssertEqual(policy.micOff(), [])
    }

    func testUserStopIsNotAFailure() {
        var policy = LiveVoicePolicy()
        _ = policy.micOn(liveWanted: true)
        _ = policy.liveReady()
        policy.handedOver()
        XCTAssertEqual(policy.liveEnded(.user), [])
        XCTAssertEqual(policy.failures, 0)
    }

    func testToggleFiveTimesAlwaysListens() {
        // Josh's device check, as a sequence: every mic-on opens the
        // regular mic first, whatever live was doing when it went off.
        var policy = LiveVoicePolicy()
        for round in 0..<5 {
            XCTAssertEqual(policy.micOn(liveWanted: true).first, .openRegularMic, "round \(round)")
            if round.isMultiple(of: 2) {
                _ = policy.liveReady()
                policy.handedOver()
            }
            _ = policy.micOff()
            XCTAssertEqual(policy.mode, .off)
        }
    }

    func testLateReadyAfterAFallbackStillHandsOver() {
        var policy = LiveVoicePolicy()
        _ = policy.micOn(liveWanted: true)
        _ = policy.liveReady()
        policy.handedOver()
        _ = policy.liveEnded(.network)
        XCTAssertEqual(policy.liveReady(), []) // nothing in flight yet
        _ = policy.retryDue()
        XCTAssertEqual(policy.liveReady(), [.handOverWhenIdle])
    }

}
