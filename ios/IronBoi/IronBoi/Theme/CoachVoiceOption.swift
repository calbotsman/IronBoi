import Foundation

/// The coach's voice: female or male, and how it sounds. The same eight as
/// the server's allowlist (COACH_VOICES in functions/src/voice/speech.ts),
/// so live voice and spoken replies match.
enum CoachVoiceOption {
    static let storageKey = "coachVoiceName"
    /// Set once you pick a voice yourself; until then the coaching style you
    /// choose picks the feel.
    static let chosenKey = "coachVoiceChosen"
    static let defaultName = "Sulafat"

    enum Feel: String, CaseIterable {
        case warm, upbeat, firm, calm
        var label: String { rawValue.capitalized }
        /// What the coach says when you try the voice.
        var sample: String {
            switch self {
            case .warm: return "Hey, I'm your coach. We'll build this together."
            case .upbeat: return "Let's go! Two more good sets and you're done."
            case .firm: return "Brace, breathe, drive. That's a good rep."
            case .calm: return "Nice and steady. Take all the time you need."
            }
        }
    }

    struct Voice { let name: String; let female: Bool; let feel: Feel }

    static let all: [Voice] = [
        Voice(name: "Sulafat", female: true, feel: .warm),
        Voice(name: "Laomedeia", female: true, feel: .upbeat),
        Voice(name: "Kore", female: true, feel: .firm),
        Voice(name: "Achernar", female: true, feel: .calm),
        Voice(name: "Achird", female: false, feel: .warm),
        Voice(name: "Puck", female: false, feel: .upbeat),
        Voice(name: "Orus", female: false, feel: .firm),
        Voice(name: "Algieba", female: false, feel: .calm),
    ]

    /// What each voice says when you try it — its own line, so switching
    /// voices never sounds like the same thing again.
    static func sample(for name: String) -> String {
        switch name {
        case "Sulafat": return "Hey, I'm your coach. We'll build this together, one session at a time."
        case "Laomedeia": return "Let's go! Two more good sets and you're done for today."
        case "Kore": return "Brace, breathe, drive. That's what a good rep looks like."
        case "Achernar": return "Nice and steady. Take all the time you need between sets."
        case "Achird": return "Good to meet you. I'll keep it simple and keep you moving."
        case "Puck": return "Alright! Let's make today a good one. You ready?"
        case "Orus": return "Feet planted. Chest up. Now push. No shortcuts."
        case "Algieba": return "Breathe out on the effort. Slow on the way down. You've got this."
        default: return voice(named: name).feel.sample
        }
    }

    static func voice(named name: String) -> Voice {
        all.first { $0.name == name } ?? all[0]
    }

    static func name(female: Bool, feel: Feel) -> String {
        all.first { $0.female == female && $0.feel == feel }?.name ?? defaultName
    }

    /// The feel a coaching style suggests.
    static func feel(tone: CoachingStyle.Tone, tips: CoachingStyle.Tips) -> Feel {
        if tone == .hype { return .upbeat }
        return tips == .full ? .warm : .firm
    }

    static var current: String {
        UserDefaults.standard.string(forKey: storageKey) ?? defaultName
    }

    /// "Warm · female", for the onboarding plan.
    static func label(_ name: String) -> String {
        let voice = voice(named: name)
        return "\(voice.feel.label) · \(voice.female ? "female" : "male") voice"
    }
}
