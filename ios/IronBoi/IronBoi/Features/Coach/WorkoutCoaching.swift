import Foundation

/// The parts of a workout a good trainer does without being asked: warm
/// you up, rest you the right amount, say something useful (and only
/// once) after a set, close out a lift before the next, and cool you down
/// with the stretches that matter most for what you just did.
enum WorkoutCoaching {

    /// "3 sets of 10", "3 sets of 30 s", "1 set of 8" — spelled out, so
    /// nobody has to decode "3 × 10".
    static func setsOf(_ sets: Int, _ reps: Int, timed: Bool, minutes: Bool = false) -> String {
        if minutes { return sets == 1 ? "\(reps) min" : "\(sets) × \(reps) min" }
        return "\(sets) \(sets == 1 ? "set" : "sets") of \(reps)\(timed ? " s" : "")"
    }

    // MARK: - Stretches and warm-ups

    struct Move: Equatable {
        let name: String
        /// Seconds per side for a stretch; total seconds for a warm-up move.
        let seconds: Int
        let eachSide: Bool
        /// One short thing to say while you do it.
        let cue: String
    }

    /// Muscle (as `ExerciseKnowledge` names them) → the stretch for it.
    private static let stretchFor: [String: Move] = {
        let chest = Move(name: "Doorway chest stretch", seconds: 30, eachSide: true, cue: "Forearm on the frame, step through until you feel the chest open.")
        let triceps = Move(name: "Overhead triceps stretch", seconds: 20, eachSide: true, cue: "Hand down your back, gently pull the elbow.")
        let shoulder = Move(name: "Cross-body shoulder stretch", seconds: 20, eachSide: true, cue: "Arm across your chest, pull it in at the elbow.")
        let lats = Move(name: "Child's pose with a side reach", seconds: 30, eachSide: true, cue: "Sit back, walk both hands to one side, breathe into your ribs.")
        let biceps = Move(name: "Wall biceps stretch", seconds: 20, eachSide: true, cue: "Palm on the wall behind you, turn away slowly.")
        let hamstrings = Move(name: "Standing hamstring stretch", seconds: 30, eachSide: true, cue: "Heel on something low, flat back, hinge until you feel it.")
        let glutes = Move(name: "Figure-four stretch", seconds: 30, eachSide: true, cue: "Ankle over the opposite knee, sit back.")
        let quads = Move(name: "Couch stretch", seconds: 30, eachSide: true, cue: "Back knee down, foot up behind you, squeeze that glute.")
        let calves = Move(name: "Wall calf stretch", seconds: 30, eachSide: true, cue: "Back leg straight, heel down, lean into the wall.")
        let back = Move(name: "Cat-cow", seconds: 30, eachSide: false, cue: "Slow. Round up on the exhale, drop the belly on the inhale.")
        let core = Move(name: "Cobra stretch", seconds: 20, eachSide: false, cue: "Hips down, press up gently, long neck.")
        let adductors = Move(name: "Butterfly stretch", seconds: 30, eachSide: false, cue: "Soles together, let the knees fall.")
        let traps = Move(name: "Neck side stretch", seconds: 20, eachSide: true, cue: "Ear toward shoulder, the other shoulder stays heavy.")
        return [
            "Chest": chest, "Upper chest": chest, "Front delts": chest,
            "Triceps": triceps,
            "Side delts": shoulder, "Rear delts": shoulder,
            "Lats": lats, "Mid back": lats,
            "Biceps": biceps, "Brachialis": biceps, "Forearms": biceps,
            "Hamstrings": hamstrings,
            "Glutes": glutes,
            "Quads": quads, "Hip flexors": quads,
            "Calves": calves,
            "Erectors": back,
            "Core": core,
            "Adductors": adductors,
            "Traps": traps,
        ]
    }()

