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
    static let soundAlikes: [String: Int] = [
        "won": 1, "wan": 1, "to": 2, "too": 2, "tu": 2, "tree": 3, "free": 3, "for": 4, "fore": 4,
        "fife": 5, "sex": 6, "sick": 6, "ate": 8, "nein": 9, "tin": 10, "tan": 10,
    ]

    /// How far you've counted: the longest run 1, 2, 3… in what you said,
    /// tolerating one missed word. "One two three five" is 5; "I did three
    /// sets" is 0 because it doesn't start at one.
    /// `from`: the count already reached before this transcript began — real
    /// counting spans pauses, and the recognizer restarts between them.
    static func repCount(in transcript: String, from start: Int = 0) -> Int {
        // "It was 2 sets at 10 reps", "50 pounds": describing, not counting.
        let words = tokens(transcript)
        let numbers = words.compactMap { Int($0) ?? numberWords[$0] }
        let runsOn = zip(numbers, numbers.dropFirst()).contains { $1 == $0 + 1 }
        if !runsOn, words.contains(where: { $0.range(of: #"^(sets?|reps?|pounds?|lbs?|kilos?|kg|kgs)$"#, options: .regularExpression) != nil }) {
            return start
        }
        // Every number-ish word, in order, with whether it was a clear
        // number or only sounds like one ("to", "for").
        let heard: [(value: Int, soundAlike: Bool)] = expanded(tokens(transcript), after: start).compactMap { token in
            if let value = Int(token) ?? numberWords[token] { return (value, false) }
            if let value = soundAlikes[token] { return (value, true) }
            return nil
        }
        var count = start
        for (i, number) in heard.enumerated() {
            let ahead = number.value - count
            guard ahead > 0 else { continue }
            // The next number, clear or sound-alike: always.
            if ahead == 1 { count = number.value; continue }
            // The recogniser drops words. A clear number a little ahead
            // resyncs the count ("…six, [seven lost], eight" lands on
            // eight), and a count can start on two or three when "one" was
            // lost. A sound-alike may only skip one.
            let limit = number.soundAlike ? 2 : 3
            if count == 0 ? (!number.soundAlike && number.value <= 3) : ahead <= limit {
                count = number.value
                continue
            }
            // Two numbers in a row are proof you're counting, however many
            // were missed before them: "two … [three, four, five lost] …
            // six, seven" lands on seven.
            if number.value <= 30, i + 1 < heard.count, heard[i + 1].value == number.value + 1,
               !(number.soundAlike && heard[i + 1].soundAlike) {
                count = number.value
            }
        }
        return count
    }

    /// Nothing but numbers (and counting filler): mid-workout this is a
    /// count, even one that couldn't be followed, and never a message.
    static func isOnlyNumbers(_ transcript: String) -> Bool {
        let words = tokens(transcript)
        guard !words.isEmpty else { return false }
        let filler: Set<String> = ["and", "uh", "um", "okay", "ok", "come", "on", "more", "rep", "reps"]
        return words.allSatisfy { Int($0) != nil || numberWords[$0] != nil || soundAlikes[$0] != nil || filler.contains($0) }
            && words.contains { Int($0) != nil || numberWords[$0] != nil }
    }

    /// "Can I do these seated?", "let me do it kneeling", "switch to
    /// standing": a change of position for the lift you're on.
    static func stanceRequest(_ transcript: String) -> ExerciseMotion.Stance? {
        let t = normalized(transcript)
        guard t.range(of: #"\b(not|don't|never)\b"#, options: .regularExpression) == nil,
              t.range(of: #"\b(can i|could i|can we|should i|let me|let's|lets|i'll|i will|i want to|i wanna|i'm gonna|i am going to|switch|change|go|do (it|this|these|them|those|this one|the rest)|instead|rather)\b"#,
                      options: .regularExpression) != nil,
              t.range(of: #"\b(seated|sitting|kneeling|on my knees|standing|stand up)\b"#, options: .regularExpression) != nil
        else { return nil }
        return ExerciseMotion.Stance.named(in: t)
    }

    /// The same lift in another position: "Dumbbell Shoulder Press" →
    /// "Seated Dumbbell Shoulder Press"; "Seated Curl" → "Standing Curl".
    static func variant(of name: String, _ stance: ExerciseMotion.Stance) -> String {
        let bare = name.replacingOccurrences(
            of: #"(?i)\b(seated|sitting|standing|half[- ]?kneeling|tall[- ]?kneeling|kneeling)\b\s*"#,
            with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        switch stance {
        case .seated: return "Seated \(bare)"
        case .kneeling: return "Kneeling \(bare)"
        case .standing: return "Standing \(bare)"
        }
    }

    /// "Done", "that's the set", "finished" — the set is over at whatever count.
    static func saysSetDone(_ transcript: String) -> Bool {
        let t = normalized(transcript)
        // "sat down", "shut down", "set down", "said done" are what the
        // recogniser makes of "set done" in a gym.
        return t.range(of: #"\b(done|finished|that's it|that is it|set complete|that's the set|got it|last one|sat down|shut down|set down|said done|said that|sit down|sets done|set's done|that's done|all done)\b"#,
                       options: .regularExpression) != nil
    }

    /// Mid-workout, worth the coach's attention without "MYO" first. The mic
    /// hears the gym: "E", "Hey", "What? Two.", "There she is." went to the
    /// coach and set off a loop of "did you mean…?" (2026-10-15). Fragments
    /// and stray words are dropped; a real question, a yes or no to the
    /// coach's question, or something about the workout gets through.
    static func worthSendingMidWorkout(_ transcript: String, justAsked: Bool) -> Bool {
        let words = tokens(transcript)
        let filler: Set<String> = ["uh", "um", "umm", "ah", "oh", "e", "a", "an", "the", "and", "so", "like", "what",
                                   "hey", "yo", "nah", "bon", "dam", "damn", "huh", "hmm", "mm", "okay", "ok", "wow", "man"]
        let meaningful = words.filter { !filler.contains($0) && Int($0) == nil && numberWords[$0] == nil }
        let t = normalized(transcript)
        func says(_ pattern: String) -> Bool { t.range(of: pattern, options: .regularExpression) != nil }
        if justAsked, says(#"^\W*(yes|yeah|yep|yup|no|nope|sure|correct|right|exactly|that's right)\b"#) { return true }
        guard meaningful.count >= 2 else { return false }
        let aboutWorkout = says(#"\b(heavy|heavier|light|lighter|weight|pounds?|lbs?|kilos?|reps?|sets?|hurts?|hurting|pain|sore|tired|form|next|skip|swap|done|finish|knee|back|shoulder|elbow|wrist|hip|ankle|neck|rest|break|water|easier|harder|instead|change|demo|show)\b"#)
        if justAsked || aboutWorkout { return true }
        return meaningful.count >= 3 && (isQuestionOrRequest(transcript) || words.count >= 6)
    }

    /// Mid-count, something that isn't a number and isn't "done": a question
    /// or a request Coach should act on, rather than a pause to ignore.
    static func isQuestionOrRequest(_ transcript: String) -> Bool {
        let t = normalized(transcript)
        if transcript.contains("?") { return true }
        return t.range(of: #"\b(show me|how do|how many|what|what's|when|why|can you|could you|should i|explain|again|swap|skip|add|change|remind|tell me|myo)\b"#,
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
    /// a count resumes mid-way after a pause. Judged on the LAST few words
    /// (`tail`), so "okay, let's go — one, two, three" still counts: the
    /// recogniser keeps everything since the mic last restarted, and one
    /// leading phrase must not poison a whole set.
    /// `running`: a count is already going. Then one stray word between
    /// numbers ("seven, oh god, eight") can't stall it: the last word being a
    /// number, or half the tail, is enough.
    static func looksLikeCounting(_ transcript: String, tail: Int = 4, running: Bool = false) -> Bool {
        let words = Array(tokens(transcript).suffix(tail))
        guard !words.isEmpty else { return false }
        if running, let last = words.last, isNumberWord(last) { return true }
        let filler: Set<String> = ["and", "done", "finished", "set", "that's", "it", "last", "the", "got", "rep", "reps",
                                   "okay", "ok", "uh", "um", "come", "on", "more"]
        let counted = words.filter { Int($0) != nil || numberWords[$0] != nil || soundAlikes[$0] != nil || filler.contains($0) }
        return Double(counted.count) / Double(words.count) >= (running ? 0.5 : 0.75)
    }

    /// A word that means "stop and listen to me" when Coach is talking and
    /// you're mid-workout: the next number of your count (so Coach saying
    /// "eight" can never cut itself off unless you're on seven), or a set
    /// being called done once a count is running.
    static func cutsIn(_ transcript: String, repCount: Int, countBase: Int) -> Bool {
        if repCount > 0, saysSetDone(transcript) { return true }
        return looksLikeCounting(transcript, running: repCount > 0)
            && self.repCount(in: transcript, from: countBase) > repCount
    }

    /// A lift done one side at a time, counted to the target on each side:
    /// "single-arm row", "Bulgarian split squat", "side plank".
    static func isEachSide(_ name: String) -> Bool {
        name.lowercased().range(
            of: #"\b(single|one)[- ]?(arm|leg|side)|each (side|arm|leg)|per (side|arm|leg)|unilateral|lunges?|split squat|bulgarian|step[- ]?ups?|suitcase|side plank|pistol|cossack|\b(left|right) and (left|right)"#,
            options: .regularExpression) != nil
    }

    /// Is this word a number or something that sounds like one.
    static func isNumberWord(_ word: String) -> Bool {
        Int(word) != nil || numberWords[word] != nil || soundAlikes[word] != nil
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
              says(#"\b(done|finished|finish|complete|completed|did|that's|got|knocked out|logged|was|were)\b"#) else { return nil }
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
        // "Go to 12 reps", "3 sets of 10" — those numbers are reps or sets,
        // so they're set aside; "3 sets of 10 with 50 pounds" still has 50.
        let t = normalized(transcript)
            .replacingOccurrences(of: #"\b(\d+|[a-z]+)\s+sets?\s+(of|at|for)\s+\d+(\s*reps?)?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\b\d+\s*(reps?|sets?|times|rounds?)\b"#, with: "", options: .regularExpression)
        guard let number = firstNumber(in: t), number >= 2.5, number <= 1000 else { return nil }
        let isKilos = t.range(of: #"\b(kg|kgs|kilo|kilos|kilograms?)\b"#, options: .regularExpression) != nil
        let pounds = isKilos ? (number * 2.20462 / 2.5).rounded() * 2.5 : number
        let mentionsWeight = t.range(of: #"\b(pounds?|lbs?|kg|kgs|kilos?|kilograms?|weight|plates?|heavier|lighter)\b"#,
                                     options: .regularExpression) != nil
        let saysUp = t.range(of: #"\b(up|increase|increased|add|added|bump|bumped|raise|raised|heavier|go up|went up)\b"#,
                         options: .regularExpression) != nil
        let saysDown = t.range(of: #"\b(down|decrease|decreased|drop|dropped|lower|lowered|reduce|reduced|lighter|take off|took off)\b"#,
                           options: .regularExpression) != nil
        let absolute = t.range(of: #"\b(to|at|using|use|used|with|make it|it's|its|now|was)\s+(a\s+|the\s+)?\d"#, options: .regularExpression) != nil

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
            // The recogniser writes "50 pound" as "£50": a weight, not money.
            .replacingOccurrences(of: #"£\s*(\d+(\.\d+)?)(\s*pounds?)?"#, with: "$1 pounds", options: .regularExpression)
    }

    /// "I did it with 50", "that was 50 pounds": about sets already done.
    static func isPastTense(_ transcript: String) -> Bool {
        normalized(transcript).range(of: #"\b(did|was|were|used|went|lifted|had|been)\b"#, options: .regularExpression) != nil
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
            // The recogniser glues a fast count into one number: "12456" for
            // 1, 2, [3 lost], 4, 5, 6, or "8910" for 8, 9, 10. Split it back
            // into rising reps, allowing one missed number between them.
            if token.count > 1, token.allSatisfy(\.isNumber), let run = splitCount(token, expected: expected) {
                out.append(contentsOf: run.map(String.init))
                expected = (run.last ?? 0) + 1
                continue
            }
            out.append(token)
            if let value = Int(token) ?? numberWords[token] { expected = value + 1 }
        }
        return out
    }

    /// "12456" → [1, 2, 4, 5, 6]; "8910" → [8, 9, 10]. Each rep is the last
    /// one plus 1 (or plus 2: one lost), up to 30. Nil if it doesn't read as
    /// a count starting at `expected` (or at 1, a fresh set).
    static func splitCount(_ token: String, expected: Int) -> [Int]? {
        let chars = Array(token)
        func walk(_ index: Int, _ last: Int, _ acc: [Int]) -> [Int]? {
            if index == chars.count { return acc }
            for width in [1, 2] where index + width <= chars.count {
                guard let value = Int(String(chars[index..<index + width])), String(value).count == width else { continue }
                let step = value - last
                guard value <= 30, step == 1 || step == 2 else { continue }
                if let done = walk(index + width, value, acc + [value]) { return done }
            }
            return nil
        }
        for start in Set([expected, 1]) {
            let width = String(start).count
            guard chars.count > width, String(chars.prefix(width)) == String(start),
                  let run = walk(width, start, [start]), run.count >= 2 else { continue }
            return run
        }
        return nil
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
