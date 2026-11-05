import Foundation

/// One set being counted out loud, from the first number to the set being
/// logged. Reaching the target is only a moment in the set: the count keeps
/// going for as long as you keep lifting, and the set is logged once, when
/// it ends — "done", a tap, or a quiet stretch long enough for your pace.
///
/// (It used to be logged the instant you hit the target. On the last set
/// that finished the exercise, so "Next up…" started over your extra reps.)
struct SetCount: Equatable {
    /// The exercise this count is for, pinned at the first number.
    let exercise: Int
    let target: Int
    /// Counted to the target on each side in turn.
    let eachSide: Bool

    private(set) var count = 0
    /// An each-side lift: the first side's reps, while the other is counted.
    private(set) var firstSide: Int?
    /// Which side that was, if they said ("left side done"); nil = taken
    /// as the left.
    private(set) var firstSideName: WorkoutVoice.Side?
    /// The slowest you've gone between two numbers this set (per rep, when
    /// the recogniser dropped a word and the count jumped).
    private(set) var slowestRep: TimeInterval = 0
    /// When the last number was heard: the set ended there, so rest
    /// counts from it, not from when the quiet stretch ran out.
    private(set) var lastRepAt: Date?

    init(exercise: Int, target: Int, eachSide: Bool) {
        self.exercise = exercise
        self.target = max(1, target)
        self.eachSide = eachSide
    }

    enum Step: Equatable {
        /// Not a new number (a repeat, or behind the count).
        case ignored
        /// One more rep, short of or past the target.
        case rep
        /// Just reached the target. The set isn't over: keep counting.
        case reachedTarget
        /// An each-side lift reached the target on the first side: the
        /// other side counts from one.
        case switchSides
    }

    var pastTarget: Bool { count >= target }

    /// The count moved to `heard` at `time`.
    mutating func advance(to heard: Int, at time: Date) -> Step {
        guard heard > count else { return .ignored }
        if let last = lastRepAt {
            let perRep = time.timeIntervalSince(last) / Double(heard - count)
            slowestRep = max(slowestRep, perRep)
        }
        lastRepAt = time
        let wasShort = count < target
        count = heard
        guard wasShort, count >= target else { return .rep }
        if eachSide, firstSide == nil {
            firstSide = count
            count = 0
            lastRepAt = nil
            return .switchSides
        }
        return .reachedTarget
    }

    /// They said a side is done ("left side done", "switching sides",
    /// "right side now"): the other side counts from one, whatever the
    /// count. False if this isn't a side switch (not each-side, nothing
    /// counted yet, or already on the second side — then it only notes
    /// which side the first was, if that wasn't known).
    mutating func switchSides(finished: WorkoutVoice.Side?) -> Bool {
        guard eachSide else { return false }
        guard firstSide == nil, count > 0 else {
            if firstSide != nil, firstSideName == nil { firstSideName = finished }
            return false
        }
        firstSide = count
        firstSideName = finished
        count = 0
        lastRepAt = nil
        return true
    }

    /// The side being counted now.
    var currentSide: WorkoutVoice.Side? {
        guard eachSide else { return nil }
        let first = firstSideName ?? .left
        return firstSide == nil ? first : first.other
    }

    // MARK: - When the set is over

    /// Short of the target, a pause is usually a breath mid-set.
    static let quietShortOfTarget: TimeInterval = 12
    /// At or past it, a pause usually means the bar's racked — but a hard
    /// last rep can take several seconds, so not so short it cuts that off.
    static let quietPastTarget: TimeInterval = 6
    /// Waiting for the other side of an each-side lift to start.
    static let quietBetweenSides: TimeInterval = 30
    /// A pause this many times your slowest rep is a stop, not a grind.
    static let paceAllowance = 2.0
    /// However slow the reps, this much quiet ends the set.
    static let longestQuiet: TimeInterval = 20

    /// Quiet for longer than your slowest rep (by this much) means you've
    /// stopped repping, at least for now.
    static let stoppedAllowance = 1.5
    /// Never sooner than this: a normal rep takes a second or two.
    static let stoppedFloor: TimeInterval = 3

    /// How long after the last number you've stopped repping. The coach's
    /// ears reopen here — talking to it right after racking is heard —
    /// while the set stays open a while longer in case of one more rep.
    var repsStoppedAfter: TimeInterval {
        min(quietWindow, max(Self.stoppedFloor, slowestRep * Self.stoppedAllowance))
    }

    /// How long the mic must stay quiet before the set is over, from the
    /// last number heard. Scales with your own pace this set: grinding reps
    /// at the end of a set get the time they take.
    var quietWindow: TimeInterval {
        if firstSide != nil, count == 0 { return Self.quietBetweenSides }
        let floor = pastTarget ? Self.quietPastTarget : Self.quietShortOfTarget
        return min(Self.longestQuiet, max(floor, slowestRep * Self.paceAllowance))
    }

    // MARK: - What gets logged

    /// Fewer than this short of the target is a stray "one, two", not a set.
    static let fewestToLog = 3

    /// The reps to log for this set — fewer, exactly, or more than the
    /// target — or nil if it never became a set. An each-side lift logs the
    /// weaker side, or the first side alone if the other wasn't counted.
    var repsToLog: Int? {
        let reps: Int
        if let side = firstSide {
            reps = count >= Self.fewestToLog ? min(side, count) : side
        } else {
            reps = count
        }
        return reps >= min(Self.fewestToLog, target) ? reps : nil
    }

    /// An each-side lift's two sides for the log (`repsToLog` is the
    /// fewer); one side only if the other wasn't counted. Nil otherwise.
    var sidesToLog: (left: Int?, right: Int?)? {
        guard let side = firstSide else { return nil }
        let both = WorkoutVoice.sides(first: side, second: count, firstName: firstSideName)
        return (both.left, both.right)
    }
}
