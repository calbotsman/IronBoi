import XCTest

/// 2026-11-05 workout: "I'm increasing the weight" changed nothing, and "35"
/// on a dumbbell lift could mean either hand or both.
final class WeightRequestTests: XCTestCase {
    private func change(_ text: String) -> WeightRequest.Change? { WeightLoad.request(in: text)?.change }

    /// A lift with no weight set yet reads "Set weight", not "bodyweight".
    func testWhichLiftsTakeAWeight() {
        for name in ["Single Arm Row", "Single-arm DB Row", "Goblet Squat", "Lateral Raises", "Overhead Press",
                     "Romanian Deadlift", "Farmer Carry", "KB Swing", "Cable Row"] {
            XCTAssertTrue(WeightLoad.takesWeight(name), name)
        }
        for name in ["Push-ups", "Decline Push-ups", "Inverted Row", "Pull-ups", "Plank", "Bodyweight Squat",
                     "Walking Lunges", "Hanging Leg Raises", "Glute Bridge", "Band Row", "Bench Dips", "Cat-cow"] {
            XCTAssertFalse(WeightLoad.takesWeight(name), name)
        }
    }

    func testExactPhrasesStayOnThePhone() {
        XCTAssertEqual(change("bump it to 40"), .to(40))
        XCTAssertEqual(change("add 5 pounds"), .by(5))
        XCTAssertEqual(change("drop 10 pounds"), .by(-10))
        XCTAssertEqual(change("going up to 45"), .to(45))
        XCTAssertEqual(change("I'm going up to thirty five"), .to(35))
        XCTAssertEqual(change("go up to two twenty five"), .to(225))
        XCTAssertEqual(change("ten more pounds"), .by(10))
        XCTAssertEqual(change("40 pounds"), .to(40))
        XCTAssertEqual(change("20 kilos"), .to(45))
        XCTAssertEqual(change("37.5 lbs"), .to(37.5))
    }

    /// No number: not the phone's call. These go to the coach, whose
    /// set_workout_weight tool asks "up to what?".
    func testLoosePhrasesWithoutANumberGoToTheCoach() {
        XCTAssertNil(WeightLoad.request(in: "I'm increasing the weight"))
        XCTAssertNil(WeightLoad.request(in: "I'm going up"))
        XCTAssertNil(WeightLoad.request(in: "going heavier on this one"))
        XCTAssertNil(WeightLoad.request(in: "this is too light"))
    }

    func testRepsSetsAndTimeAreNotWeight() {
        XCTAssertNil(WeightLoad.request(in: "go to 12 reps"))
        XCTAssertNil(WeightLoad.request(in: "five more"))
        XCTAssertNil(WeightLoad.request(in: "add 2 sets"))
        XCTAssertNil(WeightLoad.request(in: "add 20 minutes on the bike"))
    }

    func testSaysWhichConventionWasMeant() {
        XCTAssertEqual(WeightLoad.request(in: "35 each"), WeightRequest(change: .to(35), stated: .each))
        XCTAssertEqual(WeightLoad.request(in: "make it 35 in each hand"), WeightRequest(change: .to(35), stated: .each))
        XCTAssertEqual(WeightLoad.request(in: "70 total"), WeightRequest(change: .to(70), stated: .total))
        XCTAssertEqual(WeightLoad.request(in: "bump it to 40")?.stated, nil)
    }

    func testLoosePhrasesAreNotClaimedAsOtherWorkoutEdits() {
        let exercises = [
            ActiveWorkoutExercise(exerciseIndex: 0, name: "Dumbbell Shoulder Press", targetSets: 3, targetReps: 10,
                                  targetWeight: 35, completedSets: [], exerciseDone: false, notes: nil),
            ActiveWorkoutExercise(exerciseIndex: 1, name: "Lateral Raises", targetSets: 3, targetReps: 12,
                                  targetWeight: 15, completedSets: [], exerciseDone: false, notes: nil),
        ]
        for text in ["bump it to 40", "add 5 pounds", "I'm increasing the weight", "going heavier on this one",
                     "I'm going up", "add ten pounds"] {
            XCTAssertNil(WorkoutEdit.parse(text, exercises: exercises, current: 0), text)
        }
    }
}

