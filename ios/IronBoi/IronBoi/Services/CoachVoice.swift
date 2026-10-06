import AVFoundation
import Foundation

/// Reads coach replies aloud with the on-device synthesizer and beats the
/// orb's agent meter once per spoken word. On-device keeps it free, private
/// and offline; a cloud voice can replace `synthesizer` later without
/// touching the orb.
@MainActor
final class CoachVoice: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    /// The message currently (or last) being read, for the caption.
    @Published private(set) var speakingMessageId: String?
    /// The sentence being spoken right now — a subtitle, not a transcript.
    @Published private(set) var caption = ""
    private var sentenceRanges: [NSRange] = []

    let meter = VoiceMeter()
    private let synthesizer = AVSpeechSynthesizer()
    // A cancelled utterance's callback can land after the next one started;
    // only the current utterance may clear `isSpeaking`.
    private var current: AVSpeechUtterance?
    private lazy var voice: AVSpeechSynthesisVoice? = Self.bestVoice()

    override init() {
        super.init()
        synthesizer.delegate = self
        prewarm()
    }

    /// The synthesizer loads its voice the first time it's used, stalling
    /// the main thread for a moment — right as Coach starts talking, which
    /// made the body stutter. Render one silent utterance to a buffer
    /// (nothing plays) so that cost is paid when the screen opens instead.
    private func prewarm() {
        let utterance = AVSpeechUtterance(string: " ")
        utterance.voice = voice
        utterance.volume = 0
        synthesizer.write(utterance) { _ in }
    }

    func speak(_ text: String, messageId: String) {
        let spoken = Self.speakable(text)
        guard !spoken.isEmpty else { return }
        stop()
        // Playback needs a session that can play; the mic engine may have
        // left it in a record-capable one, which is fine — playAndRecord
        // routes to the speaker.
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        }
        try? session.setActive(true)

        sentenceRanges = Self.sentenceRanges(in: spoken)
        caption = ""
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.1
        speakingMessageId = messageId
        current = utterance
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        caption = ""
        meter.reset()
    }

    private func showSentence(at location: Int, in text: String) {
        guard let range = sentenceRanges.first(where: { NSLocationInRange(location, $0) }) else { return }
        let sentence = (text as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        if sentence != caption { caption = sentence }
    }

    private static func sentenceRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .bySentences) { _, range, _, _ in
            ranges.append(range)
        }
        return ranges
    }

    /// Strip the markdown the coach sometimes writes so it isn't read out.
    static func speakable(_ text: String) -> String {
        var out = text
        for token in ["**", "__", "`", "#"] { out = out.replacingOccurrences(of: token, with: "") }
        out = out.replacingOccurrences(of: #"(?m)^\s*[-*•]\s+"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?m)^\s*\d+\.\s+"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\n\n", with: " ")
        out = out.replacingOccurrences(of: "\n", with: ". ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Highest-quality installed US English voice, skipping the novelty ones.
    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == "en-US" && !$0.identifier.contains("speech.synthesis")
        }
        return candidates.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

extension CoachVoice: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let word = (utterance.speechString as NSString).substring(with: characterRange)
        // Longer words land harder. The band split is a stand-in for real
        // spectral analysis: vowels lean low, consonant clusters lean high.
        let letters = word.lowercased().filter(\.isLetter)
        let vowels = Float(letters.filter { "aeiou".contains($0) }.count)
        let count = Float(max(letters.count, 1))
        let strength = min(1, 0.45 + count / 12)
        let bands = SIMD3<Float>(
            min(1, 0.4 + vowels / count * 0.8),
            min(1, 0.3 + count / 10),
            min(1, (count - vowels) / count * 0.9)
        )
        meter.pulse(strength: strength, bands: bands)
        let location = characterRange.location
        let text = utterance.speechString
        Task { @MainActor in self.showSentence(at: location, in: text) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished(utterance) }
    }

    private func finished(_ utterance: AVSpeechUtterance) {
        guard current === utterance else { return }
        current = nil
        isSpeaking = false
        caption = ""
        meter.reset()
    }
}