    /// Muscle → a moving warm-up for it.
    private static let warmupFor: [String: Move] = {
        let squats = Move(name: "Bodyweight squats", seconds: 30, eachSide: false, cue: "Easy pace, full depth, wake the legs up.")
        let swings = Move(name: "Leg swings", seconds: 30, eachSide: true, cue: "Hold something, swing front to back, let it get bigger.")
        let hinges = Move(name: "Hip hinges", seconds: 30, eachSide: false, cue: "Hands on hips, push them back, stand tall. Find your hamstrings.")
        let arms = Move(name: "Arm circles", seconds: 30, eachSide: false, cue: "Small to big, then switch direction.")
        let scap = Move(name: "Scap push-ups", seconds: 30, eachSide: false, cue: "Arms straight, just squeeze and spread the shoulder blades.")
        let pullAparts = Move(name: "Arm swings", seconds: 30, eachSide: false, cue: "Hug yourself, then fling the arms wide. Open the back up.")
        let catCow = Move(name: "Cat-cow", seconds: 30, eachSide: false, cue: "Move with your breath.")
        return [
            "Quads": squats, "Glutes": squats, "Adductors": squats,
            "Hamstrings": hinges, "Erectors": hinges,
            "Calves": swings, "Hip flexors": swings,
            "Chest": scap, "Upper chest": scap, "Triceps": scap,
            "Front delts": arms, "Side delts": arms, "Rear delts": arms, "Traps": arms,
            "Lats": pullAparts, "Mid back": pullAparts, "Biceps": pullAparts, "Brachialis": pullAparts, "Forearms": pullAparts,
            "Core": catCow,
        ]
    }()

    /// The muscles a lift works, primary first. Falls back on the body's
    /// own idea of the lift for names the catalog doesn't know.
    static func muscles(for exerciseName: String) -> (primary: [String], secondary: [String]) {
        let known = ExerciseKnowledge.lookup(exerciseName)
        if !known.primary.isEmpty { return (known.primary, known.secondary) }
        switch Lift.match(exerciseName) {
        case .squat, .lunge: return (["Quads", "Glutes"], ["Hamstrings"])
        case .hinge, .swing: return (["Hamstrings", "Glutes"], ["Erectors"])
        case .benchPress, .pushups: return (["Chest"], ["Triceps", "Front delts"])
        case .overheadPress: return (["Front delts", "Side delts"], ["Triceps"])
        case .lateralRaise: return (["Side delts"], [])
        case .pullDown: return (["Lats"], ["Biceps"])
        case .curl: return (["Biceps"], [])
        case .tricepExtension, .skullCrusher: return (["Triceps"], [])
        case .plank: return (["Core"], [])
        default: return ([], [])
        }
    }

    /// Muscles ranked by how much work they did: primary counts 2 per set,
    /// secondary 1. Ties keep the order they were trained in.
    static func rankedMuscles(_ work: [(name: String, sets: Int)]) -> [String] {
        var score: [String: Int] = [:]
        var order: [String] = []
        for (name, sets) in work where sets > 0 {
            let m = muscles(for: name)
            for muscle in m.primary + m.secondary {
                if score[muscle] == nil { order.append(muscle) }
                score[muscle, default: 0] += sets * (m.primary.contains(muscle) ? 2 : 1)
            }
        }
        return order.enumerated()
            .sorted { (score[$0.element]!, -$0.offset) > (score[$1.element]!, -$1.offset) }
            .map(\.element)
    }

    /// The cooldown, most important first: the stretch for the muscle that
    /// worked hardest leads ("if you only do one…"). No repeats, at most 4.
    static func cooldown(for work: [(name: String, sets: Int)]) -> [Move] {
        unique(rankedMuscles(work).compactMap { stretchFor[$0] }, limit: 4)
    }

    /// A short warm-up for what's planned: three moves, about 90 seconds.
    static func warmup(for exercises: [String]) -> [Move] {
        let moves = unique(rankedMuscles(exercises.map { ($0, 1) }).compactMap { warmupFor[$0] }, limit: 3)
        return moves.isEmpty ? [warmupFor["Quads"]!, warmupFor["Front delts"]!, warmupFor["Core"]!] : moves
    }

    /// One or two stretches for a lift you just finished, to say on the
    /// way out of it.
    static func stretches(after exerciseName: String) -> [Move] {
        let m = muscles(for: exerciseName)
        return unique(m.primary.compactMap { stretchFor[$0] }, limit: 2)
    }

    private static func unique(_ moves: [Move], limit: Int) -> [Move] {
        var seen = Set<String>()
        return Array(moves.filter { seen.insert($0.name).inserted }.prefix(limit))
    }

    static func spoken(_ move: Move) -> String {
        "\(move.name), \(move.seconds) seconds\(move.eachSide ? " each side" : "")."
    }

