import XCTest

final class BackupVoicePolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testOneFailedLineDoesNotChangeTheVoice() {
        var policy = BackupVoicePolicy()
        XCTAssertFalse(policy.shouldTryBackup(after: "openai", failingRepeatedly: false, now: start))
    }

    func testRepeatedFailureTriesTheBackupOnceAWindow() {
        var policy = BackupVoicePolicy()
        XCTAssertTrue(policy.shouldTryBackup(after: "openai", failingRepeatedly: true, now: start))
        XCTAssertFalse(policy.shouldTryBackup(after: "openai", failingRepeatedly: true, now: start.addingTimeInterval(29)))
        XCTAssertTrue(policy.shouldTryBackup(after: "openai", failingRepeatedly: true, now: start.addingTimeInterval(30)))
    }

    func testBackupFailingLeavesTheVoiceAlone() {
        var policy = BackupVoicePolicy()
        _ = policy.shouldTryBackup(after: "openai", failingRepeatedly: true, now: start)
        XCTAssertFalse(policy.isActive)
    }

    func testOnceSwitchedItStaysAndCoversLinesAlreadyStarted() {
        var policy = BackupVoicePolicy()
        _ = policy.shouldTryBackup(after: "openai", failingRepeatedly: true, now: start)
        policy.backupAnswered()
        XCTAssertTrue(policy.isActive)
        XCTAssertTrue(policy.shouldTryBackup(after: "openai", failingRepeatedly: false, now: start.addingTimeInterval(1)))
    }

    func testTheBackupHasNoBackup() {
        var policy = BackupVoicePolicy()
        XCTAssertFalse(policy.shouldTryBackup(after: BackupVoicePolicy.backupEngine, failingRepeatedly: true, now: start))
    }

    func testANewSessionGoesBackToTheCoachsVoice() {
        var policy = BackupVoicePolicy()
        policy.backupAnswered()
        policy = BackupVoicePolicy()
        XCTAssertFalse(policy.isActive)
    }
}
