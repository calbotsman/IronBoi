import Foundation

/// What you say mid-workout that the phone handles itself, instantly,
/// without a round trip to the coach: counting reps out loud, calling a set
/// done, and changing the weight.
enum WorkoutVoice {
    enum WeightChange: Equatable {
        case to(Double)
        case by(Double)
    }

    // MARK: - Counting

    static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20,
    ]
    /// What the recognizer hears when you count: "to" for two, "for" for four…
    /// Only accepted when it's the next number in the count.
    private static let soundAlikes: [String: Int] = [
        "won": 1, "to": 2, "too": 2, "tree": 3, "for": 4, "fore": 4, "sex": 6, "ate": 8, "tin": 10,
    ]

    /// How far you've counted: the longest run 1, 2, 3… in what you said,
    /// tolerating one missed word. "One two three five" is 5; "I did three
    /// sets" is 0 because it doesn't start at one.
    /// `from`: the count already reached before this transcript began — real
    /// counting spans pauses, and the recognizer restarts between them.
    static func repCount(in transcript: String, from start: Int = 0) -> Int {
        var count = start
        for token in expanded(tokens(transcript), after: start) {
            let value = Int(token) ?? numberWords[token] ?? soundAlikes[token]
            guard let value else { continue }
            let isSoundAlike = Int(token) == nil && numberWords[token] == nil
            if value == count + 1 || (!isSoundAlike && value == count + 2 && count > 0) {
                count = value
            }
        }
        return count
    }

    /// "Done", "that's the set", "finished" — the set is over at whatever count.
    static func saysSetDone(_ transcript: String) -> Bool {
        let t = normalized(transcript)
        return t.range(of: #"\b(done|finished|that's it|that is it|set complete|that's the set|got it|last one)\b"#,
                       options: .regularExpression) != nil
    }

    /// True when what you said was only counting (and maybe "done") — so
    /// it shouldn't also be sent to the coach as a message.
    static func isOnlyCounting(_ transcript: String) -> Bool {
        let words = tokens(transcript)
        guard !words.isEmpty else { return false }
        let filler: Set<String> = ["and", "done", "finished", "set", "that's", "it", "last", "the", "got", "rep", "reps", "okay", "ok"]
        let counted = words.filter { Int($0) != nil || numberWords[$0] != nil || soundAlikes[$0] != nil || filler.contains($0) }
        return Double(counted.count) / Double(words.count) >= 0.8 && repCount(in: transcript) > 0
    }

    /// Mostly numbers (and a little filler) — someone counting, not a
    /// sentence that happens to contain "12". Doesn't need to start at one:
    /// a count resumes mid-way after a pause.
    static func looksLikeCounting(_ transcript: String) -> Bool {
        let words = tokens(transcript)
        guard !words.isEmpty else { return false }
        let filler: Set<String> = ["and", "done", "finished", "set", "that's", "it", "last", "the", "got", "rep", "reps",
                                   "okay", "ok", "uh", "um", "come", "on", "more"]
        let counted = words.filter { Int($0) != nil || numberWords[$0] != nil || soundAlikes[$0] != nil || filler.contains($0) }
        return Double(counted.count) / Double(words.count) >= 0.75
    }

    // MARK: - Sets without counting

    struct SetsLogged: Equatable {
        /// How many sets; nil means every set left on this exercise.
        let sets: Int?
        /// Reps per set if you said ("set done, eight reps"), else the target.
        let reps: Int?
    }

    /// "Set done", "finished that set", "two sets done", "did three sets of
    /// eight", "all sets done" — for when you didn't count out loud. Needs
    /// the word "set", so a bare "done" (finishing the workout?) isn't one.
    static func setsLogged(in transcript: String) -> SetsLogged? {
        let t = normalized(transcript)
        func says(_ pattern: String) -> Bool { t.range(of: pattern, options: .regularExpression) != nil }
        // "How many sets did I do?", "two sets left" — questions and counts
        // of what's to come aren't logging anything.
        if transcript.contains("?") || says(#"^(how|what|which|when|is|are|should|can|did i|do i)\b"#)
            || says(#"\b(left|to go|remaining|how many)\b"#) && !says(#"\b(all|every)( the| my)? remaining\b"#) {
            return nil
        }
        guard says(#"\bsets?\b"#),
              says(#"\b(done|finished|finish|complete|completed|did|that's|got|knocked out|logged)\b"#) else { return nil }
        let reps = number(before: #"\s*(reps?|times)\b"#, in: t) ?? number(after: #"\bsets? of\s+"#, in: t)
        if says(#"\b(all|every|remaining)( the| my| of my| of the)? sets\b"#) || says(#"\ball done\b"#) {
            return SetsLogged(sets: nil, reps: reps)
        }
        let sets = number(before: #"\s+sets\b"#, in: t) ?? 1
        guard (1...10).contains(sets) else { return nil }
        return SetsLogged(sets: sets, reps: reps.flatMap { (1...100).contains($0) ? $0 : nil })
    }

    /// The number (digits or a word) right before `suffix`.
    private static func number(before suffix: String, in t: String) -> Int? {
        guard let range = t.range(of: #"(\d+|[a-z]+)"# + suffix, options: .regularExpression) else { return nil }
        let word = t[range].split(separator: " ").first.map(String.init) ?? ""
        return Int(word) ?? numberWords[word] ?? (word == "a" || word == "one" ? 1 : nil)
    }

    /// The number (digits or a word) right after `prefix`.
    private static func number(after prefix: String, in t: String) -> Int? {
        guard let range = t.range(of: prefix + #"(\d+|[a-z]+)"#, options: .regularExpression) else { return nil }
        let word = t[range].split(separator: " ").last.map(String.init) ?? ""
        return Int(word) ?? numberWords[word]
    }

    // MARK: - Weight

    /// A weight change, if that's what you said. Pounds unless you say kilos.
    static func weightChange(in transcript: String) -> WeightChange? {
        let t = normalized(transcript)
        guard let number = firstNumber(in: t), number >= 2.5, number <= 1000 else { return nil }
        // "Go to 12 reps", "it's 5 sets" — that number is reps or sets.
        if t.range(of: #"\b\d+\s*(reps?|sets?|times|rounds?)\b"#, options: .regularExpression) != nil { return nil }
        let isKilos = t.range(of: #"\b(kg|kgs|kilo|kilos|kilograms?)\b"#, options: .regularExpression) != nil
        let pounds = isKilos ? (number * 2.20462 / 2.5).rounded() * 2.5 : number
        let mentionsWeight = t.range(of: #"\b(pounds?|lbs?|kg|kgs|kilos?|kilograms?|weight|plates?|heavier|lighter)\b"#,
                                     options: .regularExpression) != nil
        let saysUp = t.range(of: #"\b(up|increase|increased|add|added|bump|bumped|raise|raised|heavier|go up|went up)\b"#,
                         options: .regularExpression) != nil
        let saysDown = t.range(of: #"\b(down|decrease|decreased|drop|dropped|lower|lowered|reduce|reduced|lighter|take off|took off)\b"#,
                           options: .regularExpression) != nil
        let absolute = t.range(of: #"\b(to|at|using|use|with|make it|it's|its|now)\s+\d"#, options: .regularExpression) != nil

        // "More"/"less" only mean weight when a unit says so ("ten more
        // pounds") — "five more" is reps.
        let up = saysUp || (mentionsWeight && t.contains("more"))
        let down = saysDown || (mentionsWeight && t.contains("less"))
        if up || down {
            if absolute { return .to(pounds) }
            return .by(up ? pounds : -pounds)
        }
        if mentionsWeight || absolute { return .to(pounds) }
        return nil
    }

    // MARK: - Helpers

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
    }

    private static func tokens(_ text: String) -> [String] {
        normalized(text)
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    /// The recognizer sometimes runs a count together ("12" for "one two",
    /// "345"): split a digit string into single digits when that continues
    /// the count.
    private static func expanded(_ tokens: [String], after start: Int) -> [String] {
        var out: [String] = []
        var expected = start + 1
        for token in tokens {
            if token.count > 1, token.allSatisfy(\.isNumber), let first = Int(String(token.first!)),
               first == expected || first == 1 {
                let digits = token.compactMap { Int(String($0)) }
                if zip(digits, digits.dropFirst()).allSatisfy({ $1 == $0 + 1 }) {
                    out.append(contentsOf: digits.map(String.init))
                    expected = (digits.last ?? 0) + 1
                    continue
                }
            }
            out.append(token)
            if let value = Int(token) ?? numberWords[token] { expected = value + 1 }
        }
        return out
    }

    private static func firstNumber(in text: String) -> Double? {
        if let range = text.range(of: #"\d+(\.\d+)?"#, options: .regularExpression) {
            return Double(text[range])
        }
        for token in tokens(text) {
            if let value = numberWords[token] { return Double(value) }
        }
        return nil
    }
}
