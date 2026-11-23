import SwiftUI

/// The Watch in MYO's own look: the paper you picked on the phone, its ink,
/// and the coach's colour. The hexes match `Paper.all` and `MyoTheme.Colors`
/// on the phone (the Watch target doesn't compile the phone's theme).
struct WatchLook: Equatable {
    var paper: Color
    var raised: Color
    var ink: Color
    var isDark: Bool
    var coach: Color

    static let ochre = Color(watchHex: "C4892A")
    static let brick = Color(watchHex: "A04030")
    static let brickLight = Color(watchHex: "C06040")
    static let sage = Color(watchHex: "5A8C6E")

    private static let papers: [String: (base: String, raised: String, ink: String, dark: Bool)] = [
        "cream": ("FCF4E8", "F7ECDA", "1A1410", false),
        "linen": ("F4F3EF", "EAE8E2", "1B2230", false),
        "blush": ("FAEDE9", "F3E0DA", "2B1620", false),
        "sage": ("EFF2E8", "E3E9DA", "17241B", false),
        "sand": ("EFE3CF", "E6D5BA", "2A1D10", false),
        "night": ("1D1916", "29241F", "F3EADC", true),
    ]

    /// `alwaysOn`: wrist down. The Watch dims to the Night paper, as watchOS asks.
    static func from(paperId: String?, coachHex: String?, alwaysOn: Bool = false) -> WatchLook {
        let p = papers[alwaysOn ? "night" : (paperId ?? "cream")] ?? papers["cream"]!
        return WatchLook(paper: Color(watchHex: p.base), raised: Color(watchHex: p.raised), ink: Color(watchHex: p.ink),
                         isDark: p.dark, coach: Color(watchHex: coachHex ?? "F6A609"))
    }

    var secondary: Color { ink.opacity(0.7) }
    var tertiary: Color { ink.opacity(0.5) }
    var hairline: Color { ink.opacity(isDark ? 0.14 : 0.08) }
}

extension Color {
    init(watchHex hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(s, radix: 16) ?? 0xF6A609
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
