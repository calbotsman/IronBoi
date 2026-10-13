import Observation
import SwiftUI

/// MyoTheme v2 — "The Living Dossier".
/// Source of truth: docs/design/myo-living-dossier-art-direction.md.
///
/// Structure: private-ish PRIMITIVES (the raw palette) live under
/// `MyoTheme.Colors`; views should reach for the SEMANTIC ROLES under
/// `MyoColor` (Surface / Text / Action / State) so a screen never names a
/// hex or an ad-hoc opacity again. Type ships through `MyoFont` + `.myoStyle`.
enum MyoTheme {
    /// Raw palette. Prefer the semantic `MyoColor` roles in views; reach for a
    /// primitive only when defining a new role.
    enum Colors {
        // The paper, the type and the shadows come from the paper you picked
        // (`Paper`, on the You screen) — Cream unless you chose another.
        // Reading them inside a view's body subscribes it, so a new paper
        // repaints every screen at once.
        /// The paper (Cream: #FCF4E8)
        static var cream: Color { PaperStore.shared.paper.base }
        /// A sheet raised on the paper (Cream: #F7ECDA)
        static var creamElevated: Color { PaperStore.shared.paper.raised }
        /// The type (Cream: #1A1410)
        static var ink: Color { PaperStore.shared.paper.ink }
        /// What shadows are cast in.
        static var shadow: Color { PaperStore.shared.paper.shadow }
        /// #C4892A — "Coach acting on you"
        static let ochre = Color(red: 0xC4 / 255, green: 0x89 / 255, blue: 0x2A / 255)
        /// #E8B858
        static let ochreLight = Color(red: 0xE8 / 255, green: 0xB8 / 255, blue: 0x58 / 255)
        /// #A04030 — the coach's red pen; destructive actions
        static let brick = Color(red: 0xA0 / 255, green: 0x40 / 255, blue: 0x30 / 255)
        /// #C06040 — caution, still in the red-pen family
        static let brickLight = Color(red: 0xC0 / 255, green: 0x60 / 255, blue: 0x40 / 255)
        /// #F6A609 — the coach's body (orb-lab's agent amber). The warm half
        /// of the pair; you are the cool half, blue by default.
        static let coachAmber = Color(red: 0xF6 / 255, green: 0xA6 / 255, blue: 0x09 / 255)
        /// #5A8C6E — success on paper; never iOS system green
        static let sage = Color(red: 0x5A / 255, green: 0x8C / 255, blue: 0x6E / 255)
        /// Ink at 6%
        static var hairline: Color { ink.opacity(PaperStore.shared.paper.isDark ? 0.12 : 0.06) }
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Radius {
        static let card: CGFloat = 14
    }

    enum Typography {
        /// Legacy alias — prefer `MyoFont.label`. Kept so existing call sites
        /// (`.font(MyoTheme.Typography.monoLabel)`) keep compiling during the
        /// v1→v2 type migration.
        static let monoLabel = MyoFont.label.font
    }

    enum Motion {
        /// The only sanctioned transition: a 200ms tonal fade ("held breath").
        static let fade = Animation.easeInOut(duration: 0.2)
    }
}

/// Semantic color roles. Views use THESE, not primitives — so hierarchy and
/// state are consistent and the inline `ink.opacity(...)` drift is gone.
enum MyoColor {
    enum Surface {
        case base, elevated, pressed, selected
        var color: Color {
            switch self {
            case .base: return MyoTheme.Colors.cream
            case .elevated: return MyoTheme.Colors.creamElevated
            case .pressed: return MyoTheme.Colors.ochre.opacity(0.10)
            case .selected: return MyoTheme.Colors.ochreLight
            }
        }
    }

    enum Text {
        case primary, secondary, tertiary, disabled
        var color: Color {
            switch self {
            case .primary: return MyoTheme.Colors.ink
            case .secondary: return MyoTheme.Colors.ink.opacity(0.7)
            case .tertiary: return MyoTheme.Colors.ink.opacity(0.5)
            case .disabled: return MyoTheme.Colors.ink.opacity(0.35)
            }
        }
    }