final class LoadBasisTests: XCTestCase {
    func testWhichConventionEachLiftUses() {
        XCTAssertEqual(WeightLoad.basis(for: "Dumbbell Shoulder Press"), .each)
        XCTAssertEqual(WeightLoad.basis(for: "Arnold Press"), .each)
        XCTAssertEqual(WeightLoad.basis(for: "Seated Arnold Press"), .each)
        XCTAssertEqual(WeightLoad.basis(for: "Seated Dumbbell Shoulder Press"), .each)
        XCTAssertEqual(WeightLoad.basis(for: "KB Swing"), .one)
        XCTAssertEqual(WeightLoad.basis(for: "Kettlebell Goblet Squat"), .one)
        XCTAssertEqual(WeightLoad.basis(for: "Single-arm DB Row"), .one)
        XCTAssertEqual(WeightLoad.basis(for: "Barbell Bench Press"), .bar)
        XCTAssertEqual(WeightLoad.basis(for: "Deadlift"), .bar)
        XCTAssertEqual(WeightLoad.basis(for: "Barbell Curl"), .bar)
        XCTAssertEqual(WeightLoad.basis(for: "Bench Press"), .total)
        XCTAssertEqual(WeightLoad.basis(for: "Leg Press"), .total)
    }

    func testLabelsAndSpeech() {
        XCTAssertEqual(WeightLoad.label(35, for: "Dumbbell Shoulder Press"), "35 lb each")
        XCTAssertEqual(WeightLoad.label(35, for: "KB Swing"), "35 lb")
        XCTAssertEqual(WeightLoad.label(135, for: "Barbell Bench Press"), "135 lb total")
        XCTAssertEqual(WeightLoad.label(37.5, for: "Hammer Curls"), "37.5 lb each")
        XCTAssertEqual(WeightLoad.spoken(35, for: "Arnold Press"), "35 pounds each")
        XCTAssertEqual(WeightLoad.spoken(135, for: "Deadlift"), "135 pounds total")
        XCTAssertEqual(WeightLoad.change(from: 35, to: 40, for: "Arnold Press"), "35 → 40 lb each")
        XCTAssertEqual(WeightLoad.change(from: 135, to: 145, for: "Deadlift"), "135 → 145 lb total")
    }

    func testStoresOneConventionAndChecksOnlyWhenItsUnclear() {
        func resolve(_ text: String, current: Double, _ basis: LoadBasis, guess: Bool = true) -> (Double, Bool) {
            let r = WeightLoad.resolve(WeightLoad.request(in: text)!, current: current, basis: basis, guess: guess)
            return (r.pounds, r.check)
        }
        // Two dumbbells at 35 each.
        XCTAssertTrue(resolve("bump it to 40", current: 35, .each) == (40, false))
        XCTAssertTrue(resolve("70 total", current: 35, .each) == (35, false))
        XCTAssertTrue(resolve("make it 70 each", current: 35, .each) == (70, false))
        XCTAssertTrue(resolve("add 10 pounds total", current: 35, .each) == (40, false))
        XCTAssertTrue(resolve("add 5 pounds", current: 35, .each) == (40, false))
        // "80" when holding 35s reads as both together: stored as 40, and asked.
        XCTAssertTrue(resolve("go up to 80", current: 35, .each) == (40, true))
        // The coach's tool says which it means: no guessing.
        XCTAssertTrue(resolve("go up to 80", current: 35, .each, guess: false) == (80, false))
        // A barbell's number is the total, always.
        XCTAssertTrue(resolve("go up to 270", current: 135, .bar) == (270, false))
        XCTAssertTrue(resolve("270 total", current: 135, .bar) == (270, false))
        // Nothing known yet: take it per dumbbell, as said in a gym ("35s").
        XCTAssertTrue(resolve("40 pounds", current: 0, .each) == (40, false))
        XCTAssertTrue(resolve("drop 50 pounds", current: 20, .each) == (0, false))
    }

