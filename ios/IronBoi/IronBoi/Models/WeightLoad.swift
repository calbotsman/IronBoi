import Foundation

/// How a lift's weight is counted, so "35" is never a guess.
///
/// One convention everywhere (card, set log, recap, Record tab, the coach):
/// the number stored is what's on ONE dumbbell or kettlebell, or the whole
/// load for a barbell, machine or anything else. That is what the plans
/// already hold (a "moderate" dumbbell lift starts at 20 lb, a barbell at
/// 45+), so nothing stored changes meaning; it just gets said plainly.
/// Server mirror: functions/src/workouts/loadBasis.ts (a test keeps the
/// patterns and the catalog table in step).
enum LoadBasis: String, Equatable {
    /// Two dumbbells or kettlebells; the number is one of them: "35 lb each".
    case each
    /// One dumbbell or kettlebell (goblet squat, swing, single-arm row): "35 lb".
    case one
    /// A barbell: the total, bar included. "25s a side" is plate maths.
    case bar
    /// A machine, cable or added load: "135 lb total".
    case total
}

/// What you said about a weight, before it's matched to the lift.
struct WeightRequest: Equatable {
    enum Change: Equatable {
        case to(Double)
        case by(Double)
    }
    /// What the number means, if you said ("35 each", "70 total").
    enum Stated: String, Equatable {
        case each
        case total
    }
    let change: Change
    let stated: Stated?
    /// +1 "up/heavier", -1 "down/lighter", 0 neither.
    var direction: Int = 0
    /// "25s on each side", "a plate a side": plates on each end of a bar.
    var perSide: Bool = false
}

/// What a weight request became for a lift.
struct WeightResolution: Equatable {
    let pounds: Double
    /// Read as something other than said; say it back as a question.
    var check: Bool = false
    /// Plates per side on a bar, when that's how it was said.
    var platesPerSide: Double? = nil
}

enum WeightLoad {
    // MARK: - Which convention a lift uses

    /// Words in a lift's name that mean dumbbells or kettlebells.
    static let implementPattern = #"\b(dumbbells?|dbs?|kettlebells?|kbs?)\b"#
    /// Lifts done with a single bell or object.
    static let singleImplementPattern = #"\b(single|one)[- ]?(arm|hand|leg)\b|\b(goblet|swings?|halo|suitcase|clean (&|and) press|tricep extension)\b"#
    /// Things there's only ever one of: a club, a sandbag, a med ball.
    static let oneObjectPattern = #"\b(clubs?|sandbag|med ?ball)\b"#
    /// A bar in the name: "Barbell Curl", "EZ Bar Curl", "Trap Bar Deadlift".
    static let barPattern = #"\b(barbell|ez[- ]?bar|trap bar|bb)\b"#
    /// What "25s a side" sits on: a standard Olympic bar.
    static let barPounds: Double = 45

    /// Catalog lifts that aren't a plain total (bells, bars), by the catalog's
    /// equipment (Arnold Press has no "dumbbell" in its name). Generated from
    /// functions/src/workouts/loadBasis.ts; exerciseCatalog.test.ts fails if
    /// the two disagree.
    static let catalogBasis: [String: LoadBasis] = [
        "Arnold Press": .each,
        "Barbell Back Squat": .bar,
        "Barbell Bench Press": .bar,
        "Bent-over Barbell Row": .bar,
        "Deadlift": .bar,
        "Dumbbell Bench Press": .each,
        "Dumbbell Floor Press": .each,
        "Dumbbell Goblet Squat": .one,
        "Dumbbell Romanian Deadlift": .each,
        "Dumbbell Shoulder Press": .each,
        "EZ Bar Curl": .bar,
        "Farmer Carry": .each,
        "Good Morning": .bar,
        "Hammer Curls": .each,
        "Heavy Club Mill": .one,
        "Heavy Club Shield Cast": .one,
        "Hip Thrust": .bar,
        "Incline Dumbbell Curl": .each,
        "Incline Dumbbell Press": .each,
        "KB Clean & Press": .one,
        "KB Curl": .each,
        "KB Goblet Squat": .one,
        "KB Halo": .one,
        "KB Single-arm Row": .one,
        "KB Swing": .one,
        "Lateral Raises": .each,
        "Med Ball Slam": .one,
        "Overhead Press": .bar,
        "Overhead Tricep Extension": .one,
        "Romanian Deadlift": .bar,
        "Sandbag Carry": .one,
        "Sandbag Clean & Squat": .one,
        "Single-arm DB Row": .one,
        "Skull Crushers": .bar,
        "Suitcase Carry": .one,
    ]