    enum Action {
        case primary, critical
        var color: Color {
            switch self {
            case .primary: return MyoTheme.Colors.ochre
            case .critical: return MyoTheme.Colors.brick
            }
        }
    }

    enum State {
        case success, warning, danger
        var color: Color {
            switch self {
            case .success: return MyoTheme.Colors.sage
            case .warning: return MyoTheme.Colors.brickLight
            case .danger: return MyoTheme.Colors.brick
            }
        }
    }

    /// The cream the app sits on, as a shorthand for `Surface.base.color`.
    static var onAction: Color { MyoTheme.Colors.cream }
    static var hairline: Color { MyoTheme.Colors.hairline }
    static var redPen: Color { PaperStore.shared.paper.isDark ? MyoTheme.Colors.brickLight : MyoTheme.Colors.brick }
}

/// The type ramp. Two voices: General Sans (human) and SF Mono (the coach's
/// annotation). Mono is a detail voice — labels + numerics only, never body.
///
/// v2 ships on the SYSTEM face via Dynamic-Type text styles (so it scales for
/// accessibility). When General Sans is bundled, swap each case to
/// `.custom("GeneralSans-…", size:, relativeTo:)` — call sites don't change.
enum MyoFont {
    case display   // hero / screen title
    case title     // section + card titles
    case body      // main text, chat
    case detail    // captions, hints
    case numeric   // reps, sets, weight — mono ledger
    case label     // UPPERCASE section dividers, marginalia — mono

    var font: Font {
        switch self {
        case .display: return .system(.largeTitle, design: .default).weight(.bold)
        case .title: return .system(.title2, design: .default).weight(.medium)
        case .body: return .system(.body, design: .default)
        case .detail: return .system(.caption, design: .default).weight(.light)
        case .numeric: return .system(.subheadline, design: .monospaced)
        case .label: return .system(.caption, design: .monospaced).weight(.medium)
        }
    }
}

extension View {
    /// Apply a MyoFont ramp role: `Text("Your goals").myoStyle(.title)`.
    func myoStyle(_ role: MyoFont) -> some View {
        font(role.font)
    }
}

/// Standard Dossier card chrome: elevated cream sheet, hairline border,
/// radius 14. No drop shadow — depth is paper + ink only.
struct MyoCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(MyoColor.Surface.elevated.color)
            .overlay(
                RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous)
                    .stroke(MyoColor.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))
    }
}

extension View {
    func myoCard() -> some View {
        modifier(MyoCardModifier())
    }
}

/// Your colour in the conversation — what your words turn the coach's body
/// as they arrive. Yours to choose; Coach stays warm ochre. Stored on this
/// device as a hex string.
enum YouColor {
    static let storageKey = "youColorHex"
    static let defaultHex = "4285F4"

    /// Cool presets: they contrast with the coach's warm ochre. The custom
    /// picker allows anything, warm included.
    static let presets: [(name: String, hex: String)] = [
        ("Blue", "4285F4"),
        ("Sky", "2BA6E8"),
        ("Teal", "12A5A0"),
        ("Indigo", "5B5BF0"),
        ("Violet", "9B5CF0"),
    ]
}

/// The coach's own color — its body. Amber unless you pick another: any hue
/// on the ribbon, from soft to vivid. Stored as a hex string like YouColor.
enum CoachColor {
    static let storageKey = "coachColorHex"
    static let defaultHex = "F6A609"

    /// Named places along the ribbon (hue in degrees); the picker shows the
    /// nearest one as you drag.
    static let stops: [(hue: Double, name: String)] = [
        (0, "Cherry"), (14, "Ember"), (26, "Tangerine"), (38, "Amber"), (48, "Marigold"),
        (58, "Lemon"), (78, "Lime"), (120, "Fern"), (155, "Jade"), (180, "Lagoon"),
        (200, "Sky"), (220, "Cobalt"), (245, "Indigo"), (268, "Violet"), (290, "Orchid"),
        (315, "Magenta"), (332, "Rose"), (348, "Raspberry"),
    ]