    func testConfirmationLines() {
        XCTAssertEqual(WeightLoad.confirmation(40, exercise: "Arnold Press", short: "Arnold Press", checked: false),
                       "Arnold Press: 40 pounds each.")
        XCTAssertEqual(WeightLoad.confirmation(40, exercise: "Arnold Press", short: "Arnold Press", checked: true),
                       "Arnold Press: 40 each hand, 80 total. Right?")
        XCTAssertEqual(WeightLoad.confirmation(145, exercise: "Deadlift", short: "Deadlift", checked: false),
                       "Deadlift: 145 pounds total.")
    }
}

final class CoachWorkoutActionTests: XCTestCase {
    func testReadsTheServersActions() {
        let set = CoachWorkoutAction(["type": "set_weight", "exerciseName": "Arnold Press", "toLb": 80, "basis": "total"])
        XCTAssertEqual(set?.request, WeightRequest(change: .to(80), stated: .total))
        let by = CoachWorkoutAction(["type": "set_weight", "exerciseName": "Arnold Press", "byLb": -5])
        XCTAssertEqual(by?.request, WeightRequest(change: .by(-5), stated: nil))
        let ask = CoachWorkoutAction(["type": "ask_weight", "exerciseName": "Arnold Press"])
        XCTAssertEqual(ask?.kind, .askWeight)
        XCTAssertNil(ask?.request)
    }

    func testRejectsMalformedActions() {
        XCTAssertNil(CoachWorkoutAction(["type": "set_weight", "exerciseName": "Arnold Press"]))
        XCTAssertNil(CoachWorkoutAction(["type": "set_weight", "exerciseName": "Arnold Press", "toLb": 40, "byLb": 5]))
        XCTAssertNil(CoachWorkoutAction(["type": "delete_everything", "exerciseName": "Arnold Press"]))
        XCTAssertNil(CoachWorkoutAction(["type": "ask_weight"]))
    }
}

/// "MYO still doesn't recognize sides": one-side-at-a-time lifts are a left
/// and a right per set, and "each side" / "each arm" are understood.
final class SidesTests: XCTestCase {
    private func ex(_ name: String, eachSide: Bool? = nil) -> ActiveWorkoutExercise {
        ActiveWorkoutExercise(exerciseIndex: 0, name: name, targetSets: 3, targetReps: 10, targetWeight: 30,
                              completedSets: [], exerciseDone: false, notes: nil, eachSide: eachSide)
    }

    func testUnilateralComesFromTheExerciseData() {
        XCTAssertTrue(ExerciseKnowledge.isUnilateral("Single-arm DB Row"))
        XCTAssertTrue(ExerciseKnowledge.isUnilateral("Bulgarian Split Squat"))
        XCTAssertTrue(ExerciseKnowledge.isUnilateral("KB Clean & Press"))
        XCTAssertFalse(ExerciseKnowledge.isUnilateral("Dumbbell Shoulder Press"))
        XCTAssertFalse(ExerciseKnowledge.isUnilateral("KB Swing"))
        // Not in the table: by name.
        XCTAssertTrue(ExerciseKnowledge.isUnilateral("Single-arm Kettlebell Press"))
        XCTAssertFalse(ExerciseKnowledge.isUnilateral("Cable Fly"))
        // "10 reps each side" turns it on for a lift in today's workout.
        XCTAssertFalse(WorkoutVoice.isEachSide(ex("Dumbbell Lunges")))
        XCTAssertTrue(WorkoutVoice.isEachSide(ex("Dumbbell Lunges", eachSide: true)))
    }

    func testSidePhrases() {
        XCTAssertEqual(WorkoutVoice.sideSwitch(in: "left side done"), .init(finished: .left))
        XCTAssertEqual(WorkoutVoice.sideSwitch(in: "okay left arm is done"), .init(finished: .left))
        XCTAssertEqual(WorkoutVoice.sideSwitch(in: "done with the right"), .init(finished: .right))
        XCTAssertEqual(WorkoutVoice.sideSwitch(in: "right side now"), .init(finished: .left))
        XCTAssertEqual(WorkoutVoice.sideSwitch(in: "switching to the left"), .init(finished: .right))
        XCTAssertEqual(WorkoutVoice.sideSwitch(in: "switching sides"), .init(finished: nil))
        XCTAssertEqual(WorkoutVoice.sideSwitch(in: "other side"), .init(finished: nil))
        XCTAssertNil(WorkoutVoice.sideSwitch(in: "set done"))
        XCTAssertNil(WorkoutVoice.sideSwitch(in: "eight nine ten"))
        XCTAssertNil(WorkoutVoice.sideSwitch(in: "what's on the right of the bench"))
    }

