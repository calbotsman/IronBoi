import Foundation

/// How Coach teaches a lift: a few short spoken lines, each with what the
/// body does while it's said — stepping into the position being described
/// and holding it, then "like this" and a couple of real reps.
enum ExerciseLesson {
    struct Beat {
        let line: String
        let body: BodyCue
    }

    enum BodyCue: Equatable {
        /// Ease into this point of the rep (0 = start, 1 = end) and hold.
        case hold(Float)
        /// Show full reps.
        case reps
    }

    /// The full walk-through. Positions: 0 is where a rep starts, 1 where it
    /// turns (the bottom of a squat, the top of a curl).
    static func beats(for lift: Lift) -> [Beat] {
        switch lift {
        case .squat:
            return [
                Beat(line: "Squats need a straight back. Chest up.", body: .hold(0)),
                Beat(line: "Sit your hips back, like there's a chair behind you.", body: .hold(0.55)),
                Beat(line: "Knees out over your toes, heels down.", body: .hold(1)),
                Beat(line: "Then drive up through your heels. Like this.", body: .reps),
            ]
        case .lunge:
            return [
                Beat(line: "Lunges. Long stride, chest tall.", body: .hold(0)),
                Beat(line: "Drop straight down, back knee toward the floor.", body: .hold(0.6)),
                Beat(line: "Front knee over your ankle, not past your toes.", body: .hold(1)),
                Beat(line: "Push through your front heel to come up. Like this.", body: .reps),
            ]
        case .hinge:
            return [
                Beat(line: "Deadlifts are all hips. Back flat the whole way.", body: .hold(0)),
                Beat(line: "Push your hips back and let the weight slide down your legs.", body: .hold(0.7)),
                Beat(line: "Feel the stretch in your hamstrings.", body: .hold(1)),
                Beat(line: "Then stand tall and squeeze. Like this.", body: .reps),
            ]
        case .swing:
            return [
                Beat(line: "Swings come from your hips, not your arms.", body: .hold(0)),
                Beat(line: "Hike it back between your legs.", body: .hold(1)),
                Beat(line: "Then snap your hips forward and let it float. Like this.", body: .reps),
            ]
        case .benchPress:
            return [
                Beat(line: "Bench press. Shoulder blades pinched, feet planted.", body: .hold(0)),
                Beat(line: "Lower it to your chest, slow and controlled.", body: .hold(1)),
                Beat(line: "Then press it straight back up. Like this.", body: .reps),
            ]
        case .overheadPress:
            return [
                Beat(line: "Overhead press. Squeeze your glutes and brace.", body: .hold(0)),
                Beat(line: "Press straight up, head through at the top.", body: .hold(1)),
                Beat(line: "Lower it back to your shoulders. Like this.", body: .reps),
            ]
        case .curl:
            return [
                Beat(line: "Curls. Elbows pinned to your sides.", body: .hold(0)),
                Beat(line: "Curl up and squeeze at the top.", body: .hold(1)),
                Beat(line: "Lower it slow, no swinging. Like this.", body: .reps),
            ]
        case .lateralRaise:
            return [
                Beat(line: "Lateral raises. A soft bend in your elbows.", body: .hold(0)),
                Beat(line: "Raise out to the side, up to shoulder height. No higher.", body: .hold(1)),
                Beat(line: "Control it down. Like this.", body: .reps),
            ]
        case .tricepExtension:
            return [
                Beat(line: "Overhead extensions. Elbows point up and stay by your head.", body: .hold(0)),
                Beat(line: "Straighten all the way up.", body: .hold(1)),
                Beat(line: "Then lower it behind your head. Like this.", body: .reps),
            ]
        case .pullDown:
            return [
                Beat(line: "Chest up. Pull with your back, not your arms.", body: .hold(0)),
                Beat(line: "Bring it down to your upper chest.", body: .hold(1)),
                Beat(line: "Let it back up slow. Like this.", body: .reps),
            ]
        case .skullCrusher:
            return [
                Beat(line: "Skull crushers. Upper arms stay still.", body: .hold(0)),
                Beat(line: "Bend at the elbows and lower toward your forehead.", body: .hold(1)),
                Beat(line: "Then extend back up. Like this.", body: .reps),
            ]
        case .pushups:
            return [
                Beat(line: "Push-ups. One straight line, head to heels.", body: .hold(0)),
                Beat(line: "Lower your chest to the floor, elbows tucked.", body: .hold(1)),
                Beat(line: "Then push the floor away. Like this.", body: .reps),
            ]
        case .plank:
            return [
                Beat(line: "Plank. Elbows under shoulders, squeeze everything, and breathe.", body: .hold(0)),
            ]
        }
    }