    /// Hue 0…1 and vivid 0…1 (soft…full) to a hex. Vivid 1 at amber's hue is
    /// the default amber, so the ribbon and the brand agree.
    static func hex(hue: Double, vivid: Double) -> String {
        let v = min(max(vivid, 0), 1)
        let ui = UIColor(hue: CGFloat(hue.truncatingRemainder(dividingBy: 1)),
                         saturation: CGFloat(0.42 + 0.54 * v),
                         brightness: CGFloat(0.84 + 0.12 * v), alpha: 1)
        return Color(uiColor: ui).hexString
    }

    static func color(hue: Double, vivid: Double) -> Color {
        Color(hex: hex(hue: hue, vivid: vivid))
    }

    /// Where a stored hex sits on the ribbon.
    static func position(of hex: String) -> (hue: Double, vivid: Double) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(Color(hex: hex)).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), min(max((Double(s) - 0.42) / 0.54, 0), 1))
    }

    static func name(hue: Double) -> String {
        let degrees = hue * 360
        func distance(_ stop: Double) -> Double {
            let d = abs(stop - degrees).truncatingRemainder(dividingBy: 360)
            return min(d, 360 - d)
        }
        return stops.min { distance($0.hue) < distance($1.hue) }?.name ?? "Amber"
    }
}

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

/// The paper the whole app is printed on: background, type and shadow, in
/// one choice. A handful of good ones rather than a colour mixer.
struct Paper: Identifiable, Equatable {
    let id: String
    let name: String
    let base: Color
    let raised: Color
    let ink: Color
    let shadow: Color
    var isDark = false

    static let storageKey = "paperName"

    static let all: [Paper] = [
        Paper(id: "cream", name: "Cream", base: Color(hex: "FCF4E8"), raised: Color(hex: "F7ECDA"),
              ink: Color(hex: "1A1410"), shadow: Color(hex: "1A1410")),
        Paper(id: "linen", name: "Linen", base: Color(hex: "F4F3EF"), raised: Color(hex: "EAE8E2"),
              ink: Color(hex: "1B2230"), shadow: Color(hex: "1B2230")),
        Paper(id: "blush", name: "Blush", base: Color(hex: "FAEDE9"), raised: Color(hex: "F3E0DA"),
              ink: Color(hex: "2B1620"), shadow: Color(hex: "5A2A38")),
        Paper(id: "sage", name: "Sage", base: Color(hex: "EFF2E8"), raised: Color(hex: "E3E9DA"),
              ink: Color(hex: "17241B"), shadow: Color(hex: "21402C")),
        Paper(id: "sand", name: "Sand", base: Color(hex: "EFE3CF"), raised: Color(hex: "E6D5BA"),
              ink: Color(hex: "2A1D10"), shadow: Color(hex: "4A3418")),
        Paper(id: "night", name: "Night", base: Color(hex: "1D1916"), raised: Color(hex: "29241F"),
              ink: Color(hex: "F3EADC"), shadow: Color(hex: "000000"), isDark: true),
    ]

    static func named(_ id: String?) -> Paper {
        all.first { $0.id == id } ?? all[0]
    }
}

/// The paper in use. Observable, so every view that reads a paper colour
/// repaints when it changes.
@Observable
final class PaperStore {
    static let shared = PaperStore()

    var paper: Paper {
        didSet { UserDefaults.standard.set(paper.id, forKey: Paper.storageKey) }
    }

    private init() {
        paper = Paper.named(UserDefaults.standard.string(forKey: Paper.storageKey))
    }
}

extension Color {
    /// From "RRGGBB" (a leading # is fine). Falls back to the default blue.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(cleaned, radix: 16) ?? UInt32(YouColor.defaultHex, radix: 16)!
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// "RRGGBB" in sRGB.
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let clamp = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }
}
