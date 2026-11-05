import XCTest

final class SetCountTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    /// Counts 1…`to` with `gap` seconds between numbers.
    private func counted(_ set: inout SetCount, to last: Int, gap: TimeInterval, from first: Int = 1,
                         startingAt t0: TimeInterval = 0) -> [SetCount.Step] {
        (first...last).enumerated().map { i, n in
            set.advance(to: n, at: start.addingTimeInterval(t0 + Double(i) * gap))
        }
    }

    func testReachingTargetDoesNotEndTheSet() {
        var set = SetCount(exercise: 0, target: 10, eachSide: false)
        let steps = counted(&set, to: 10, gap: 2)
        XCTAssertEqual(steps.last, .reachedTarget)
        XCTAssertEqual(steps.dropLast().filter { $0 != .rep }, [])
        // Counting on is just more reps.
        XCTAssertEqual(set.advance(to: 11, at: start.addingTimeInterval(22)), .rep)
        XCTAssertEqual(set.count, 11)
    }

    func testRepsPastTargetAreAllLogged() {
        var set = SetCount(exercise: 0, target: 10, eachSide: false)
        _ = counted(&set, to: 13, gap: 2)
        XCTAssertEqual(set.repsToLog, 13)
    }

    func testFastConsecutiveNumbersAllCount() {
        var set = SetCount(exercise: 0, target: 10, eachSide: false)
        _ = counted(&set, to: 10, gap: 2)
        // "eleven, twelve, thirteen" in one breath, each its own update.
        XCTAssertEqual(set.advance(to: 11, at: start.addingTimeInterval(18.3)), .rep)
        XCTAssertEqual(set.advance(to: 12, at: start.addingTimeInterval(18.6)), .rep)
        XCTAssertEqual(set.advance(to: 13, at: start.addingTimeInterval(18.9)), .rep)
        XCTAssertEqual(set.repsToLog, 13)
    }

    func testRepeatsAndStaleNumbersAreIgnored() {
        var set = SetCount(exercise: 0, target: 10, eachSide: false)
        _ = counted(&set, to: 5, gap: 2)
        XCTAssertEqual(set.advance(to: 5, at: start.addingTimeInterval(9)), .ignored)
        XCTAssertEqual(set.advance(to: 3, at: start.addingTimeInterval(9)), .ignored)
        XCTAssertEqual(set.count, 5)
    }

    func testQuietWindowIsLongerShortOfTarget() {
        var set = SetCount(exercise: 0, target: 10, eachSide: false)
        _ = counted(&set, to: 5, gap: 1)
        XCTAssertEqual(set.quietWindow, SetCount.quietShortOfTarget)
        _ = counted(&set, to: 10, gap: 1, from: 6, startingAt: 5)
        XCTAssertEqual(set.quietWindow, SetCount.quietPastTarget)
        XCTAssertLessThan(SetCount.quietPastTarget, SetCount.quietShortOfTarget)
    }

    func testGrindingRepsPastTargetGetMoreTime() {
        var set = SetCount(exercise: 0, target: 10, eachSide: false)
        _ = counted(&set, to: 10, gap: 2)
        let brisk = set.quietWindow
        // A grinding rep, slower than the past-target floor allows for.
        let grind = SetCount.quietPastTarget
        _ = set.advance(to: 11, at: start.addingTimeInterval(18 + grind))
        XCTAssertEqual(set.quietWindow, min(SetCount.longestQuiet, grind * SetCount.paceAllowance))
        XCTAssertGreaterThan(set.quietWindow, brisk)
        // The next grind fits inside the window the last one opened.
        XCTAssertGreaterThan(set.quietWindow, grind)
    }

    func testQuietWindowIsCapped() {
        var set = SetCount(exercise: 0, target: 10, eachSide: false)
        _ = set.advance(to: 1, at: start)
        _ = set.advance(to: 2, at: start.addingTimeInterval(SetCount.longestQuiet * 2))
        XCTAssertEqual(set.quietWindow, SetCount.longestQuiet)
    }

    func testDroppedWordSpreadsTheGapOverTheRepsItCovers() {
        var set = SetCount(exercise: 0, target: 10, eachSide: false)
        _ = set.advance(to: 4, at: start)
        // "…four, [five lost], six" two reps in four seconds is 2 s a rep.
        _ = set.advance(to: 6, at: start.addingTimeInterval(4))
        XCTAssertEqual(set.slowestRep, 2, accuracy: 0.001)
    }

    func testStrayNumbersAreNotASet() {
        var set = SetCount(exercise: 0, target: 10, eachSide: false)
        _ = counted(&set, to: 2, gap: 1)
        XCTAssertNil(set.repsToLog)
        _ = set.advance(to: SetCount.fewestToLog, at: start.addingTimeInterval(3))
        XCTAssertEqual(set.repsToLog, SetCount.fewestToLog)
    }

    func testSmallTargetLogsAtTarget() {
        var set = SetCount(exercise: 0, target: 2, eachSide: false)
        _ = counted(&set, to: 2, gap: 3)
        XCTAssertEqual(set.repsToLog, 2)
    }

    func testEachSideSwitchesAtTargetAndLogsTheWeakerSide() {
        var set = SetCount(exercise: 0, target: 8, eachSide: true)
        XCTAssertEqual(counted(&set, to: 8, gap: 2).last, .switchSides)
        XCTAssertEqual(set.firstSide, 8)
        XCTAssertEqual(set.count, 0)
        XCTAssertEqual(set.quietWindow, SetCount.quietBetweenSides)
        // The other side reaching the target doesn't switch again.
        XCTAssertEqual(counted(&set, to: 8, gap: 2, startingAt: 30).last, .reachedTarget)
        _ = set.advance(to: 9, at: start.addingTimeInterval(50))
        XCTAssertEqual(set.repsToLog, 8)
    }

    func testEachSideWithNoSecondSideLogsTheFirst() {
        var set = SetCount(exercise: 0, target: 8, eachSide: true)
        _ = counted(&set, to: 8, gap: 2)
        XCTAssertEqual(set.repsToLog, 8)
        // A stray "one" on the other side doesn't drag it down.
        _ = set.advance(to: 1, at: start.addingTimeInterval(40))
        XCTAssertEqual(set.repsToLog, 8)
    }

    func testMicReopensOnceRepsStopWhileSetStaysOpen() {
        var set = SetCount(exercise: 0, target: 10, eachSide: false)
        _ = counted(&set, to: 11, gap: 1)
        XCTAssertEqual(set.repsStoppedAfter, SetCount.stoppedFloor)
        XCTAssertLessThan(set.repsStoppedAfter, set.quietWindow)
        XCTAssertEqual(set.lastRepAt, start.addingTimeInterval(10))
    }

    func testMicReopensLaterForSlowReps() {
        var set = SetCount(exercise: 0, target: 10, eachSide: false)
        _ = counted(&set, to: 10, gap: 4)
        XCTAssertEqual(set.repsStoppedAfter, 4 * SetCount.stoppedAllowance, accuracy: 0.001)
        XCTAssertLessThanOrEqual(set.repsStoppedAfter, set.quietWindow)
    }

    func testMicNeverReopensAfterTheSetCloses() {
        var set = SetCount(exercise: 0, target: 10, eachSide: false)
        _ = set.advance(to: 1, at: start)
        _ = set.advance(to: 2, at: start.addingTimeInterval(SetCount.longestQuiet))
        XCTAssertEqual(set.repsStoppedAfter, set.quietWindow)
    }
}
