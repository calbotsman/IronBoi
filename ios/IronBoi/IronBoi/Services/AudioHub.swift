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
    private var engineStarted = false
    private var sessionActive = false
    private(set) var echoCancelling = false
    /// Headphones (wired or Bluetooth) are connected. Tracked separately
    /// from the current route: once voice processing has pulled audio onto
    /// the speaker, the route no longer shows the headphones at all.
    private(set) var headphonesConnected = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            MainActor.assumeIsolated {
                self.routeChanged(raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)), previous: previous)
            }
        }
    }

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?, previous: AVAudioSessionRouteDescription?) {
        let current = AVAudioSession.sharedInstance().currentRoute
        switch reason {
        case .oldDeviceUnavailable:
            if let previous, Self.headphones(in: previous) { headphonesConnected = Self.headphones(in: current) }
        default:
            if Self.headphones(in: current) { headphonesConnected = true }
        }
    }

    /// Where audio is going right now, for the mic button's long-press —
    /// so a tester can say exactly what happened.
    var routeLines: [String] {
        let route = AVAudioSession.sharedInstance().currentRoute
        let out = route.outputs.map(\.portName).joined(separator: ", ")
        let input = route.inputs.map(\.portName).joined(separator: ", ")
        return [
            "Sound out: \(out.isEmpty ? "none" : out)",
            "Mic: \(input.isEmpty ? "none" : input)",
            "Headphones: \(headphonesConnected ? "yes" : "no") · Echo cancel: \(echoCancelling ? "on" : "off")",
        ]
    }

    /// Session + graph, once; then makes sure the engine is running.
    /// `reconfigure`: the mic isn't tapped right now, so echo cancellation
    /// may be switched on or off to suit the current route.
    func start(reconfigure: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        // Before we take the session, the route is the system's own — if
        // headphones are on, it shows them.
        if !sessionActive { headphonesConnected = Self.headphones(in: session.currentRoute) }
        if session.category != .playAndRecord {
            try session.setCategory(.playAndRecord, mode: .default, options: Self.categoryOptions)
        }
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        sessionActive = true
        if Self.headphones(in: session.currentRoute) { headphonesConnected = true }

        if !configured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: Self.voiceFormat)
            configured = true
        }

        // Echo cancellation only where it's needed and safe: Coach on the
        // phone's own speaker, nothing else playing. Voice processing can't
        // run with Bluetooth headphones — iOS pulls the audio off them onto
        // the speaker — and with headphones the mic can't hear Coach
        // anyway. With music playing it fights the other app's audio.
        let wanted = !headphonesConnected && !session.isOtherAudioPlaying
        if (reconfigure || !engineStarted), wanted != engine.inputNode.isVoiceProcessingEnabled, !player.isPlaying {
            if engine.isRunning { engine.stop() }
            do {
                try engine.inputNode.setVoiceProcessingEnabled(wanted)
                if wanted, #available(iOS 17.0, *) {
                    // Other audio dips only while someone's actually talking.
                    engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                        .init(enableAdvancedDucking: true, duckingLevel: .mid)
                }
            } catch {
                // The simulator and some routes refuse it; the app still
                // works, you just can't talk over Coach on the speaker.
            }
        }
        echoCancelling = engine.inputNode.isVoiceProcessingEnabled
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
            engineStarted = true
        }
    }

    /// You can talk over Coach without the mic hearing Coach: its voice is
    /// cancelled from the mic, or it's in your ears.
    var canTalkOver: Bool {
        echoCancelling || headphonesConnected
    }

    private static func headphones(in route: AVAudioSessionRouteDescription) -> Bool {
        let ports: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
                                               .usbAudio, .carAudio, .airPlay]
        return route.outputs.contains { ports.contains($0.portType) }
    }

    /// Plays alongside your music rather than stopping it. Bluetooth stays
    /// in its full-quality music mode (A2DP) — the hands-free mode turned
    /// Spotify into phone-call audio — so the phone's own mic listens.
    private static let categoryOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .mixWithOthers, .allowBluetoothA2DP]

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

    /// Lets the mic indicator go out when the conversation is over, and
    /// tells other apps we're done — anything we interrupted can resume.
    func stop() {
        player.stop()
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sessionActive = false
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
