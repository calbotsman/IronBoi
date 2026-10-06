import AVFoundation

/// One audio engine for both sides of the conversation: the mic going in and
/// Coach's voice coming out. Sharing it is what lets iOS voice processing
/// cancel Coach's own voice from the mic — so the mic can stay open while
/// Coach talks, and you can simply start talking to cut in.
@MainActor
final class AudioHub {
    static let shared = AudioHub()

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    /// Coach's audio format: Cloud TTS LINEAR16 at 24 kHz, mono.
    static let voiceFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    private var configured = false
    private(set) var echoCancelling = false

    private init() {}

    /// Session + graph, once; then makes sure the engine is running.
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try session.setCategory(.playAndRecord, mode: .default, options: Self.categoryOptions)
        }
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        if !configured {
            // Echo cancellation must be set before the engine first runs.
            // The simulator and some routes refuse it; the app still works,
            // you just can't talk over Coach there.
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                if #available(iOS 17.0, *) {
                    // Your music dips only while someone's actually talking
                    // — Coach or you — not for the whole time the mic is open.
                    engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                        .init(enableAdvancedDucking: true, duckingLevel: .mid)
                }
                echoCancelling = true
            } catch {
                echoCancelling = false
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: Self.voiceFormat)
            configured = true
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    /// Plays alongside your music rather than stopping it. Bluetooth stays
    /// in its full-quality music mode (A2DP) — the old hands-free mode
    /// turned Spotify into phone-call audio for the whole workout. On iOS 26
    /// AirPods that support it record at full quality too; otherwise the
    /// phone's own mic listens.
    private static var categoryOptions: AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .mixWithOthers, .allowBluetoothA2DP]
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { options.insert(.bluetoothHighQualityRecording) }
        #endif
        return options
    }

    /// Plays one buffer of Coach's voice; returns when it has been heard (or
    /// playback was stopped).
    func play(_ buffer: AVAudioPCMBuffer) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                done.resume()
            }
            if !player.isPlaying { player.play() }
        }
    }

    func stopPlayback() {
        player.stop()
    }

    /// Lets the mic indicator go out when the conversation is over.
    func stop() {
        player.stop()
        if engine.isRunning { engine.stop() }
    }

    /// Decodes Cloud TTS WAV bytes into a buffer the player can schedule.
    static func buffer(fromWAV data: Data) throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coach-\(UUID().uuidString).wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer)
        guard file.processingFormat.sampleRate == voiceFormat.sampleRate,
              file.processingFormat.channelCount == voiceFormat.channelCount else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return buffer
    }
}