    func testEachSideRepsAndEachArmWeight() {
        let exercises = [ex("Dumbbell Lunges")]
        XCTAssertEqual(WorkoutEdit.parse("10 reps each side", exercises: exercises, current: 0),
                       .targets(0, sets: nil, reps: 10, eachSide: true))
        XCTAssertEqual(WorkoutEdit.parse("do 3 sets of 8 per leg", exercises: exercises, current: 0),
                       .targets(0, sets: 3, reps: 8, eachSide: true))
        XCTAssertEqual(WorkoutEdit.parse("make it 12 reps", exercises: exercises, current: 0),
                       .targets(0, sets: nil, reps: 12, eachSide: false))
        // "10 lb each arm" is the weight, per hand — not reps.
        XCTAssertNil(WorkoutEdit.parse("10 lb each arm", exercises: exercises, current: 0))
        XCTAssertEqual(WeightLoad.request(in: "10 lb each arm"), WeightRequest(change: .to(10), stated: .each))
        XCTAssertNil(WeightLoad.request(in: "10 reps each side"))
        let r = WeightLoad.resolve(WeightLoad.request(in: "10 lb each arm")!, current: 30, basis: .each)
        XCTAssertEqual(r, WeightResolution(pounds: 10))
        XCTAssertEqual(WeightLoad.label(10, for: "Dumbbell Lunges"), "10 lb each")
    }
}

/// Watchdog F36–F38 (docs/audit/findings.md): phrasing the first pass missed.
final class WeightPhrasingTests: XCTestCase {
    private func resolve(_ text: String, current: Double, _ basis: LoadBasis) -> WeightResolution? {
        WeightLoad.request(in: text).map { WeightLoad.resolve($0, current: current, basis: basis) }
    }

    /// F36: bells by their number, plural.
    func testPluralBellNumbers() {
        XCTAssertEqual(WeightLoad.request(in: "go up to 50s")?.change, .to(50))
        XCTAssertEqual(WeightLoad.request(in: "grab the 40s")?.change, .to(40))
        XCTAssertEqual(WeightLoad.request(in: "I'm using the 25s")?.change, .to(25))
        XCTAssertEqual(resolve("go up to 50s", current: 35, .each), WeightResolution(pounds: 50))
        XCTAssertNil(WeightLoad.request(in: "hold for 30s"))
        XCTAssertNil(WeightLoad.request(in: "do the 10 lunges"))
    }

    /// F37: the "is that a total?" guess follows the direction you said.
    func testGuessFollowsDirection() {
        XCTAssertEqual(resolve("go up to 50", current: 35, .each), WeightResolution(pounds: 50))
        XCTAssertEqual(resolve("go up to 60", current: 35, .each), WeightResolution(pounds: 60))
        XCTAssertEqual(resolve("go up to 80", current: 35, .each), WeightResolution(pounds: 40, check: true))
        XCTAssertEqual(resolve("80 pounds", current: 35, .each), WeightResolution(pounds: 40, check: true))
        XCTAssertEqual(resolve("drop to 70", current: 35, .each), WeightResolution(pounds: 70))
        XCTAssertEqual(resolve("40 pounds", current: 35, .each), WeightResolution(pounds: 40))
    }