    /// One short reminder for between sets.
    static func cue(for lift: Lift) -> String {
        let cues: [String]
        switch lift {
        case .squat: cues = ["Chest up.", "Sit back into it.", "Drive through your heels.", "Knees out."]
        case .lunge: cues = ["Chest tall.", "Straight down, not forward.", "Drive through the front heel."]
        case .hinge: cues = ["Back flat.", "Hips back, not down.", "Squeeze at the top."]
        case .swing: cues = ["Snap the hips.", "Let it float.", "Arms are just ropes."]
        case .benchPress: cues = ["Feet planted.", "Touch your chest, then drive.", "Shoulder blades pinched."]
        case .overheadPress: cues = ["Squeeze your glutes.", "Head through at the top.", "Brace your core."]
        case .curl: cues = ["Elbows pinned.", "Slow on the way down.", "No swinging."]
        case .lateralRaise: cues = ["Lead with your elbows.", "Shoulder height, no higher.", "Control it down."]
        case .tricepExtension: cues = ["Elbows in.", "All the way up."]
        case .pullDown: cues = ["Chest up.", "Pull with your back."]
        case .skullCrusher: cues = ["Upper arms still.", "Slow to the forehead."]
        case .pushups: cues = ["Straight line.", "Elbows tucked.", "Push the floor away."]
        case .plank: cues = ["Breathe.", "Squeeze everything."]
        }
        return cues.randomElement()!
    }
}

/// How much Coach says and how it says it, set by what you tell it:
/// "stop talking", "no tips", "coach me", "calm down", "hype me up".
/// Remembered across workouts.
enum CoachingStyle {
    enum Tips: String {
        /// Teaches each lift and cues between sets.
        case full
        /// Names the lift and logs sets; no teaching.
        case brief
        /// Says nothing unless you ask; sets are a buzz, not a voice.
        case quiet
    }

    enum Tone: String {
        case hype, calm
    }

    static let tipsKey = "coachTips"
    static let toneKey = "coachTone"

    enum Change: Equatable {
        case tips(Tips)
        case tone(Tone)
        /// "Stop" / "enough" while Coach is talking: stop this, change nothing.
        case hush
    }

    /// What you asked for, if what you said was about how Coach talks.
    /// Only short asides count — a long message that happens to contain
    /// "stop" is a message, not a request to be quiet.
    /// `coachJustSpoke`: a bare "stop" only means "stop talking" when
    /// there's talking to stop — otherwise it's a song lyric, or about the set.
    static func change(in text: String, coachJustSpoke: Bool) -> Change? {
        let t = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !t.isEmpty, t.split(separator: " ").count <= 10 else { return nil }
        func says(_ pattern: String) -> Bool { t.range(of: pattern, options: .regularExpression) != nil }

        if ["stop", "stop it", "okay stop", "ok stop", "quiet", "shh", "shush", "hush", "enough", "okay okay", "got it"].contains(t) {
            return coachJustSpoke ? .hush : nil
        }
        if says(#"\b(stop talking|shut up|be quiet|quiet down|no talking|stop coaching|just count|enough talking|zip it)\b"#) {
            return .tips(.quiet)
        }
        if says(#"\b(no (more )?tips|don't need (the )?tips|skip the tips|stop (with )?the tips|i know (how|what i'm doing)|less talking|talk less|keep it short|too much talking|fewer tips|don't want (to hear )?(the )?tips)\b"#) {
            return .tips(.brief)
        }
        if says(#"\b(give me tips|more tips|coach me|you can talk( again)?|talk to me|tips (back )?on|i want (the )?tips)\b"#) {
            return .tips(.full)
        }
        if says(#"\b(calm down|chill( out)?|tone it down|less hype|too loud|too much energy|relax|take it easy)\b"#) {
            return .tone(.calm)
        }
        if says(#"\b(hype me( up)?|pump me up|fire me up|get me fired up|more energy|more hype|motivate me|let's get hyped)\b"#) {
            return .tone(.hype)
        }
        return nil
    }

    /// Coach's reply to the change: short, and nothing at all for quiet.
    static func acknowledgement(_ change: Change) -> String? {
        switch change {
        case .tips(.quiet), .hush: return nil
        case .tips(.brief): return "Got it. I'll keep it short."
        case .tips(.full): return "You got it. I'll coach you through it."
        case .tone(.calm): return "Got it."
        case .tone(.hype): return "Let's go!"
        }
    }

    /// "Show me how", "how do I do this", "what's the form" — mid-workout,
    /// that's a request to walk through the current lift again.
    static func asksForDemo(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        return t.range(of: #"\b(show me( how)?|how do i do (this|it|these|that)|what's the form|demonstrate|demo it|teach me)\b"#,
                       options: .regularExpression) != nil
    }

    /// A word after a set, in your chosen tone.
    static func praise(_ tone: Tone) -> String {
        switch tone {
        case .hype: return ["Let's go!", "Strong!", "That's it!", "Nice work!"].randomElement()!
        case .calm: return ["Nice.", "Good set.", "Solid."].randomElement()!
        }
    }
}