    /// "That's squats done. Strong work. Later today, a couch stretch and a
    /// figure-four will save your legs tomorrow."
    static func closeOut(exerciseName: String, short: String, hype: Bool, sayStretches: Bool) -> String {
        let praise = hype
            ? ["Strong work.", "That was solid.", "Nailed it.", "Good stuff."]
            : ["Good work.", "Well done.", "Nice and steady."]
        var line = "That's \(short) done. \(praise.randomElement()!)"
        let moves = stretches(after: exerciseName)
        if sayStretches, !moves.isEmpty {
            let names = moves.map { $0.name.lowercased() }
            let list = names.count == 2 ? "a \(names[0]) and a \(names[1])" : "a \(names[0])"
            line += " Do \(list) after, so it's less sore tomorrow."
        }
        return line
    }

    // MARK: - Rest

    /// How a set went, from what you did or what you said.
    enum Effort: Equatable {
        case easy, right, hard
    }

    /// Rest for the next set. Heavy compounds 2 min, other compounds 90 s,
    /// small lifts and holds 60 s. A hard set (missed reps, or you said so)
    /// gets 30 s more; an easy one 15 s less.
    static func restSeconds(for exerciseName: String, effort: Effort?) -> Int {
        let motion = ExerciseMotion.match(exerciseName)
        let compound: Bool = {
            switch Lift.match(exerciseName) {
            case .squat, .hinge, .benchPress, .overheadPress, .pullDown, .lunge, .swing, .pushups: return true
            default: return false
            }
        }()
        var seconds = motion?.isHeavy == true ? 120 : compound ? 90 : 60
        switch effort {
        case .hard: seconds += 30
        case .easy: seconds -= 15
        default: break
        }
        return seconds
    }

    /// From reps done against the target.
    static func effort(reps: Int, target: Int) -> Effort? {
        guard target > 0 else { return nil }
        if reps < target - 1 { return .hard }
        if reps >= target + 2 { return .easy }
        return nil
    }

    /// "Ninety seconds", "two minutes", "two thirty".
    static func spokenDuration(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        let words = ["zero", "one", "two", "three", "four", "five"]
        if m == 0 { return "\(s) seconds" }
        if seconds == 90 { return "ninety seconds" }
        let minutes = m < words.count ? words[m] : "\(m)"
        if s == 0 { return m == 1 ? "a minute" : "\(minutes) minutes" }
        return "\(minutes) \(s)"
    }

