import XCTest

/// Recovery baselines (28-day median, needs 10 days) and the "clearly low"
/// rule (two of: resting HR ≥ +7 bpm, HRV ≤ 80 %, sleep < 6 h). Rationale
/// is in RecoveryBaseline.swift; these pin the behavior, not anyone's data.
final class RecoveryBaselineTests: XCTestCase {
    typealias R = RecoveryBaseline

    /// `count` past days (daysAgo 1...count) at `value`, plus today.
    private func days(_ value: Double, count: Int = 28, today: Double?) -> [R.Daily] {
        (1...count).map { R.Daily(daysAgo: $0, value: value) } + (today.map { [R.Daily(daysAgo: 0, value: $0)] } ?? [])
    }

    func testMedianIsRobustToOneOutlier() {
        XCTAssertEqual(R.median([50, 52, 51, 200]), 51.5)
        XCTAssertEqual(R.median([3, 1, 2]), 2)
        XCTAssertNil(R.median([]))
    }

    func testBaselineIgnoresTodayAndDaysOutsideTheWindow() {
        let input = days(55, today: 90) + [R.Daily(daysAgo: 29, value: 200), R.Daily(daysAgo: 40, value: 200)]
        let split = R.split(input)
        XCTAssertEqual(split.today, 90)
        XCTAssertEqual(split.baseline, 55)
    }

    func testNoBaselineWithTooFewDays() {
        XCTAssertNil(R.split(days(55, count: R.minBaselineDays - 1, today: 70)).baseline)
        XCTAssertEqual(R.split(days(55, count: R.minBaselineDays, today: 70)).baseline, 55)
    }

    func testBadValuesAreDropped() {
        let input = days(55, today: nil) + [R.Daily(daysAgo: 0, value: .nan)]
        XCTAssertNil(R.split(input).today)
    }

    func testRestingHrFlagsAtSevenAbove() {
        XCTAssertEqual(R.summarize(restingHr: days(55, today: 62), hrv: [], sleepHours: nil).signals, [.restingHrHigh])
        XCTAssertEqual(R.summarize(restingHr: days(55, today: 61.9), hrv: [], sleepHours: nil).signals, [])
    }

    func testHrvFlagsAtTwentyPercentBelow() {
        XCTAssertEqual(R.summarize(restingHr: [], hrv: days(50, today: 40), sleepHours: nil).signals, [.hrvLow])
        XCTAssertEqual(R.summarize(restingHr: [], hrv: days(50, today: 40.5), sleepHours: nil).signals, [])
        // High HRV is never a flag.
        XCTAssertEqual(R.summarize(restingHr: [], hrv: days(50, today: 90), sleepHours: nil).signals, [])
    }

    func testSleepFlagsUnderSixHours() {
        XCTAssertEqual(R.summarize(restingHr: [], hrv: [], sleepHours: 5.9).signals, [.sleepShort])
        XCTAssertEqual(R.summarize(restingHr: [], hrv: [], sleepHours: 6).signals, [])
    }

    func testOneSignalIsNotLowTwoIs() {
        XCTAssertFalse(R.summarize(restingHr: [], hrv: [], sleepHours: 3).isLow)
        let two = R.summarize(restingHr: [], hrv: days(50, today: 35), sleepHours: 5)
        XCTAssertEqual(two.signals, [.hrvLow, .sleepShort])
        XCTAssertTrue(two.isLow)
    }

    func testWithoutBaselineHrAndHrvCannotFlag() {
        let summary = R.summarize(restingHr: [R.Daily(daysAgo: 0, value: 80)], hrv: [R.Daily(daysAgo: 0, value: 10)], sleepHours: 7)
        XCTAssertEqual(summary.signals, [])
        XCTAssertEqual(summary.restingHr, 80)
        XCTAssertNil(summary.restingHrBaseline)
    }

    func testSleepMergesOverlappingSourcesAndClipsToWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = DateInterval(start: now.addingTimeInterval(-86_400), end: now)
        let h = 3600.0
        let night = [
            // Watch: 23:00–05:00; Oura: 00:00–06:00 (overlaps) → 7 h total.
            DateInterval(start: now.addingTimeInterval(-9 * h), end: now.addingTimeInterval(-3 * h)),
            DateInterval(start: now.addingTimeInterval(-8 * h), end: now.addingTimeInterval(-2 * h)),
            // Started before the window: only the last hour counts.
            DateInterval(start: now.addingTimeInterval(-25 * h), end: now.addingTimeInterval(-23 * h)),
        ]
        XCTAssertEqual(R.sleepHours(asleep: night, in: window)!, 8, accuracy: 0.001)
        XCTAssertNil(R.sleepHours(asleep: [], in: window))
    }

    func testPayloadMatchesServerContract() {
        let low = R.summarize(restingHr: days(55, today: 63), hrv: days(48, today: 31), sleepHours: 5.43)
        let payload = R.payload(low, offerLighter: true)!
        XCTAssertEqual(payload["restingHr"] as? Int, 63)
        XCTAssertEqual(payload["restingHrBaseline"] as? Int, 55)
        XCTAssertEqual(payload["hrvMs"] as? Int, 31)
        XCTAssertEqual(payload["hrvBaselineMs"] as? Int, 48)
        XCTAssertEqual(payload["sleepHours"] as? Double, 5.4)
        XCTAssertEqual(payload["signals"] as? [String], ["resting_hr_high", "hrv_low", "sleep_short"])
        XCTAssertEqual(payload["low"] as? Bool, true)
        XCTAssertEqual(payload["offerLighter"] as? Bool, true)
        // Not low: no offer key at all. No data: no payload.
        XCTAssertNil(R.payload(R.summarize(restingHr: [], hrv: [], sleepHours: 7), offerLighter: true)?["offerLighter"])
        XCTAssertNil(R.payload(R.summarize(restingHr: [], hrv: [], sleepHours: nil), offerLighter: true))
    }

    func testOfferIsOnceADayAndOnlyBeforeTheFirstSet() {
        let low = R.summarize(restingHr: [], hrv: days(50, today: 30), sleepHours: 4)
        let fine = R.summarize(restingHr: [], hrv: [], sleepHours: 8)
        XCTAssertTrue(R.mayOfferLighter(summary: low, offeredOn: nil, today: "2026-11-05", setsDone: nil))
        XCTAssertTrue(R.mayOfferLighter(summary: low, offeredOn: "2026-11-04", today: "2026-11-05", setsDone: 0))
        XCTAssertFalse(R.mayOfferLighter(summary: low, offeredOn: "2026-11-05", today: "2026-11-05", setsDone: nil))
        XCTAssertFalse(R.mayOfferLighter(summary: low, offeredOn: nil, today: "2026-11-05", setsDone: 2))
        XCTAssertFalse(R.mayOfferLighter(summary: fine, offeredOn: nil, today: "2026-11-05", setsDone: nil))
        XCTAssertFalse(R.mayOfferLighter(summary: nil, offeredOn: nil, today: "2026-11-05", setsDone: nil))
    }

    func testOfferCountsOnlyWhenTheReplySaysIt() {
        XCTAssertTrue(R.mentionsLighterOffer("Recovery's low today, want a lighter version?"))
        XCTAssertTrue(R.mentionsLighterOffer("Want to keep it easier today?"))
        XCTAssertFalse(R.mentionsLighterOffer("Nice. First up, goblet squats, 3 sets of 10."))
    }
}
