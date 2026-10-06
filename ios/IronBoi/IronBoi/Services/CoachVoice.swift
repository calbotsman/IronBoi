import AVFoundation
import Foundation

/// Coach's voice. Replies are read by Google's Chirp 3 HD voice, fetched a
/// sentence or two at a time from the backend so playback starts quickly and
/// the next chunk downloads while this one plays. The orb's coach meter is
/// fed from the real audio as it plays. If the voice can't be fetched (no
/// network, preview mode), the on-device voice reads it instead.
@MainActor
final class CoachVoice: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var speakingMessageId: String?
    /// The sentence being spoken right now — a subtitle, not a transcript.
    @Published private(set) var caption = ""

    let meter = VoiceMeter()
    /// Text in, WAV out. Set by the screen that owns the backend connection.
    var fetchAudio: ((String) async throws -> Data)?

    private let hub = AudioHub.shared
    private var generation = 0
    private var meterTapInstalled = false

    // On-device fallback.
    private let synthesizer = AVSpeechSynthesizer()
    private var fallbackUtterance: AVSpeechUtterance?
    private var sentenceRanges: [NSRange] = []
    private lazy var fallbackVoice: AVSpeechSynthesisVoice? = Self.bestVoice()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, messageId: String) {
        let spoken = Self.speakable(text)
        guard !spoken.isEmpty else { return }
        stop()
        generation += 1
        let gen = generation
        speakingMessageId = messageId
        caption = ""
        isSpeaking = true

        guard let fetchAudio else {
            speakOnDevice(spoken)
            return
        }
        let chunks = Self.chunks(spoken)
        Task { [weak self] in
            guard let self else { return }
            do {
                try self.hub.start()
                self.installMeterTap()
            } catch {
                self.speakOnDevice(spoken)
                return
            }
            var next: Task<Data, Error>? = Task { try await fetchAudio(chunks[0]) }
            for (index, chunk) in chunks.enumerated() {
                guard gen == self.generation, let pending = next else { return }
                let buffer: AVAudioPCMBuffer
                do {
                    buffer = try AudioHub.buffer(fromWAV: try await pending.value)
                } catch {
                    guard gen == self.generation else { return }
                    self.speakOnDevice(chunks[index...].joined(separator: " "))
                    return
                }
                // Download the next chunk while this one plays.
                next = index + 1 < chunks.count ? Task { try await fetchAudio(chunks[index + 1]) } : nil
                guard gen == self.generation else { return }
                self.caption = chunk
                await self.hub.play(buffer)
            }
            if gen == self.generation { self.finish() }
        }
    }

    /// Stops mid-word — you cut in, or the conversation ended.
    func stop() {
        generation += 1
        hub.stopPlayback()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        fallbackUtterance = nil
        finish()
    }

    private func finish() {
        isSpeaking = false
        caption = ""
        meter.reset()
    }

    /// The orb reacts to what you actually hear: loudness, syllables and
    /// spectral bands analysed off the player's output.
    private func installMeterTap() {
        guard !meterTapInstalled else { return }
        let analyzer = MicAnalyzer()
        let meter = self.meter
        hub.player.installTap(onBus: 0, bufferSize: 1_024, format: AudioHub.voiceFormat) { buffer, _ in
            analyzer.process(buffer, into: meter)
        }
        meterTapInstalled = true
    }

    /// Sentences, merged so each request is a natural phrase (≤ ~220 chars)
    /// but the first one is short — that's what you wait for.
    static func chunks(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { sentences.append(s) }
        }
        if sentences.isEmpty { return [text] }
        var out: [String] = []
        for sentence in sentences {
            if let last = out.last, out.count > 1 || last.count > 90, last.count + sentence.count < 220 {
                out[out.count - 1] = last + " " + sentence
            } else {
                out.append(sentence)
            }
        }
        return out.map { String($0.prefix(590)) }
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

    // MARK: - On-device fallback

    private func speakOnDevice(_ spoken: String) {
        isSpeaking = true
        sentenceRanges = Self.sentenceRanges(in: spoken)
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = fallbackVoice
        utterance.postUtteranceDelay = 0.1
        fallbackUtterance = utterance
        synthesizer.speak(utterance)
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
        let letters = Float((utterance.speechString as NSString).substring(with: characterRange).count)
        meter.pulse(strength: min(1, 0.45 + letters / 12), bands: SIMD3(0.6, 0.5, 0.3))
        let location = characterRange.location
        let text = utterance.speechString
        Task { @MainActor in self.showSentence(at: location, in: text) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.fallbackFinished(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.fallbackFinished(utterance) }
    }

    private func fallbackFinished(_ utterance: AVSpeechUtterance) {
        guard fallbackUtterance === utterance else { return }
        fallbackUtterance = nil
        finish()
    }
}