    /// The first number in what you said: digits, or words up to ninety-nine
    /// ("forty five", "ninety", "two").
    static func number(in text: String) -> Int? {
        let t = text.lowercased().replacingOccurrences(of: "-", with: " ")
        if let digits = t.range(of: #"\d+"#, options: .regularExpression) { return Int(t[digits]) }
        let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
        let words = t.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        for (i, word) in words.enumerated() {
            if let ten = tens[word] {
                if i + 1 < words.count, let unit = WorkoutVoice.numberWords[words[i + 1]], unit < 10 { return ten + unit }
                return ten
            }
            if let n = WorkoutVoice.numberWords[word] { return n }
            if word == "a" || word == "an", i + 1 < words.count, words[i + 1].hasPrefix("minute") { return 1 }
        }
        return nil
    }

    /// "Thirty more", "add two minutes", "another minute" → seconds to add.
    static func restExtension(in text: String) -> Int? {
        let t = text.lowercased()
        guard t.range(of: #"\b(more|add|extend|longer|another|extra)\b"#, options: .regularExpression) != nil else { return nil }
        let minutes = t.range(of: #"\bminutes?\b"#, options: .regularExpression) != nil
        let n = number(in: t) ?? (minutes ? 1 : 30)
        let seconds = minutes ? n * 60 : n
        return (5...600).contains(seconds) ? seconds : nil
    }

    /// "Give me two minutes", "rest 90 seconds", "make it a minute" —
    /// the rest set to a length (not extended by it).
    static func restLength(in text: String) -> Int? {
        let t = text.lowercased()
        guard t.range(of: #"\b(give me|rest|make it|set it to|i need|need|let me have|i want)\b"#, options: .regularExpression) != nil,
              t.range(of: #"\b(more|extra|another|add)\b"#, options: .regularExpression) == nil else { return nil }
        let number: Int? = {
            if t.contains("a minute and a half") || t.contains("minute and a half") { return 90 }
            if t.range(of: #"\b(a|one) minute\b"#, options: .regularExpression) != nil { return 60 }
            guard let n = Self.number(in: t) else { return nil }
            if t.range(of: #"\bminutes?\b"#, options: .regularExpression) != nil { return n * 60 }
            if t.range(of: #"\b(seconds?|secs?)\b"#, options: .regularExpression) != nil { return n }
            return nil
        }()
        guard let number, (10...600).contains(number) else { return nil }
        return number
    }

    // MARK: - "I can't do this set"

    /// "I can't do this one", "can't finish", "that's too much", "I'm
    /// cooked" — you're telling Coach this set isn't happening as planned.
    static func saysCantDo(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        return t.range(of: #"\b(i can't|i cannot|can't do|cannot do|can't finish|couldn't (do|finish|get)|i'm not able|not gonna make it|that's too (much|heavy|hard)|too heavy|too hard|i'm (cooked|done for|spent|gassed|toast)|no more in me|i give up|failed (the|that|this) set|i failed)\b"#,
                       options: .regularExpression) != nil
            && t.range(of: #"\b(can't wait|can't believe|can't hear|can't see)\b"#, options: .regularExpression) == nil
    }

    enum CantDoReason: Equatable {
        /// Lower the weight (or the reps, for bodyweight) and go again.
        case tooHeavy
        /// Something hurts: stop this lift, offer a swap, remember it.
        case hurts(String)
        /// Just done for today: drop the rest of this lift's sets.
        case tired
    }

    /// What's wrong, from your answer to "too heavy, or does something hurt?"
    /// — or from the first thing you said, if it already says.
    static func cantDoReason(_ text: String) -> CantDoReason? {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        func says(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }
        if says(#"\b(hurts?|hurting|pain|painful|injur(y|ed)|tweak(ed)?|pull(ed)?|strain(ed)?|sore|twinge|pinch(ing)?|ache|aching|something's off|not right)\b"#)
            && !says(#"\b(doesn't|does not|nothing|no) (hurt|pain)\b"#) {
            return .hurts(bodyPart(in: t) ?? "")
        }
        if says(#"\b(heavy|weight|too much|lighter|drop it|strength|can't lift|form (is )?(breaking|going))\b"#) { return .tooHeavy }
        if says(#"\b(tired|exhausted|gassed|cooked|spent|done|fatigued|no energy|wiped|skip( it)?|move on|next)\b"#) { return .tired }
        return nil
    }

    /// Said unprompted, only clear pain counts: "my knee hurts", "that
    /// hurt my back", "I tweaked something" — not "pull-ups", "sore
    /// tomorrow", or "that's not right" about a count.
    static func saysPain(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        guard t.range(of: #"\b(no|not|doesn't|does not|didn't|nothing) (hurt|hurts|pain)"#, options: .regularExpression) == nil,
              !t.contains("tomorrow") else { return false }
        return t.range(of: #"\b(hurts|hurting|it hurt|that hurt|this hurt|painful|in pain|sharp pain|pain in|injured|tweaked|pulled (my|a|something)|strained|twinged|felt a pop|something popped)\b"#,
                       options: .regularExpression) != nil
            || (bodyPart(in: t) != nil && t.range(of: #"\b(pain|aches?|aching|pinch(ing)?|killing me)\b"#, options: .regularExpression) != nil)
    }

    static func bodyPart(in t: String) -> String? {
        let parts = ["lower back", "upper back", "back", "left knee", "right knee", "knee", "left shoulder", "right shoulder", "shoulder",
                     "elbow", "wrist", "hip", "neck", "ankle", "hamstring", "groin", "chest", "pec", "bicep", "tricep", "calf", "foot"]
        return parts.first { t.contains($0) }
    }

    /// Ten percent off, to the nearest 5 lb (2.5 under 20 lb).
    static func lighter(_ pounds: Double) -> Double {
        let step = pounds < 20 ? 2.5 : 5
        return max(0, ((pounds * 0.9) / step).rounded(.down) * step)
    }

    // MARK: - After a set

    /// What Coach says after a set beyond the fact of it. Only something
    /// worth hearing, never the same line twice in a workout, and nothing
    /// you've asked it to stop saying.
    struct SetAdvisor {
        enum Kind: String, CaseIterable {
            /// A form cue for the next set.
            case cue
            /// "How did that feel?"
            case question
            /// "You got 8 of 10 — want 5 lb off?"
            case shortfall
            /// A word of praise.
            case praise
        }

        private(set) var said: Set<String> = []
        /// Lifts already asked "how did that feel?" this workout.
        private var askedAbout: Set<String> = []
        private var setsSinceSpoke = 0
        /// Kinds you said to stop.
        var muted: Set<Kind> = []
        /// Kinds you said were helpful: offered more often.
        var liked: Set<Kind> = []

        struct Line: Equatable {
            let kind: Kind
            let text: String
            /// It's a question you can answer ("easy", "hard").
            var asks: Bool { kind == .question || kind == .shortfall }
            /// The cue it came from, so it's never picked again.
            var source: String? = nil
        }

        /// After set `set` of `targetSets` on a lift, with `reps` of `target`.
        mutating func line(exercise name: String, set: Int, targetSets: Int, reps: Int, target: Int,
                           timed: Bool, hype: Bool, tipsFull: Bool) -> Line? {
            let lastSet = set >= targetSets
            setsSinceSpoke += 1
            var options: [Line] = []

            if !timed, reps < target - 1, !muted.contains(.shortfall) {
                options.append(Line(kind: .shortfall, text: "\(reps) of \(target). Want me to take a little weight off for the next one?"))
            }
            if !lastSet, set == 1, !muted.contains(.question), !askedAbout.contains(name) {
                options.append(Line(kind: .question, text: ["How did that feel? Easy, good, or hard?",
                                                            "How was that one? Too light, about right, or tough?"].randomElement()!))
            }
            if !lastSet, tipsFull, !muted.contains(.cue) {
                let cues = ExerciseKnowledge.lookup(name).cues + (ExerciseMotion.match(name).map { [ExerciseLesson.cue(for: $0)] } ?? [])
                if let cue = cues.first(where: { !said.contains($0) }) {
                    options.append(Line(kind: .cue, text: "On the next set, " + Self.lowerFirst(cue).trimmingCharacters(in: .punctuationCharacters) + ".", source: cue))
                }
            }
            if !muted.contains(.praise) {
                let pool = hype
                    ? ["Let's go!", "Strong!", "That's it!", "Nice work!", "Big set.", "Clean reps."]
                    : ["Nice.", "Good set.", "Solid.", "Steady.", "That's the one."]
                if let praise = pool.shuffled().first(where: { !said.contains($0) }) {
                    options.append(Line(kind: .praise, text: praise))
                }
            }
            // A shortfall always gets said; anything you liked comes next;
            // otherwise a cue or question, and only every other set or so,
            // so there's room to just breathe.
            let pick = options.first { $0.kind == .shortfall }
                ?? options.first { liked.contains($0.kind) }
                ?? (setsSinceSpoke >= 2 || set == 1 ? options.first { $0.kind == .question || $0.kind == .cue } : nil)
                ?? (lastSet || Bool.random() ? options.first { $0.kind == .praise } : nil)
            if let pick {
                said.insert(pick.text)
                if let source = pick.source { said.insert(source) }
                if pick.kind == .question { askedAbout.insert(name) }
                setsSinceSpoke = 0
            }
            return pick
        }

        private static func lowerFirst(_ s: String) -> String {
            guard let first = s.first else { return s }
            return first.lowercased() + s.dropFirst()
        }
    }

    /// Your answer to "how did that feel?"
    static func effortAnswer(_ text: String) -> Effort? {
        let t = text.lowercased()
        guard t.split(separator: " ").count <= 10 else { return nil }
        if t.range(of: #"\b(easy|light|too light|easier|nothing|piece of cake|could do more|more weight)\b"#, options: .regularExpression) != nil { return .easy }
        if t.range(of: #"\b(hard|tough|heavy|brutal|killer|struggle|struggled|difficult|rough)\b"#, options: .regularExpression) != nil { return .hard }
        if t.range(of: #"\b(good|fine|right|okay|ok|alright|solid|perfect|great)\b"#, options: .regularExpression) != nil { return .right }
        return nil
    }

    // MARK: - Tuning: "stop telling me that", "that's helpful"

    enum Tuning: Equatable {
        case stop
        case more
    }

    /// Feedback on what Coach just said.
    static func tuning(in text: String) -> Tuning? {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        guard t.split(separator: " ").count <= 12 else { return nil }
        if t.range(of: #"\b(stop (telling|saying|asking) me (that|this)|stop saying that|don't (tell|ask) me that|don't say that|quit (saying|asking) that|i don't need (that|to hear that)|enough of that|you keep saying that|stop asking)\b"#,
                   options: .regularExpression) != nil { return .stop }
        if t.range(of: #"\b(that's (really )?helpful|that helps|that helped|that's useful|good (tip|call|advice)|keep (telling|saying) me that|i like (that|those)|more of that)\b"#,
                   options: .regularExpression) != nil { return .more }
        return nil
    }

    /// A memory fact id for a tuning, so the phone can find it again.
    static func tuningFactId(_ tuning: Tuning, _ kind: SetAdvisor.Kind) -> String {
        "coach-tune-\(tuning == .stop ? "mute" : "like")-\(kind.rawValue)"
    }

    static func tuningFactContent(_ tuning: Tuning, _ kind: SetAdvisor.Kind, example: String) -> String {
        let what: String = {
            switch kind {
            case .cue: return "form cues between sets"
            case .question: return "being asked how a set felt"
            case .shortfall: return "offers to drop the weight after a missed rep"
            case .praise: return "praise after every set"
            }
        }()
        return tuning == .stop
            ? "Doesn't want \(what) (said \"stop telling me that\" after: \"\(example.prefix(80))\")."
            : "Finds \(what) helpful — do more of it (after: \"\(example.prefix(80))\")."
    }

    /// Reads tunings back from memory fact ids.
    static func tunings(fromFactIds ids: [String]) -> (muted: Set<SetAdvisor.Kind>, liked: Set<SetAdvisor.Kind>) {
        var muted = Set<SetAdvisor.Kind>(), liked = Set<SetAdvisor.Kind>()
        for id in ids {
            for kind in SetAdvisor.Kind.allCases {
                if id == tuningFactId(.stop, kind) { muted.insert(kind) }
                if id == tuningFactId(.more, kind) { liked.insert(kind) }
            }
        }
        return (muted, liked)
    }
}

extension String {
    /// "two minutes" → "Two minutes".
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension CoachVoiceOption {
    /// What you asked for when you asked Coach to sound different.
    enum VoiceRequest: Equatable {
        case to(String)
        /// An accent or language there's no voice for yet.
        case unavailable(String)
    }

    /// "Can you change your voice to a woman's?", "sound calmer", "use a
    /// male voice", "different voice" → the voice to switch to.
    static func request(in text: String, current: String) -> VoiceRequest? {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        func says(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }
        guard t.split(separator: " ").count <= 16,
              says(#"\b(voice|sound|sounding|talk like|speak like)\b"#),
              says(#"\b(change|switch|swap|use|try|different|another|can you|could you|make|want|prefer|rather|sound (more|less|like)|new)\b"#)
        else { return nil }
        if let accent = ["british", "english accent", "australian", "aussie", "irish", "scottish", "indian", "spanish", "french", "german"]
            .first(where: { t.contains($0) }) {
            return .unavailable(accent)
        }
        let now = voice(named: current)
        var female = now.female
        var feel = now.feel
        var changed = false
        if says(#"\b(woman|women|woman's|female|girl|lady|her)\b"#) { female = true; changed = true }
        if says(#"\b(man|men|man's|male|guy|dude|him|bloke)\b"#) { female = false; changed = true }
        if says(#"\b(warm|warmer|friendly|friendlier|kind|kinder|nice)\b"#) { feel = .warm; changed = true }
        if says(#"\b(upbeat|energetic|excited|hype|hyped|pumped|enthusiastic|peppier|peppy)\b"#) { feel = .upbeat; changed = true }
        if says(#"\b(firm|firmer|strict|stricter|serious|stern|tough|tougher|deeper|drill)\b"#) {
            feel = .firm
            if says(#"\bdeeper\b"#), !says(#"\b(woman|female|girl|lady)\b"#) { female = false }
            changed = true
        }
        if says(#"\b(calm|calmer|soft|softer|gentle|gentler|relaxed|chill|quieter|soothing)\b"#) { feel = .calm; changed = true }
        if !changed {
            // "A different voice": the next one, same kind.
            guard says(#"\b(different|another|new|other|change|switch)\b"#) else { return nil }
            let same = all.filter { $0.female == now.female }
            let i = same.firstIndex { $0.name == now.name } ?? 0
            return .to(same[(i + 1) % same.count].name)
        }
        let name = name(female: female, feel: feel)
        return .to(name)
    }
}
