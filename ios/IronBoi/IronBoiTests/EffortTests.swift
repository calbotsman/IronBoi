import XCTest

final class EffortTests: XCTestCase {
    func testEaseCoversNinetyFivePercentInTenSeconds() {
        let v = EffortSignal.eased(from: 0, to: 1, elapsed: 10)
        XCTAssertEqual(v, 0.95, accuracy: 0.01)
        XCTAssertEqual(EffortSignal.eased(from: 0, to: 1, elapsed: 0), 0)
    }

    func testRetargetingNeverJumps() {
        let signal = EffortSignal()
        signal.reset(to: 0)
        signal.aim(at: 1, now: 100)
        let before = signal.current(now: 103)
        signal.aim(at: 0, now: 103)
        XCTAssertEqual(signal.current(now: 103), before, accuracy: 0.0001)
    }

    func testHeartShareMapsCalmToPumped() {
        // Age 32: max 185.6.
        let max = 208 - 0.7 * 32.0
        XCTAssertEqual(EffortTarget.fromHeart(bpm: 95, maxHR: max), 0)
        XCTAssertEqual(EffortTarget.fromHeart(bpm: 175, maxHR: max), 1)
        XCTAssertEqual(EffortTarget.fromHeart(bpm: Int(max * 0.725), maxHR: max), 0.5, accuracy: 0.03)
    }

    func testStateFallbackOrder() {
        XCTAssertLessThan(EffortTarget.fromState(.resting), EffortTarget.fromState(.warmingUp))
        XCTAssertLessThan(EffortTarget.fromState(.warmingUp), EffortTarget.fromState(.working))
    }

    func testRecoveryNeedsAnElevatedStartAndTime() {
        let max = 185.0
        // Back under 65% after starting above 70%, 30 s in: recovered.
        XCTAssertTrue(Recovery.isRecovered(bpm: 118, restStartBpm: 160, maxHR: max, restElapsed: 30))
        // Too early.
        XCTAssertFalse(Recovery.isRecovered(bpm: 118, restStartBpm: 160, maxHR: max, restElapsed: 10))
        // Never got going: nothing to recover from.
        XCTAssertFalse(Recovery.isRecovered(bpm: 100, restStartBpm: 120, maxHR: max, restElapsed: 30))
        // Still up.
        XCTAssertFalse(Recovery.isRecovered(bpm: 140, restStartBpm: 160, maxHR: max, restElapsed: 60))
    }

    func testCaloriesOnlyFromHeartRate() {
        XCTAssertNil(CalorieEstimate.perMinute(bpm: nil, weightKg: 82, ageYears: 32, sex: .male))
        XCTAssertNil(CalorieEstimate.perMinute(bpm: 140, weightKg: nil, ageYears: 32, sex: .male))
        XCTAssertNil(CalorieEstimate.perMinute(bpm: 140, weightKg: 82, ageYears: nil, sex: .male))
        // Keytel, male, 140 bpm, 82 kg, 32 y: (−55.0969 + 88.326 + 16.302 + 6.454) / 4.184 ≈ 13.38 kcal/min.
        let male = CalorieEstimate.perMinute(bpm: 140, weightKg: 82, ageYears: 32, sex: .male) ?? 0
        XCTAssertEqual(male, 13.38, accuracy: 0.01)
        // Near resting HR the formula goes negative; floored at ~1.3 MET.
        let floor = CalorieEstimate.perMinute(bpm: 60, weightKg: 82, ageYears: 32, sex: .female) ?? 0
        XCTAssertEqual(floor, 1.3 * 3.5 * 82 / 200, accuracy: 0.001)
    }
}
