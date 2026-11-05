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
    /// Which line of a `speak(lines:)` is playing, so the body can act it out.
    @Published private(set) var lineIndex = 0
    private var lines: [String] = []
    /// Everything in the reply being spoken, start to finish — what the mic
    /// might be hearing of Coach's own voice, not just the current sentence.
    private(set) var spokenText = ""

    let meter = VoiceMeter()
    /// Text in, WAV out. Set by the screen that owns the backend connection.
    /// (words, engine) in → (WAV, the engine that actually read it) out.
    var fetchAudio: ((String, String) async throws -> (Data, String))?
    /// Set while live voice runs a workout: lines go to the live coach.
    /// Returns false when the live coach can't take it right now (it's
    /// between connections): then this voice says it, so there's no dead air.
    var redirect: ((String) -> Bool)?

    private let hub = AudioHub.shared
    private var generation = 0

    // On-device fallback.
    private let synthesizer = AVSpeechSynthesizer()
    private var fallbackUtterance: AVSpeechUtterance?
    private var sentenceRanges: [NSRange] = []
    private lazy var fallbackVoice: AVSpeechSynthesisVoice? = Self.bestVoice()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// No coach voice to be had at all: the device voice outside a workout;
    /// in one, a tone and the words on screen — the voice never changes.
    private func cannotSpeak(_ lines: [String], generation gen: Int) {
        if allowsDeviceVoice {
            speakOnDevice(lines.joined(separator: " "))
            return
        }
        AudioHub.log("voice: couldn't speak — shown instead")
        AudioHub.shared.play(cue: .tick)
        for line in lines { onUnspoken?(line) }
        if gen == generation { finish() }
    }

    /// Outside a workout the on-device voice can stand in when the network
    /// fails; in one, the voice must never change, so it's a tone and the
    /// words on screen instead.
    var allowsDeviceVoice = true
    /// A line that couldn't be spoken in the coach's voice (shown instead).
    var onUnspoken: ((String) -> Void)?

    /// One sentence's audio: from the phone if it's there, else fetched —
    /// within 4 s all told (one quick retry if the first fails fast). A
    /// fetch that lands late is still saved for next time. Nil when there's
    /// none to be had; low signal skips the wait for lines not saved.
    private func audio(for text: String) -> Task<Data?, Never> {
        let fetchAudio = self.fetchAudio
        let engine = VoiceCache.engine
        return Task {
            if let saved = VoiceCache.shared.audio(for: text, engine: engine) { return saved }
            guard let fetchAudio, !VoiceCache.shared.lowSignal else { return nil }
            let deadline = Date().addingTimeInterval(4)
            for attempt in 0..<2 {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0.3, !Task.isCancelled else { break }
                let fetch = Task { () -> Data? in
                    guard let (data, served) = try? await fetchAudio(text, engine) else { return nil }
                    if served == engine { VoiceCache.shared.store(data, for: text, engine: engine) }
                    return data
                }
                do {
                    if let data = try await withDeadline(remaining, { await fetch.value }) {
                        VoiceCache.shared.noteSuccess()
                        return data
                    }
                    AudioHub.log("voice fetch \(attempt + 1) failed")
                } catch {
                    AudioHub.log("voice fetch timed out after 4 s")
                    break
                }
            }
            // Counted once per line, and never for a line that was simply
            // no longer wanted (the coach moved on).
            if !Task.isCancelled { VoiceCache.shared.noteFailure() }
            return nil
        }
    }

    /// Gets lines ready ahead of time (today's workout script), a few at a
    /// time, quietly. Lines already saved cost nothing.
    func prepare(_ lines: [String]) {
        guard let fetchAudio else { return }
        let engine = VoiceCache.engine
        let missing = Array(Set(lines.flatMap { Self.sentences(Self.speakable($0)) })).filter { !VoiceCache.shared.has($0, engine: engine) }
        guard !missing.isEmpty else { return }
        AudioHub.log("voice: preparing \(missing.count) lines")
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func add() {
                    guard next < missing.count else { return }
                    let text = missing[next]
                    next += 1
                    group.addTask {
                        if let (data, served) = try? await withDeadline(8, { try await fetchAudio(text, engine) }), served == engine {
                            VoiceCache.shared.store(data, for: text, engine: engine)
                        }
                    }
                }
                for _ in 0..<4 { add() }
                while await group.next() != nil { add() }
            }
            await MainActor.run { AudioHub.log("voice: prepared") }
        }
    }

    /// When Coach last drew a breath; not again within a few seconds, or
    /// it starts to sound like panting.
    private var lastBreathAt = Date.distantPast

    private func breathes(before chunk: String, index: Int) -> Bool {
        let words = chunk.split(separator: " ").count
        guard words >= 6, Date().timeIntervalSince(lastBreathAt) > 6 else { return false }
        // First sentence of something real: usually. Later ones: sometimes.
        guard index == 0 ? Double.random(in: 0...1) < 0.75 : (words >= 12 && Double.random(in: 0...1) < 0.35) else { return false }
        lastBreathAt = Date()
        return true
    }

    func speak(_ text: String, messageId: String) {
        let spoken = Self.speakable(text)
        guard !spoken.isEmpty else { return }
        play(Self.chunks(spoken), messageId: messageId)
        lines = []
    }

    /// Speaks these lines one after another, each its own request, keeping
    /// `lineIndex` on the one playing — for a lesson the body acts out.
    func speak(lines: [String], messageId: String) {
        let spoken = lines.map(Self.speakable).filter { !$0.isEmpty }
        guard !spoken.isEmpty else { return }
        play(spoken, messageId: messageId)
        self.lines = spoken
    }

    private func play(_ chunks: [String], messageId: String) {
        // A chunk of only punctuation is "too small" for the server, and
        // that error used to drop the rest of the reply to the robot voice.
        let chunks = chunks.filter { $0.rangeOfCharacter(from: .alphanumerics) != nil }
        guard !chunks.isEmpty else { return }
        let spoken = chunks.joined(separator: " ")
        stop()
        spokenText = spoken
        generation += 1
        let gen = generation
        speakingMessageId = messageId
        caption = ""
        lineIndex = 0
        isSpeaking = true

        // Live voice is on: the live coach says it, in its own voice and
        // words. This voice stays "speaking" for about as long as the line
        // takes, so lessons and the mic's turn-taking keep their timing.
        if let redirect, redirect(spoken) {
            let seconds = min(12, 1.2 + Double(spoken.split(separator: " ").count) * 0.38)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard let self, gen == self.generation else { return }
                self.finish()
            }
            return
        }

        guard fetchAudio != nil else {
            cannotSpeak(chunks, generation: gen)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try self.hub.start()
            } catch {
                // The engine wouldn't start (often -50 after a route change):
                // rebuild it once rather than fall back to the robot voice.
                AudioHub.log("voice: engine wouldn't start, rebuilding")
                self.hub.recover()
                do { try self.hub.start() } catch {
                    self.cannotSpeak(chunks, generation: gen)
                    return
                }
            }
            self.installMeterTap()
            // Sentence by sentence, each from the phone if it's been said
            // before (or prepared), else fetched — all at once, so the gaps
            // between sentences are just playback.
            let units = chunks.enumerated().flatMap { line, text in
                Self.sentences(text).map { (text: $0, line: line) }
            }
            let pending = units.map { self.audio(for: $0.text) }
            for (index, unit) in units.enumerated() {
                guard gen == self.generation else { pending.forEach { $0.cancel() }; return }
                guard let data = await pending[index].value, let buffer = try? AudioHub.buffer(fromWAV: data) else {
                    guard gen == self.generation else { return }
                    if self.allowsDeviceVoice {
                        AudioHub.log("voice: no audio, on-device fallback")
                        self.speakOnDevice(units[index...].map(\.text).joined(separator: " "))
                        return
                    }
                    // Mid-workout the voice never changes: a soft tone and
                    // the words on screen instead, then on to the next line.
                    AudioHub.log("voice: no audio for \"\(unit.text.prefix(40))\" — shown, not spoken")
                    AudioHub.shared.play(cue: .tick)
                    self.onUnspoken?(unit.text)
                    continue
                }
                guard gen == self.generation else { return }
                // Breathe like a person: in before a real sentence (not a
                // one-word "Go."), and now and then between longer ones,
                // with gaps that aren't all the same length.
                if self.breathes(before: unit.text, index: index), let breath = AudioHub.breath() {
                    await self.hub.play(breath)
                    guard gen == self.generation else { return }
                } else if index > 0 {
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 30_000_000...110_000_000))
                    guard gen == self.generation else { return }
                }
                self.caption = unit.text
                self.lineIndex = unit.line
                if index == 0 { AudioHub.log("coach speaking: \(AudioHub.shared.routeLines.joined(separator: " | "))") }
                await self.hub.play(buffer)
            }
            if gen == self.generation { self.finish() }
        }
    }

    /// What Coach hadn't got to yet, while it's speaking: the reply from
    /// just after the current sentence to the end. Read it BEFORE stop()
    /// when you cut in, so the rest can be offered later ("want the rest of
    /// what I was saying?").
    var remainingSpeech: String? {
        guard isSpeaking, !caption.isEmpty, let range = spokenText.range(of: caption) else { return nil }
        let rest = spokenText[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.count >= 24 ? rest : nil
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
        // A finished player still reads as playing, which stops the hub from
        // retuning echo cancellation (headphones plugged in mid-workout).
        if hub.player.isPlaying { hub.stopPlayback() }
        speakingOnDevice = false
        isSpeaking = false
        caption = ""
        meter.reset()
    }

    /// The orb reacts to what you actually hear: loudness, syllables and
    /// spectral bands analysed off the player's output.
    /// The voice whose meter is on the shared player, and the player it's on.
    /// More than one screen has a voice (onboarding, then the coach), and the
    /// player allows ONE tap: installing a second aborts the app.
    private static weak var tapOwner: CoachVoice?
    private static weak var tappedPlayer: AVAudioNode?

    private func installMeterTap() {
        let player = hub.player
        guard Self.tapOwner !== self || Self.tappedPlayer !== player else { return }
        // Whoever had it (another screen's voice): this voice's body moves now.
        if Self.tappedPlayer === player { player.removeTap(onBus: 0) }
        let analyzer = MicAnalyzer()
        let meter = self.meter
        player.installTap(onBus: 0, bufferSize: 1_024, format: AudioHub.voiceFormat) { buffer, _ in
            analyzer.process(buffer, into: meter)
        }
        Self.tapOwner = self
        Self.tappedPlayer = player
    }

    /// Sentences, merged so each request is a natural phrase (≤ ~220 chars)
    /// but the first one is short — that's what you wait for.
    /// One sentence each — the unit that's saved and reused ("Rest ninety
    /// seconds." is the same audio every time).
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), s.rangeOfCharacter(from: .alphanumerics) != nil {
                out.append(String(s.prefix(590)))
            }
        }
        if out.isEmpty, text.rangeOfCharacter(from: .alphanumerics) != nil { return [String(text.prefix(590))] }
        return out
    }

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

    /// The on-device voice is speaking. It doesn't go through the shared
    /// engine, so echo cancellation can't remove it from the mic.
    @Published private(set) var speakingOnDevice = false

    private func speakOnDevice(_ spoken: String) {
        speakingOnDevice = true
        // The synthesizer plays on our session; set it up first, or it
        // would use the default one, which stops other apps' music.
        try? hub.start()
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
        if let line = lines.firstIndex(where: { $0.contains(sentence) }), line != lineIndex { lineIndex = line }
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
