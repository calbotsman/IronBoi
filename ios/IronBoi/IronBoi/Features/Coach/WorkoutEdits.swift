import Foundation

/// Changes to the workout you call out mid-session, handled on the phone:
/// adding a lift, swapping one, skipping one, doing them in a different
/// order, changing sets or reps, finishing. What isn't one of these goes to
/// Coach as usual.
enum WorkoutEdit: Equatable {
    case add(name: String, sets: Int?, reps: Int?, weight: Double?, now: Bool)
    case swap(Int, to: String)
    case skip(Int)
    case jump(Int)
    case targets(Int, sets: Int?, reps: Int?)
    case finish

    static func parse(_ transcript: String, exercises: [ActiveWorkoutExercise], current: Int?) -> WorkoutEdit? {
        let t = transcript.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[.!?,]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        func first(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
            return (1..<match.numberOfRanges).map { i in
                Range(match.range(at: i), in: t).map { String(t[$0]) } ?? ""
            }
        }
        func find(_ phrase: String) -> Int? { resolve(phrase, in: exercises, current: current) }

        if first(#"\b(finish|end|wrap up|complete|close out)( my| the| this)? (workout|session)\b"#) != nil
            || first(#"\b(workout|session)('s| is) (done|over|finished)\b"#) != nil
            || first(#"\bi'm done for (the day|today)\b"#) != nil {
            return .finish
        }
        if let m = first(#"\b(?:swap|switch|replace|sub|substitute|trade)(?: out)? (?:the )?(.+?) (?:for|with) (.+)$"#),
           let index = find(m[0]) {
            return .swap(index, to: cleanName(m[1]))
        }
        if let m = first(#"\b(?:do|let's do|lets do|i'll do|ill do) (.+?) instead of (?:the )?(.+)$"#),
           let index = find(m[1]) {
            return .swap(index, to: cleanName(m[0]))
        }
        if let m = first(#"^(?:let's |lets |can we |i want to |i'm gonna |gonna )?(?:skip|drop|remove|cut|ditch|forget) (?:the )?(.+?)(?: today| for today| this time)?$"#),
           let index = find(m[0]) {
            return .skip(index)
        }
        if let m = first(#"\b(?:add|throw in|tack on|put in|add in|also do|squeeze in)(?: some| a few| a| an)? (.+)$"#) {
            let rest = m[0]
            let (sets, reps) = setsAndReps(in: rest)
            let weight = first(#"\bat (\d+(?:\.\d+)?)"#).flatMap { Double($0[0]) }
            let now = rest.range(of: #"\b(now|next|first)\b"#, options: .regularExpression) != nil
            let name = cleanName(rest)
            guard !name.isEmpty, find(name) == nil else { return nil }
            return .add(name: name, sets: sets, reps: reps, weight: weight, now: now)
        }
        if let m = first(#"\b(?:do|go to|switch to|start with|jump to|move to|move on to|hit|skip ahead to|skip to) (?:the )?(.+?)(?: first| next| now| right now)$"#),
           let index = find(m[0]), index != current {
            return .jump(index)
        }
        if let m = first(#"\b(?:start with|jump to|go to|switch to|move on to|skip ahead to|skip to) (?:the )?(.+)$"#),
           let index = find(m[0]), index != current {
            return .jump(index)
        }
        if let current, first(#"\b(make it|make that|let's do|lets do|i'll do|do|change (?:it|this|that) to|switch to|going to do|gonna do)\b"#) != nil
            || t.contains("instead") {
            let (sets, reps) = setsAndReps(in: t)
            if sets != nil || reps != nil {
                let target = first(#"\bfor (?:the )?([a-z -]+)$"#).flatMap { find($0[0]) } ?? current
                return .targets(target, sets: sets, reps: reps)
            }
        }
        return nil
    }

    // MARK: - Pieces

    /// Which exercise in the workout a phrase means: "the last one", "the
    /// next one", or by name ("bench" → Barbell Bench Press).
    static func resolve(_ phrase: String, in exercises: [ActiveWorkoutExercise], current: Int?) -> Int? {
        let p = phrase.trimmingCharacters(in: .whitespaces)
        let open = exercises.indices.filter { !exercises[$0].exerciseDone }
        if p.range(of: #"^(the )?last( one| exercise| lift)?$"#, options: .regularExpression) != nil {
            return open.last ?? exercises.indices.last
        }
        if p.range(of: #"^(the )?first( one| exercise| lift)?$"#, options: .regularExpression) != nil {
            return open.first
        }
        if p.range(of: #"^(the )?next( one| exercise| lift)?$"#, options: .regularExpression) != nil {
            return open.first { $0 != current }
        }
        let words = keyWords(p)
        guard !words.isEmpty else { return nil }
        var best: (index: Int, score: Int)?
        for (index, exercise) in exercises.enumerated() {
            let score = keyWords(exercise.name).intersection(words).count
            if score > 0, score > (best?.score ?? 0) { best = (index, score) }
        }
        return best?.index
    }

    /// The words that tell lifts apart: no equipment, no plurals, no filler.
    private static func keyWords(_ text: String) -> Set<String> {
        let skip: Set<String> = ["the", "a", "some", "my", "barbell", "dumbbell", "db", "kb", "kettlebell", "bb",
                                 "one", "exercise", "lift", "of", "and", "with", "to"]
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count > 1 && !skip.contains($0) }
            .map { word -> String in
                if word.hasSuffix("es"), word.count > 4, !word.hasSuffix("ses") { return String(word.dropLast(2)) }
                if word.hasSuffix("s"), word.count > 3 { return String(word.dropLast()) }
                return word
            }
        return Set(words)
    }

    /// "3 sets of 12", "3 by 12", "3x12", "4 sets", "12 reps".
    static func setsAndReps(in text: String) -> (sets: Int?, reps: Int?) {
        let n = #"(\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty)"#
        func value(_ s: String) -> Int? { Int(s) ?? WorkoutVoice.numberWords[s] }
        func groups(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: text).map { String(text[$0]) } }
        }
        if let g = groups(n + #"\s*(?:sets of|by|x|times)\s*"# + n), g.count == 2 {
            return (value(g[0]), value(g[1]))
        }
        let sets = groups(n + #"\s+sets\b"#).flatMap { value($0[0]) }
        let reps = groups(n + #"\s+reps\b"#).flatMap { value($0[0]) }
        return (sets, reps)
    }

    /// "some bicep curls 3 by 12 at 25 now" → "Bicep Curls".
    static func cleanName(_ text: String) -> String {
        var s = text
        for pattern in [#"\b\d+(\.\d+)?\s*(sets? of|by|x|times)\s*\d+\b"#, #"\b\d+\s+(sets?|reps?)\b"#,
                        #"\bat \d+(\.\d+)?( pounds| lbs?| kilos?| kg)?\b"#,
                        #"\b(now|next|first|today|too|as well|at the end|to the end|to the workout|please|instead)\b"#,
                        #"^(some|a few|a|an|the)\s+"#] {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let words = s.split(separator: " ").filter { !$0.isEmpty }
        return words.map { word in
            ["db", "kb", "rdl", "ez"].contains(word) ? word.uppercased() : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}