    /// A lift that's done with a weight, even when the plan doesn't have
    /// one yet (0 means "not set" as well as "bodyweight": a swap across
    /// load classes, or a lift you've no history on). "Single Arm Row" at 0
    /// read "bodyweight" and hid the weight control; it needs "Set weight".
    static func takesWeight(_ exerciseName: String) -> Bool {
        if catalogBasis[exerciseName] != nil { return true }
        let lower = exerciseName.lowercased()
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        if has(implementPattern) || has(oneObjectPattern) || has(barPattern)
            || has(#"\b(weighted|cable|machine|plate|landmine|sled)\b"#) { return true }
        let bodyweight = #"\b(push[- ]?ups?|pull[- ]?ups?|chin[- ]?ups?|inverted|bodyweight|body weight|air squats?|band|plank|dips?|pike|bridges?|jumps?|jumping|burpees?|leg raises?|calf raises?|sit[- ]?ups?|crunch(es)?|mountain|bird dog|dead bug|superman|nordic|stretch|walk|jog|run|sprints?|yoga|mobility|foam|lunges?|split squats?|step[- ]?ups?|single[- ]leg)\b"#
        if has(bodyweight) { return false }
        return has(#"\b(rows?|press(es)?|curls?|deadlifts?|rdls?|squats?|lunges?|raises?|fly|flyes|flys|flies|shrugs?|extensions?|thrusts?|swings?|carry|carries|cleans?|snatch(es)?|pullovers?|skull ?crushers?)\b"#)
    }

    static func basis(for exerciseName: String) -> LoadBasis {
        if let known = catalogBasis[exerciseName] { return known }
        // "Seated Arnold Press" is still an Arnold Press.
        let bare = exerciseName.replacingOccurrences(
            of: #"(?i)^(seated|sitting|standing|half[- ]?kneeling|tall[- ]?kneeling|kneeling|incline|decline)\s+"#,
            with: "", options: .regularExpression)
        if let known = catalogBasis[bare] { return known }
        let lower = exerciseName.lowercased()
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        if has(implementPattern) { return has(singleImplementPattern) ? .one : .each }
        if has(oneObjectPattern) { return .one }
        if has(barPattern) { return .bar }
        return .total
    }

    // MARK: - Saying it

    /// "35", "37.5".
    static func number(_ pounds: Double) -> String {
        pounds.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(pounds)) : String(format: "%.1f", pounds)
    }

    /// On screen: "35 lb each", "35 lb", "135 lb total".
    static func label(_ pounds: Double, for exerciseName: String) -> String {
        label(pounds, basis: basis(for: exerciseName))
    }

    static func label(_ pounds: Double, basis: LoadBasis) -> String {
        let n = number(pounds)
        switch basis {
        case .each: return "\(n) lb each"
        case .one: return "\(n) lb"
        case .bar, .total: return "\(n) lb total"
        }
    }

    /// A change: "35 → 40 lb each", "35 → 40 lb", "135 → 145 lb total".
    static func change(from: Double, to: Double, for exerciseName: String) -> String {
        let unit: String
        switch basis(for: exerciseName) {
        case .each: unit = "lb each"
        case .one: unit = "lb"
        case .bar, .total: unit = "lb total"
        }
        return "\(number(from)) → \(number(to)) \(unit)"
    }

    /// Out loud: "35 pounds each", "35 pounds", "135 pounds total".
    static func spoken(_ pounds: Double, for exerciseName: String) -> String {
        let n = number(pounds)
        switch basis(for: exerciseName) {
        case .each: return "\(n) pounds each"
        case .one: return "\(n) pounds"
        case .bar, .total: return "\(n) pounds total"
        }
    }

    // MARK: - Hearing it

    /// A weight change, if that's what you said. Pounds unless you say
    /// kilos. Nil without a number ("I'm going up") — that goes to the
    /// coach, which asks "up to what?".
    static func request(in transcript: String) -> WeightRequest? {
        let t = transcript.lowercased().replacingOccurrences(of: "’", with: "'")
        func has(_ pattern: String) -> Bool { t.range(of: pattern, options: .regularExpression) != nil }
        guard let number = firstNumber(in: t), number >= 2.5, number <= 1000 else { return nil }
        // "Go to 12 reps", "it's 5 sets" — that number is reps or sets.
        if has(#"\b\d+\s*(reps?|sets?|times|rounds?|minutes?|mins?|seconds?)\b"#) { return nil }
        let isKilos = has(#"\b(kg|kgs|kilo|kilos|kilograms?)\b"#)
        let pounds = isKilos ? (number * 2.20462 / 2.5).rounded() * 2.5 : number
        let stated: WeightRequest.Stated? =
            has(#"\b(total|both|altogether|combined|all together|in total)\b"#) ? .total
            : has(#"\b(each|apiece|per (hand|side|arm|dumbbell|bell)|a hand|a side|each hand|each side|in each)\b"#) ? .each
            : nil
        let mentionsWeight = has(#"\b(pounds?|lbs?|kg|kgs|kilos?|kilograms?|weight|weights|plates?|heavier|lighter|dumbbells?|bells?|kettlebells?)\b"#)
            || stated != nil
        let saysUp = has(#"\b(up|increase|increasing|increased|add|adding|added|bump|bumping|bumped|raise|raising|raised|heavier|go up|going up|went up)\b"#)
        let saysDown = has(#"\b(down|decrease|decreasing|decreased|drop|dropping|dropped|lower|lowering|lowered|reduce|reducing|reduced|lighter|take off|took off)\b"#)
        // "50s", "the 40s": a pair of bells by their number (the plural
        // isn't "seconds": "hold for 30s" has no verb here).
        let absolute = has(#"\b(to|at|using|use|with|make it|it's|its|now|grab|grabbing|grabbed|pick up|picking up|go with|going with)\s+(?:the )?(\d+(?:\.\d+)?s?|a hundred|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)\b"#)
            || has(#"\bthe \d+s\b"#)
        let perSide = has(#"\b(on each side|each side|per side|a side|on either side|each end)\b"#)
        // "10 each side" with no weight word is reps on a one-sided lift.
        if perSide, !has(#"\b(pounds?|lbs?|kg|kgs|kilos?|kilograms?|plates?)\b|\b\d+s\b"#) { return nil }

        // "More"/"less" only mean weight when a unit says so ("ten more
        // pounds") — "five more" is reps.
        let up = saysUp || (mentionsWeight && t.contains("more"))
        let down = saysDown || (mentionsWeight && t.contains("less"))
        let direction = up == down ? 0 : (up ? 1 : -1)
        if up || down {
            if absolute { return WeightRequest(change: .to(pounds), stated: stated, direction: direction, perSide: perSide) }
            return WeightRequest(change: .by(up ? pounds : -pounds), stated: stated, direction: direction, perSide: perSide)
        }
        if mentionsWeight || absolute { return WeightRequest(change: .to(pounds), stated: stated, perSide: perSide) }
        return nil
    }

    /// What the stored weight becomes, and whether to check the reading
    /// out loud.
    /// - Two bells ("each"): "70 total" is 35 each. `guess`: with neither
    ///   word, a new number at least 1.6× what you hold, whose half still
    ///   goes the way you said ("up to 80" holding 35s), reads as the total
    ///   and is checked. "Up to 50" holding 35s is 50 each. The coach's tool
    ///   says which it means, so it passes false.
    /// - A bar: "25s a side" is the bar plus two plates (95 total).
    /// - Anything else counted as a total: "25 a side" is checked as 50.
    static func resolve(_ request: WeightRequest, current: Double, basis: LoadBasis, guess: Bool = true)
        -> WeightResolution
    {
        let halve = basis == .each && request.stated == .total
        switch request.change {
        case .by(let delta):
            let step = halve ? delta / 2 : (request.perSide && (basis == .bar || basis == .total) ? delta * 2 : delta)
            return WeightResolution(pounds: clamp(current + step))
        case .to(let value):
            if halve { return WeightResolution(pounds: clamp(value / 2)) }
            if request.perSide || (request.stated == .each && (basis == .bar || basis == .total)) {
                switch basis {
                case .bar: return WeightResolution(pounds: clamp(barPounds + 2 * value), platesPerSide: value)
                case .total: return WeightResolution(pounds: clamp(2 * value), check: true)
                case .each, .one: break
                }
            }
            if guess, basis == .each, request.stated == nil, current > 0, request.direction >= 0,
               value >= current * 1.6, request.direction == 0 || value / 2 > current {
                return WeightResolution(pounds: clamp(value / 2), check: true)
            }
            return WeightResolution(pounds: clamp(value))
        }
    }

    /// The line said back once the weight changes: "Arnold Press: 35 pounds
    /// each hand." / "35 each hand, so 70 total, right?"
    static func confirmation(_ pounds: Double, exercise name: String, short: String, checked: Bool) -> String {
        confirmation(WeightResolution(pounds: pounds, check: checked), exercise: name, short: short)
    }

    static func confirmation(_ r: WeightResolution, exercise name: String, short: String) -> String {
        if let plates = r.platesPerSide {
            return "\(short): \(number(plates)) a side on a \(number(barPounds)) bar, \(number(r.pounds)) pounds total."
        }
        if r.check {
            return basis(for: name) == .each
                ? "\(short): \(number(r.pounds)) each hand, \(number(r.pounds * 2)) total. Right?"
                : "\(short): \(number(r.pounds)) pounds total. Right?"
        }
        return "\(short): \(spoken(r.pounds, for: name))."
    }

    private static func clamp(_ pounds: Double) -> Double { min(max(pounds, 0), 2000) }

    // MARK: - Numbers

    private static let ones: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// The first number in what was said: "37.5", "35", "thirty five",
    /// "a hundred and thirty five", "two twenty five" (225).
    static func firstNumber(in text: String) -> Double? {
        if let range = text.range(of: #"\d+(\.\d+)?"#, options: .regularExpression) {
            return Double(text[range])
        }
        let words = text.replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        var i = 0
        while i < words.count {
            if let value = numberWords(words, from: i) { return Double(value) }
            i += 1
        }
        return nil
    }

    private static func numberWords(_ words: [String], from start: Int) -> Int? {
        var i = start
        func word(_ k: Int) -> String? { k < words.count ? words[k] : nil }
        // Up to 99: "thirty five", "forty", "fifteen".
        func small(_ k: inout Int) -> Int? {
            guard let w = word(k) else { return nil }
            if let ten = tens[w] {
                k += 1
                if let next = word(k), let one = ones[next], one < 10 { k += 1; return ten + one }
                return ten
            }
            if let one = ones[w] { k += 1; return one }
            return nil
        }
        var hundreds = 0
        if word(i) == "a" || word(i) == "one", word(i + 1) == "hundred" {
            hundreds = 100; i += 2
        } else if let lead = ones[word(i) ?? ""], lead < 10, word(i + 1) == "hundred" {
            hundreds = lead * 100; i += 2
        } else if let lead = ones[word(i) ?? ""], lead < 10, let w = word(i + 1), tens[w] != nil {
            // "two twenty five" is how a gym says 225.
            var k = i + 1
            if let rest = small(&k) { return lead * 100 + rest }
        }
        if hundreds > 0 {
            if word(i) == "and" { i += 1 }
            var k = i
            return hundreds + (small(&k) ?? 0)
        }
        var k = i
        return small(&k)
    }
}
