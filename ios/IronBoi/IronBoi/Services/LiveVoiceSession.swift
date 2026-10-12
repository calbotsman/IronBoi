import AVFoundation
import Foundation

/// Live voice (beta): the phone talks straight to Gemini Live — your voice
/// streams up, the coach's voice streams back, and talking over it stops it
/// mid-word. The server mints a single-use token with the coach's prompt
/// locked in (startLiveCoachSession), so nothing here can change what the
/// coach is told. Milestone 1 of docs/design/live-voice-brain.md: no tools,
/// nothing is written; the regular coach is one tap away.
@MainActor
final class LiveVoiceSession: ObservableObject {
    enum State: Equatable { case idle, connecting, listening, speaking }

    @Published private(set) var state: State = .idle
    /// What the coach is saying right now.
    @Published private(set) var caption = ""
    /// The last thing it heard you say.
    @Published private(set) var heard = ""

    let youMeter = VoiceMeter()
    let agentMeter = VoiceMeter()

    static let defaultsKey = "liveVoiceBeta"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    var isActive: Bool { state != .idle }

    private let hub = AudioHub.shared
    private var socket: URLSessionWebSocketTask?
    private var connection = 0
    private var tapInstalled = false
    private let uplink = MicUplink()
    private let agentAnalyzer = MicAnalyzer()
    private var buffersPlaying = 0
    private var turnDone = true

    struct Ticket: Decodable { let token: String; let model: String }

    /// Connects and starts listening. False if it couldn't (the caller
    /// falls back to the regular coach).
    func start(mint: () async throws -> Ticket) async -> Bool {
        guard state == .idle else { return true }
        connection += 1
        let mine = connection
        state = .connecting
        caption = ""
        heard = ""
        do {
            let ticket = try await mint()
            guard mine == connection else { return false }
            try hub.start(reconfigure: true)
            let token = ticket.token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+/=&"))) ?? ticket.token
            guard let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained?access_token=\(token)") else {
                throw URLError(.badURL)
            }
            let task = URLSession.shared.webSocketTask(with: url)
            task.maximumMessageSize = 8 * 1024 * 1024
            socket = task
            task.resume()
            receive(on: task, connection: mine)
            let setup: [String: Any] = ["setup": [
                "model": "models/\(ticket.model)",
                "generationConfig": ["responseModalities": ["AUDIO"]],
            ]]
            try await task.send(.string(Self.json(setup)))
            AudioHub.log("live: connecting \(ticket.model)")
            return true
        } catch {
            AudioHub.log("live: start failed \(error.localizedDescription)")
            if mine == connection { stop() }
            return false
        }
    }

    func stop() {
        connection += 1
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        removeTap()
        hub.stopPlayback()
        buffersPlaying = 0
        turnDone = true
        youMeter.reset()
        agentMeter.reset()
        if state != .idle { AudioHub.log("live: ended") }
        state = .idle
        caption = ""
        hub.stop()
    }

    // MARK: - Receiving

    private func receive(on task: URLSessionWebSocketTask, connection mine: Int) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, mine == self.connection else { return }
                switch result {
                case .failure(let error):
                    AudioHub.log("live: socket closed \(error.localizedDescription)")
                    self.stop()
                case .success(let message):
                    let data: Data?
                    switch message {
                    case .string(let text): data = text.data(using: .utf8)
                    case .data(let raw): data = raw
                    @unknown default: data = nil
                    }
                    if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handle(object)
                    }
                    if mine == self.connection { self.receive(on: task, connection: mine) }
                }
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        if let error = message["error"] as? [String: Any] {
            AudioHub.log("live: provider error \(error["code"] ?? "?") \(String(describing: error["status"] ?? ""))")
            stop()
            return
        }
        if message["setupComplete"] != nil {
            AudioHub.log("live: ready")
            state = .listening
            installTap()
            return
        }
        if message["goAway"] != nil { AudioHub.log("live: server asked to wrap up") }
        guard let content = message["serverContent"] as? [String: Any] else { return }
        if content["interrupted"] as? Bool == true {
            // You talked over it: drop what's queued, right now.
            hub.stopPlayback()
            buffersPlaying = 0
            turnDone = true
            agentMeter.reset()
            uplink.coachSpeaking = false
            state = .listening
            AudioHub.log("live: interrupted")
        }
        if let input = (content["inputTranscription"] as? [String: Any])?["text"] as? String,
           !input.trimmingCharacters(in: .whitespaces).isEmpty {
            heard = turnDone ? input : heard + input
            AudioHub.log("live heard: \(input.suffix(60))")
        }
        if let parts = (content["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] {
            for part in parts {
                guard let inline = part["inlineData"] as? [String: Any],
                      let b64 = inline["data"] as? String,
                      let pcm = Data(base64Encoded: b64),
                      let buffer = Self.buffer(fromPCM16: pcm) else { continue }
                if turnDone { caption = ""; turnDone = false }
                play(buffer)
            }
        }
        if let output = (content["outputTranscription"] as? [String: Any])?["text"] as? String {
            caption += output
        }
        if content["turnComplete"] as? Bool == true {
            turnDone = true
            if buffersPlaying == 0 { state = .listening; uplink.coachSpeaking = false }
            AudioHub.log("live said: \(caption.suffix(80))")
        }
    }

    private func play(_ buffer: AVAudioPCMBuffer) {
        if !hub.engine.isRunning { try? hub.start() }
        state = .speaking
        uplink.coachSpeaking = true
        uplink.halfDuplex = !hub.canTalkOver
        buffersPlaying += 1
        agentAnalyzer.process(buffer, into: agentMeter)
        let mine = connection
        hub.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, mine == self.connection else { return }
                self.buffersPlaying = max(0, self.buffersPlaying - 1)
                if self.buffersPlaying == 0, self.turnDone {
                    self.state = .listening
                    self.uplink.coachSpeaking = false
                    self.agentMeter.reset()
                }
            }
        }
        if !hub.player.isPlaying { hub.player.play() }
    }

    /// Gemini sends 24 kHz mono 16-bit PCM; the player takes the hub's
    /// float format at the same rate.
    static func buffer(fromPCM16 data: Data) -> AVAudioPCMBuffer? {
        let frames = data.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: AudioHub.voiceFormat, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0] else { return nil }
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: samples[i])) / 32768 }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    // MARK: - Sending

    private func installTap() {
        guard !tapInstalled, let socket else { return }
        let input = hub.engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { AudioHub.log("live: no mic"); stop(); return }
        uplink.reset(sourceRate: format.sampleRate)
        let uplink = self.uplink
        let meter = youMeter
        let analyzer = MicAnalyzer()
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            analyzer.process(buffer, into: meter)
            guard let chunk = uplink.append(buffer) else { return }
            let message = "{\"realtimeInput\":{\"audio\":{\"data\":\"\(chunk.base64EncodedString())\",\"mimeType\":\"audio/pcm;rate=16000\"}}}"
            socket.send(.string(message)) { _ in }
        }
        tapInstalled = true
        if !hub.engine.isRunning { try? hub.start() }
        AudioHub.log("live: mic streaming (echo cancel \(hub.canTalkOver ? "or headphones" : "off: half duplex"))")
    }

    private func removeTap() {
        guard tapInstalled else { return }
        hub.engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    #if DEBUG
    /// Sends a typed line as if spoken (MYO_LIVE_PROBE).
    func debugSay(_ text: String) {
        guard let socket, let json = try? Self.json(["realtimeInput": ["text": text]]) else { return }
        socket.send(.string(json)) { _ in }
        AudioHub.log("probe: said \"\(text)\"")
    }
    #endif

    private static func json(_ object: [String: Any]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8) ?? "{}"
    }
}

