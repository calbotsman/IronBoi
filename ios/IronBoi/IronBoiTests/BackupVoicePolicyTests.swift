import XCTest

final class BackupVoicePolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { start.addingTimeInterval(s) }

    func testOneReplysSentencesFailingTogetherDoNotCount() {
        var policy = BackupVoicePolicy()
        XCTAssertFalse(policy.shouldTryBackup(after: "openai", failures: [at(0), at(1)], liveActive: false, now: at(1)))
    }

    func testTwoSeparateRepliesFailingTryTheBackup() {
        var policy = BackupVoicePolicy()
        XCTAssertTrue(policy.shouldTryBackup(after: "openai", failures: [at(0), at(8)], liveActive: false, now: at(8)))
    }

    func testOneProbePerWindow() {
        var policy = BackupVoicePolicy()
        XCTAssertTrue(policy.shouldTryBackup(after: "openai", failures: [at(0), at(8)], liveActive: false, now: at(8)))
        XCTAssertFalse(policy.shouldTryBackup(after: "openai", failures: [at(0), at(8), at(20)], liveActive: false, now: at(37)))
        XCTAssertTrue(policy.shouldTryBackup(after: "openai", failures: [at(8), at(20), at(38)], liveActive: false, now: at(38)))
    }

    func testNeverWhileLiveVoiceIsOn() {
        var policy = BackupVoicePolicy()
        XCTAssertFalse(policy.shouldTryBackup(after: "openai", failures: [at(0), at(8)], liveActive: true, now: at(8)))
        policy.backupAnswered(now: at(8))
        XCTAssertFalse(policy.shouldTryBackup(after: "openai", failures: [], liveActive: true, now: at(9)))
    }

    func testBackupFailingLeavesTheVoiceAlone() {
        var policy = BackupVoicePolicy()
        XCTAssertTrue(policy.shouldTryBackup(after: "openai", failures: [at(0), at(8)], liveActive: false, now: at(8)))
        XCTAssertFalse(policy.isActive(now: at(9)))
    }

    func testOnceSwitchedItCoversLinesAlreadyStarted() {
        var policy = BackupVoicePolicy()
        policy.backupAnswered(now: at(10))
        XCTAssertTrue(policy.shouldTryBackup(after: "openai", failures: [], liveActive: false, now: at(11)))
    }

    func testTheCoachsVoiceIsTriedAgainAfterAFewMinutes() {
        var policy = BackupVoicePolicy()
        policy.backupAnswered(now: at(0))
        XCTAssertTrue(policy.isActive(now: at(BackupVoicePolicy.recheckAfter - 1)))
        XCTAssertFalse(policy.isActive(now: at(BackupVoicePolicy.recheckAfter)))
        XCTAssertFalse(policy.shouldTryBackup(after: "openai", failures: [], liveActive: false, now: at(BackupVoicePolicy.recheckAfter)))
    }

    func testTheBackupHasNoBackup() {
        var policy = BackupVoicePolicy()
        XCTAssertFalse(policy.shouldTryBackup(after: BackupVoicePolicy.backupEngine, failures: [at(0), at(8)], liveActive: false, now: at(8)))
    }
}