    /// F38: plates per side on a bar.
    func testPlatesPerSide() {
        XCTAssertEqual(WeightLoad.request(in: "25s on each side")?.perSide, true)
        XCTAssertEqual(resolve("25s on each side", current: 135, .bar), WeightResolution(pounds: 95, platesPerSide: 25))
        XCTAssertEqual(resolve("45 pounds a side", current: 95, .bar), WeightResolution(pounds: 135, platesPerSide: 45))
        XCTAssertEqual(resolve("add 10 pounds a side", current: 135, .bar), WeightResolution(pounds: 155))
        // A machine: no bar to add, so checked.
        XCTAssertEqual(resolve("45 pounds a side", current: 90, .total), WeightResolution(pounds: 90, check: true))
        // On two dumbbells "each side" is per hand.
        XCTAssertEqual(resolve("30 pounds each side", current: 25, .each), WeightResolution(pounds: 30))
        // No weight word: "10 each side" is reps on a one-sided lift.
        XCTAssertNil(WeightLoad.request(in: "10 each side"))
        XCTAssertEqual(WeightLoad.confirmation(WeightResolution(pounds: 95, platesPerSide: 25), exercise: "Deadlift", short: "Deadlift"),
                       "Deadlift: 25 a side on a 45 bar, 95 pounds total.")
    }
}

final class SideLoggingTests: XCTestCase {
    func testBothSidesFromTwoCounts() {
        XCTAssertTrue(WorkoutVoice.sides(first: 10, second: 9, firstName: nil) == (10, 9, 9))
        XCTAssertTrue(WorkoutVoice.sides(first: 10, second: 9, firstName: .right) == (9, 10, 9))
        // Second side never really counted: the first side alone.
        XCTAssertTrue(WorkoutVoice.sides(first: 10, second: 1, firstName: nil) == (10, nil, 10))
        XCTAssertTrue(WorkoutVoice.sides(first: 10, second: 0, firstName: .right) == (nil, 10, 10))
    }

    func testSidesSaidInsteadOfCounted() {
        XCTAssertTrue(WorkoutVoice.sideReps(in: "10 left 9 right")! == (10, 9))
        XCTAssertTrue(WorkoutVoice.sideReps(in: "nine on the right and ten on the left")! == (10, 9))
        XCTAssertTrue(WorkoutVoice.sideReps(in: "left 8, right 10")! == (8, 10))
        XCTAssertTrue(WorkoutVoice.sideReps(in: "set done, 10 each side")! == (10, 10))
        XCTAssertNil(WorkoutVoice.sideReps(in: "switch to the left"))
        XCTAssertNil(WorkoutVoice.sideReps(in: "set done"))
    }
}

/// Per-side counting on #46's SetCount: a said side switch, both sides logged.
final class SetCountSidesTests: XCTestCase {
    private func count(_ c: inout SetCount, to n: Int) {
        let start = Date()
        for i in 1...n { _ = c.advance(to: i, at: start.addingTimeInterval(Double(i) * 2)) }
    }

    func testSaidSideSwitchesMidCount() {
        var c = SetCount(exercise: 0, target: 10, eachSide: true)
        count(&c, to: 7)
        XCTAssertTrue(c.switchSides(finished: .right))   // "right side done" at 7
        XCTAssertEqual(c.firstSide, 7)
        XCTAssertEqual(c.count, 0)
        XCTAssertEqual(c.currentSide, .left)
        count(&c, to: 8)
        XCTAssertEqual(c.repsToLog, 7)
        XCTAssertTrue(c.sidesToLog! == (8, 7))
    }

    func testSwitchAtTargetThenNamingTheSide() {
        var c = SetCount(exercise: 0, target: 10, eachSide: true)
        count(&c, to: 10)                                  // switches itself at the target
        XCTAssertEqual(c.firstSide, 10)
        XCTAssertFalse(c.switchSides(finished: .left))     // "right side now": names the first side
        XCTAssertEqual(c.firstSideName, .left)
        count(&c, to: 9)
        XCTAssertTrue(c.sidesToLog! == (10, 9))
        XCTAssertEqual(c.repsToLog, 9)
    }

    func testOnlyOneSideCountedLogsThatSide() {
        var c = SetCount(exercise: 0, target: 10, eachSide: true)
        count(&c, to: 10)
        XCTAssertTrue(c.sidesToLog! == (10, nil))
        XCTAssertEqual(c.repsToLog, 10)
    }

    func testNotForTwoSidedLifts() {
        var c = SetCount(exercise: 0, target: 10, eachSide: false)
        count(&c, to: 5)
        XCTAssertFalse(c.switchSides(finished: nil))
        XCTAssertNil(c.sidesToLog)
        XCTAssertNil(c.currentSide)
    }
}