/// Turns mic buffers into 16 kHz mono 16-bit chunks of ~100 ms, on the
/// audio thread. On the phone speaker without echo cancellation the mic
/// would hear the coach and cut it off, so there it sends silence-free
/// nothing while the coach speaks (half duplex); with headphones or echo
/// cancellation you can talk over it.
private final class MicUplink: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var ratio: Double = 3
    private var _coachSpeaking = false
    private var _halfDuplex = false
    private static let chunkBytes = 3_200 // 100 ms at 16 kHz, 16-bit

    var coachSpeaking: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _coachSpeaking }
        set { lock.lock(); _coachSpeaking = newValue; lock.unlock() }
    }
    var halfDuplex: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _halfDuplex }
        set { lock.lock(); _halfDuplex = newValue; lock.unlock() }
    }

    func reset(sourceRate: Double) {
        lock.lock(); defer { lock.unlock() }
        pending = Data()
        ratio = sourceRate / 16_000
        _coachSpeaking = false
    }

    func append(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength)
        lock.lock(); defer { lock.unlock() }
        if _halfDuplex && _coachSpeaking { pending.removeAll(keepingCapacity: true); return nil }
        let outCount = Int(Double(count) / ratio)
        guard outCount > 0 else { return nil }
        var samples = [Int16](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let position = Double(i) * ratio
            let low = min(Int(position), count - 1), high = min(low + 1, count - 1)
            let fraction = Float(position - Double(low))
            let value = channel[low] + (channel[high] - channel[low]) * fraction
            samples[i] = Int16(max(-1, min(1, value)) * 32767)
        }
        samples.withUnsafeBufferPointer { pending.append(Data(buffer: $0)) }
        guard pending.count >= Self.chunkBytes else { return nil }
        let chunk = pending
        pending = Data()
        return chunk
    }
}
