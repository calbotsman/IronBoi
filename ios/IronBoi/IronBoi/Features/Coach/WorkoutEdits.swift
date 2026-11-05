import Foundation

/// Changes to the workout you call out mid-session, handled on the phone:
/// adding a lift, swapping one, skipping one, doing them in a different
/// order, changing sets or reps, finishing. What isn't one of these goes to
/// Coach as usual.
enum WorkoutEdit: Equatable {
    case add(name: String, sets: Int?, reps: Int?, weight: Double?, now: Bool)
    /// "I'm adding indoor cycling today", "20 minutes on the bike", "a run
    /// at the end": a cardio block done for minutes, not sets.
    case addCardio(name: String, minutes: Int, now: Bool)
    case swap(Int, to: String)
    /// "Swap the bench", "something else instead of curls" — no
    /// replacement named: offer some.
    case swapForSomething(Int)
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

        // A question or a "not" is never a command ("what should I eat
        // after I finish my workout?", "don't skip curls").
        // Question words lead on their own; "do/is/are…" only make a question
        // with a pronoun after ("do I need to…", "is this enough"). Bare "do"
        // and polite "can we / could you" are commands ("do squats next",
        // "can we swap the bench").
        let isQuestion = transcript.contains("?")
            || t.range(of: #"^(what|how|when|why|where|which|who|should)\b"#, options: .regularExpression) != nil
            || t.range(of: #"^(do|does|did|will|is|are)\s+(i|we|you|it|they|there|this|that)\b"#,
                       options: .regularExpression) != nil
        if isQuestion || t.range(of: #"\b(don't|do not|never|not)\b"#, options: .regularExpression) != nil { return nil }
        if first(#"^(?:ok |okay |alright |let's |lets |i want to |i'm gonna )?(?:finish|end|wrap up|complete|close out)( my| the| this)? (workout|session)\b"#) != nil
            || first(#"^(?:my |the |this )?(workout|session)('s| is) (done|over|finished)\b"#) != nil
            || first(#"^i'?m done for (the day|today)\b"#) != nil {
            return .finish
        }
        let vague = #"^(?:something|anything|another|an alternative|alternative|a different|different|an easier|something easier|something different|something else|another one|something lighter)(?: one| exercise| lift| movement| move| else| option)?$"#
        if let m = first(#"\b(?:swap|switch|replace|sub|substitute|trade|change)(?: out)? (?:the )?(.+?) (?:for|with) (.+)$"#),
           let index = find(m[0]) {
            let target = m[1].trimmingCharacters(in: .whitespaces)
            if target.range(of: vague, options: .regularExpression) != nil { return .swapForSomething(index) }
            return .swap(index, to: cleanName(target))
        }
        if let m = first(#"\b(?:something else|an alternative|another (?:exercise|lift|option)) (?:instead of|for|than) (?:the )?(.+)$"#),
           let index = find(m[0]) {
            return .swapForSomething(index)
        }
        if let m = first(#"^(?:can (?:we|i|you) |let's |lets |i want to |i'd like to )?(?:swap|switch|replace|sub|change)(?: out)? (?:the |this |that )?(.+?)(?: please)?$"#),
           !m[0].contains(" for "), !m[0].contains(" with "), let index = find(m[0]) {
            return .swapForSomething(index)
        }
        if let m = first(#"\b(?:do|let's do|lets do|i'll do|ill do) (.+?) instead of (?:the )?(.+)$"#),
           let index = find(m[1]) {
            return .swap(index, to: cleanName(m[0]))
        }
        // "Skip this", "skip this one", even "skip this workout": the lift
        // you're on — never the whole session (that's "I'm done for today").
        if let current, first(#"^(?:let's |lets |can we |can you |could we |i want to |i wanna |i'm gonna |gonna )?(?:skip|pass on|next) (?:this|it|that|this one|that one|this move|this exercise|this lift|this workout|this set)(?: one)?(?: please)?$"#) != nil {
            return .skip(current)
        }
        if let m = first(#"^(?:let's |lets |can we |can you |could you |could we |would you |i want to |i'm gonna |gonna )?(?:skip|drop|remove|cut|ditch|forget) (?:the )?(.+?)(?: today| for today| this time)?$"#),
           // "Forget it", "drop that" are about what was just said, not a lift.
           m[0].range(of: #"^(it|that|this|about it|about that)$"#, options: .regularExpression) == nil,
           let index = find(m[0]) {
            return .skip(index)
        }
        if let cardio = cardioRequest(t), find(cardio.name) == nil {
            return .addCardio(name: cardio.name, minutes: cardio.minutes, now: cardio.now)
        }
        if let m = first(#"\b(?:add|adding|throw in|throwing in|tack on|put in|add in|also do|squeeze in)(?: some| a few| a| an)? (.+)$"#) {
            let rest = m[0]
            // "Add ten pounds", "add a plate", "add another set": weight or
            // volume, not a new lift.
            let amount = #"(?:a|an|another|some|more|one|two|three|four|five|ten|fifteen|twenty|\d+(?:\.\d+)?)"#
            if rest.range(of: "^(?:" + amount + #"\s+)*(?:pounds?|lbs?|kilos?|kgs?|plates?|weight|sets?|reps?|rounds?|more)\b"#,
                          options: .regularExpression) != nil {
                return nil
            }
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

    // MARK: - Cardio

    /// A cardio block they're adding: what, how long (20 minutes when they
    /// don't say), and whether it's now. Needs a cardio word and something
    /// that makes it a plan for today — a verb like "add" or "do", a length,
    /// or "at the end" — so "I went for a run this morning" stays a chat.
    static func cardioRequest(_ t: String) -> (name: String, minutes: Int, now: Bool)? {
        guard let name = cardioName(t) else { return nil }
        let minutes = minutes(in: t)
        func has(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }
        // "I'm going for a run", "doing yoga instead", "not doing that": maybe
        // a whole-session switch, maybe an add-on. The coach tells them apart
        // (replace_session); only a plain "add it on" stays here.
        let extra = has(#"\b(add|adding|added|throw in|tack on|squeeze in|also|too|as well|after this|afterwards|at the end|to finish|finish with|end with)\b"#)
        if !extra, has(#"\b(instead|rather|not doing|don't want to do|dont want to do|skip (?:the|this|that|today)|go for|going for|gonna go|going to go)\b"#) {
            return nil
        }
        let adding = has(#"\b(add|adding|added|throw in|throwing in|tack on|tacking on|put in|squeeze in|squeezing in|also do|also doing|finish with|finishing with|end with|ending with|hop on|hopping on|jump on|get on|getting on)\b"#)
            || has(#"^(?:ok |okay |so |and |then |let's |lets |i'll |ill |i'm gonna |im gonna |gonna |i want to |i wanna |i'd like to |i'm going to |im going to )?(?:do|doing)\b"#)
            || has(#"\b(i'm doing|im doing|i'll do|ill do|i'm gonna do|gonna do|let's do|lets do|i want to do|i wanna do|i'm going to do)\b"#)
            || has(#"\b(at the end|to finish|after this|afterwards|to my workout|to the workout|to today's workout)\b"#)
        guard adding || minutes != nil else { return nil }
        let now = has(#"\b(now|right now|first|next)\b"#)
        return (name, minutes ?? 20, now)
    }

    /// "indoor cycling" → Indoor Cycling, "the bike" → Bike, "a run" → Run.
    static func cardioName(_ t: String) -> String? {
        guard ExerciseKnowledge.isCardio(t) else { return nil }
        func has(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }
        if has(#"\b(assault bike|air ?bike|airdyne)\b"#) { return "Assault Bike" }
        if has(#"\bski ?erg\b"#) { return "Ski Erg" }
        if has(#"\b(indoor|stationary|exercise|spin|spinning|peloton)\b"#), has(#"\b(cycl\w*|bike|biking|spin|spinning|peloton)\b"#) { return "Indoor Cycling" }
        if has(#"\b(cycling|cycle|bike|biking)\b"#) { return "Cycling" }
        if has(#"\b(rowing|rower|erg)\b"#) { return "Rowing" }
        if has(#"\btreadmill\b"#) { return has(#"\bwalk"#) ? "Treadmill Walk" : "Treadmill Run" }
        if has(#"\bincline walk"#) { return "Incline Walk" }
        if has(#"\b(run|running)\b"#) { return "Run" }
        if has(#"\b(jog|jogging)\b"#) { return "Jog" }
        if has(#"\belliptical\b"#) { return "Elliptical" }
        if has(#"\bstair"#) { return "Stair Climber" }
        if has(#"\b(jump rope|skipping rope)\b"#) { return "Jump Rope" }
        if has(#"\b(swim|swimming)\b"#) { return "Swim" }
        if has(#"\b(hike|hiking)\b"#) { return "Hike" }
        if has(#"\b(walk|walking)\b"#) { return "Walk" }
        if has(#"\bzone 2\b"#) { return "Zone 2 Cardio" }
        return "Cardio"
    }

    /// "20 minutes", "20 min", "twenty-five minutes", "half an hour", "an
    /// hour and a half", "1 hour".
    static func minutes(in t: String) -> Int? {
        let s = t.replacingOccurrences(of: "-", with: " ")
        func groups(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
            return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
        }
        if s.range(of: #"\b(an|one|1) (hour|hr) and a half\b|\b(90 minutes|ninety minutes)\b"#, options: .regularExpression) != nil { return 90 }
        if s.range(of: #"\bhalf (an )?hour\b"#, options: .regularExpression) != nil { return 30 }
        if s.range(of: #"\bquarter (of an )?hour\b"#, options: .regularExpression) != nil { return 15 }
        let tens: [String: Int] = ["thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90, "twenty": 20]
        func value(_ words: String) -> Int? {
            if let n = Int(words) { return n }
            let parts = words.split(separator: " ").map(String.init)
            if parts.count == 2, let ten = tens[parts[0]], let one = WorkoutVoice.numberWords[parts[1]], one < 10 { return ten + one }
            if parts.count == 1 { return tens[parts[0]] ?? WorkoutVoice.numberWords[parts[0]] }
            return nil
        }
        let word = #"(\d+|(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)(?: (?:one|two|three|four|five|six|seven|eight|nine))?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)"#
        if let g = groups(word + #"\s*(?:minutes?|mins?)\b"#), let n = value(g[0]), n > 0 { return min(n, 180) }
        if let g = groups(word + #"\s*(?:hours?|hrs?)\b"#), let n = value(g[0]), n > 0 { return min(n * 60, 180) }
        if s.range(of: #"\b(an|one) (hour|hr)\b"#, options: .regularExpression) != nil { return 60 }
        return nil
    }

    // MARK: - Pieces

    /// Which exercise in the workout a phrase means: "the last one", "the
    /// next one", or by name ("bench" → Barbell Bench Press).
    static func resolve(_ phrase: String, in exercises: [ActiveWorkoutExercise], current: Int?) -> Int? {
        let p = phrase.trimmingCharacters(in: .whitespaces)
        let open = exercises.indices.filter { !exercises[$0].exerciseDone }
        if p.range(of: #"^(it|this|that|this one|that one|this exercise|this lift|this move|this workout|the current one)$"#, options: .regularExpression) != nil {
            return current
        }
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
        // Exact words count double; a near miss counts once — speech
        // recognition hears "inverted row" as "inverter brow".
        var best: (index: Int, score: Int)?
        for (index, exercise) in exercises.enumerated() {
            let name = keyWords(exercise.name)
            let exact = name.intersection(words).count
            let near = words.filter { word in !name.contains(word) && name.contains { close($0, word) } }.count
            let score = exact * 2 + near
            if score > 0, score > (best?.score ?? 0) { best = (index, score) }
        }
        return best?.index
    }

    /// Within one edit for short words, two for longer ones ("brow"/"row",
    /// "inverter"/"inverted").
    private static func close(_ a: String, _ b: String) -> Bool {
        guard min(a.count, b.count) >= 3, abs(a.count - b.count) <= 2 else { return false }
        let x = Array(a), y = Array(b)
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var row = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return previous[y.count] <= (max(a.count, b.count) >= 6 ? 2 : 1)
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
                        #"\b(to|into|onto) (my|the|this|today's) (workout|session)\b"#,
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
