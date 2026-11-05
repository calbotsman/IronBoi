import Foundation

/// How Coach's voice sits with your own music (Spotify, Apple Music…).
/// Three settings, all remembered:
/// - voice on or off — off is captions mode: the mic still listens, counts
///   and answers, but the answer is on screen and your music is untouched;
/// - Coach's level against the music;
/// - how much the music dips.
enum CoachMix {
    /// Shared with the older mute toggle, so both stay in step.
    static let voiceOnKey = "coachSpeaksReplies"
    static let voiceLevelKey = "coachVoiceLevel"
    static let musicDipKey = "coachMusicDip"

    static let defaultVoiceLevel = 0.75

    enum MusicDip: String, CaseIterable, Identifiable {
        /// Your music is never touched; Coach plays at your level over it.
        case none
        /// Music stays up; Coach is lifted and compressed so it cuts through.
        case light
        /// iOS lowers your music while MYO has the mic and speaker.
        case full

        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: "Off"
            case .light: "Light"
            case .full: "Full"
            }
        }
        var detail: String {
            switch self {
            case .none: "Your music stays as it is. Coach plays over it at the level above."
            case .light: "Your music stays up; Coach's voice is lifted so it cuts through."
            case .full: "Your music drops while the mic is on, so Coach is easy to hear."
            }
        }
    }

    static let defaultDip = MusicDip.light

    static var voiceOn: Bool {
        UserDefaults.standard.object(forKey: voiceOnKey) as? Bool ?? true
    }

    /// 0…1, from the slider.
    static var voiceLevel: Double {
        UserDefaults.standard.object(forKey: voiceLevelKey) as? Double ?? defaultVoiceLevel
    }

    static var dip: MusicDip {
        UserDefaults.standard.string(forKey: musicDipKey).flatMap(MusicDip.init(rawValue:)) ?? defaultDip
    }

    /// The slider's 0…1 as decibels on Coach's voice: -18 dB at the bottom,
    /// unchanged at the default, +6 dB at the top. A light dip adds 6 dB;
    /// a limiter after it keeps the lift from clipping.
    static func voiceGainDB(level: Double = voiceLevel, dip: MusicDip = dip) -> Float {
        let base = -18 + 24 * min(1, max(0, level))
        let lift: Double = dip == .light ? 6 : 0
        return Float(base + lift)
    }
}
