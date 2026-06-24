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
        /// #FCF4E8 — the paper
        static let cream = Color(red: 0xFC / 255, green: 0xF4 / 255, blue: 0xE8 / 255)
        /// #F7ECDA — a sheet raised on the paper
        static let creamElevated = Color(red: 0xF7 / 255, green: 0xEC / 255, blue: 0xDA / 255)
        /// #1A1410
        static let ink = Color(red: 0x1A / 255, green: 0x14 / 255, blue: 0x10 / 255)
        /// #C4892A — "Coach acting on you"
        static let ochre = Color(red: 0xC4 / 255, green: 0x89 / 255, blue: 0x2A / 255)
        /// #E8B858
        static let ochreLight = Color(red: 0xE8 / 255, green: 0xB8 / 255, blue: 0x58 / 255)
        /// #A04030 — the coach's red pen; destructive actions
        static let brick = Color(red: 0xA0 / 255, green: 0x40 / 255, blue: 0x30 / 255)
        /// #C06040 — caution, still in the red-pen family
        static let brickLight = Color(red: 0xC0 / 255, green: 0x60 / 255, blue: 0x40 / 255)
        /// #5A8C6E — success on paper; never iOS system green
        static let sage = Color(red: 0x5A / 255, green: 0x8C / 255, blue: 0x6E / 255)
        /// rgba(26,20,16,0.06)
        static let hairline = ink.opacity(0.06)
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
    static let onAction = MyoTheme.Colors.cream
    static let hairline = MyoTheme.Colors.hairline
    static let redPen = MyoTheme.Colors.brick
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
