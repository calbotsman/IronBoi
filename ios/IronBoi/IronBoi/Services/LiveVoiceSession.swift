import AVFoundation
import Foundation
import Network

/// Live voice (beta): the phone talks straight to Gemini Live — your voice
/// streams up, the coach's streams back, and talking over it stops it
/// mid-word. The server mints a single-use token with the whole coach brain
/// locked in (profile, plan, workouts, memory, notes, the shared
/// conversation) — nothing here can change what the coach is told.
///
/// Memory: every exchange is saved into the same conversation the regular
/// coach uses, so neither ever makes you repeat yourself. Tools (remember,
/// your name, plan changes) run on the server with the text coach's gates.
/// Connections end after ~10 minutes; it reconnects with the resume handle
/// and the conversation carries on. See docs/design/live-voice-brain.md.
@MainActor
final class LiveVoiceSession: ObservableObject {
    enum State: Equatable { case idle, connecting, listening, speaking }

    @Published private(set) var state: State = .idle
    /// What the coach is saying right now.
    @Published private(set) var caption = ""
    /// What it heard you say this turn.
    @Published private(set) var heard = ""

    let youMeter = VoiceMeter()
    let agentMeter = VoiceMeter()

    static let defaultsKey = "liveVoiceBeta"
    /// On unless you've turned it off: it's the fast voice (2026-10-18).
    static var enabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    var isActive: Bool { state != .idle }

    /// Which live voice model: Gemini Live, or OpenAI Realtime for an A/B.
    /// Same coach brain, tools and memory either way.
    enum Provider: String, CaseIterable {
        case gemini, openai
        var label: String { self == .gemini ? "Gemini" : "OpenAI" }
    }
    static let providerKey = "liveVoiceProvider"
    static var provider: Provider {
        Provider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .gemini
    }
    /// The provider of the connection that's open now.
    private(set) var activeProvider: Provider = .gemini
    private var openAI: Bool { activeProvider == .openai }
    /// OpenAI tool calls still running this turn.
    private var openAIToolsPending = 0

    struct Ticket: Decodable { let token: String; let model: String; let provider: String? }
    struct TurnResult: Decodable { let saved: Bool; let stop: Bool; let line: String? }

    /// The server, as the session needs it.
    struct Backend {
        /// `handover`: a fresh connection mid-conversation (its own cap).
        var mint: (_ resumeHandle: String?, _ handover: Bool) async throws -> Ticket
        var recordTurn: (_ user: String, _ coach: String, _ startedAt: Date, _ interrupted: Bool) async throws -> TurnResult
        var runTool: (_ name: String, _ args: [String: Any], _ turnId: String, _ rawUserText: String) async throws -> [String: Any]
    }

    /// The server's severe screen fired on what you said: the session ends
    /// and the caller says this line.
    var onSafetyStop: ((String) -> Void)?
    /// Live dropped and couldn't come back: the caller carries on with the
    /// regular coach, without a word about it.
    var onDropped: (() -> Void)?
    /// Every mic buffer also goes here (the phone's own counter, mid-workout).
    var sideTap: ((AVAudioPCMBuffer) -> Void)?
    /// While you count, the coach doesn't hear the mic at all — it can't
    /// talk over a set. When this went false (anything said just before
    /// that is forwarded as text).
    private(set) var uplinkMuted = false
    private(set) var unmutedAt = Date.distantPast

    private let hub = AudioHub.shared
    private var backend: Backend?
    private var socket: URLSessionWebSocketTask?
    private let socketBox = SocketBox()
    private var connection = 0
    private var tapInstalled = false
    private let uplink = MicUplink()
    private let agentAnalyzer = MicAnalyzer()
    private var buffersPlaying = 0
    private var model = ""
    private var resumeHandle: String?
    private var reconnecting = false

    // The handover. Connections don't last (Gemini ~10 min, OpenAI 60), so
    // before one ends a second is opened alongside it and the mic moves over
    // at a quiet moment — nobody talking, nothing playing — so you never
    // hear it. The audio session is never released, so AirPods don't blip.
    private var standby: URLSessionWebSocketTask?
    private var standbyReady = false
    private var connectedAt = Date()
    /// The provider said this connection is ending: hand over by then.
    private var mustMoveBy: Date?
    private var handingOver = false
    private var handoverWatch: Task<Void, Never>?
    /// When you were last heard, so a handover never lands mid-sentence.
    private var lastHeardAt = Date.distantPast

    // Wi-Fi to cellular (walking out of the gym, a dead spot) kills a
    // connection without warning — far more often than the time limit. The
    // moment the network changes, hand over to a connection on the new one.
    private var pathMonitor: NWPathMonitor?
    private var lastInterface: NWInterface.InterfaceType?

    // For the log: every handover and every gap you could have heard.
    private var gapStartedAt: Date?
    private var gapReason = ""
    private var handovers = 0
    private var gaps: [Int] = []

    // The exchange in progress: what you said, what it said back.
    private var turnId = UUID().uuidString
    private var turnUser = ""
    private var turnCoach = ""
    private var turnStartedAt = Date()
    private var coachTurnDone = true

    /// Connects and starts listening. False if it couldn't (the caller
    /// falls back to the regular coach).
    func start(_ backend: Backend) async -> Bool {
        guard state == .idle else { return true }
        self.backend = backend
        resumeHandle = nil
        caption = ""
        heard = ""
        resetTurn()
        state = .connecting
        watchNetwork()
        return await connect(resume: nil)
    }

    private func watchNetwork() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let interface: NWInterface.InterfaceType? = path.status == .satisfied
                ? [.wifi, .cellular, .wiredEthernet].first { path.usesInterfaceType($0) } : nil
            Task { @MainActor in self?.networkChanged(to: interface) }
        }
        monitor.start(queue: DispatchQueue(label: "live.path"))
        pathMonitor = monitor
        lastInterface = nil
    }

    private func networkChanged(to interface: NWInterface.InterfaceType?) {
        defer { if interface != nil { lastInterface = interface } }
        guard state != .idle, socket != nil, let interface, let before = lastInterface, interface != before else { return }
        AudioHub.log("live: network \(before) → \(interface), handing over now")
        // Go now: the old connection is riding a network that's leaving.
        mustMoveBy = Date()
    }

    func stop() {
        connection += 1
        recordTurnIfAny(interrupted: true)
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        standby?.cancel(with: .normalClosure, reason: nil)
        standby = nil
        standbyReady = false
        handoverWatch?.cancel()
        handoverWatch = nil
        mustMoveBy = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        if state != .idle {
            AudioHub.log("live: session summary — handovers \(handovers), gaps \(gaps.count)\(gaps.isEmpty ? "" : " (ms: \(gaps.map(String.init).joined(separator: ", ")))")")
        }
        handovers = 0
        gaps = []
        gapStartedAt = nil
        socketBox.socket = nil
        removeTap()
        uplinkMuted = false
        uplink.muted = false
        hub.stopPlayback()
        buffersPlaying = 0
        youMeter.reset()
        agentMeter.reset()
        if state != .idle { AudioHub.log("live: ended") }
        state = .idle
        caption = ""
        reconnecting = false
        hub.stop()
    }

    /// A reconnect finished: how long you were without the coach.
    private func endGap() {
        guard let started = gapStartedAt else { return }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        gaps.append(ms)
        gapStartedAt = nil
        AudioHub.log("live: GAP \(ms) ms (\(gapReason))")
    }

    /// It died and couldn't come back: stop, and let the caller take over.
    private func drop() {
        guard state != .idle else { return }
        AudioHub.log("live: dropped, handing to the regular coach")
        stop()
        onDropped?()
    }

    // MARK: - Connecting

    private func connect(resume handle: String?) async -> Bool {
        guard let backend else { return false }
        connection += 1
        let mine = connection
        do {
            let ticket = try await backend.mint(handle, handle != nil || gapStartedAt != nil)
            guard mine == connection else { return false }
            model = ticket.model
            activeProvider = Provider(rawValue: ticket.provider ?? "") ?? .gemini
            try hub.start(reconfigure: !tapInstalled)
            _ = try await openSocket(ticket, resume: handle, connection: mine)
            connectedAt = Date()
            mustMoveBy = nil
            watchForHandover()
            return true
        } catch {
            AudioHub.log("live: connect failed \(error.localizedDescription)")
            if mine == connection {
                if handle != nil {
                    // Resuming failed: a fresh session still has the whole
                    // conversation (every turn was saved), so carry on.
                    resumeHandle = nil
                    return await connect(resume: nil)
                }
                stop()
            }
            return false
        }
    }

    /// Opens a connection for this ticket and starts reading it.
    /// `standby`: it's the next connection for a handover, not the one in use.
    private func openSocket(_ ticket: Ticket, resume handle: String?, connection mine: Int,
                            standby asStandby: Bool = false) async throws -> URLSessionWebSocketTask {
        // Claimed before anything can arrive on it, so its first message
        // ("ready") is never dropped.
        func claim(_ task: URLSessionWebSocketTask) {
            if asStandby { standby = task } else { socket = task }
        }
        if openAI {
            // Realtime: the client secret goes in the header; the session
            // (brain, voice, tools) was attached when it was minted.
            guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(ticket.model)") else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(ticket.token)", forHTTPHeaderField: "Authorization")
            let task = URLSession.shared.webSocketTask(with: request)
            task.maximumMessageSize = 8 * 1024 * 1024
            claim(task)
            task.resume()
            receive(on: task, connection: mine)
            AudioHub.log("live: connecting OpenAI \(ticket.model)")
            return task
        }
        let token = ticket.token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+/=&"))) ?? ticket.token
        guard let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained?access_token=\(token)") else {
            throw URLError(.badURL)
        }
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 8 * 1024 * 1024
        claim(task)
        task.resume()
        receive(on: task, connection: mine)
        var setup: [String: Any] = [
            "model": "models/\(ticket.model)",
            "generationConfig": ["responseModalities": ["AUDIO"]],
        ]
        if let handle { setup["sessionResumption"] = ["handle": handle] }
        try await task.send(.string(Self.json(["setup": setup])))
        AudioHub.log("live: connecting \(ticket.model)\(handle == nil ? "" : " (resuming)")")
        return task
    }

    // MARK: - The handover

    /// How long a connection is kept before it's handed over: well inside
    /// Gemini's ~10 minutes and OpenAI's 60.
    private var handoverAge: TimeInterval { openAI ? 45 * 60 : 7.5 * 60 }

    /// Nobody's talking and nothing's playing: a handover here is unheard.
    /// Counting a set counts as quiet — the coach's mic is muted for it.
    private var isQuiet: Bool {
        (state == .listening || uplinkMuted) && buffersPlaying == 0 && coachTurnDone && openAIToolsPending == 0
            && Date().timeIntervalSince(lastHeardAt) > 2.5 && !handingOver
    }

    private func watchForHandover() {
        handoverWatch?.cancel()
        handoverWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.state != .idle, self.socket != nil else { return }
                // A reconnect already under way does the same job.
                guard !self.handingOver, !self.reconnecting else { continue }
                let due = Date().timeIntervalSince(self.connectedAt) > self.handoverAge || self.mustMoveBy != nil
                // Close to the provider's cut-off: go now, quiet or not.
                let urgent = self.mustMoveBy.map { $0.timeIntervalSinceNow < 6 } ?? false
                if due, urgent || self.isQuiet { await self.handOver() }
            }
        }
    }

    /// Opens the next connection beside this one, waits for it, then moves
    /// the mic across in one step. The coach's last words finish on the old
    /// one; anything you said in the last two seconds is sent again.
    private func handOver() async {
        guard let backend, !handingOver, !reconnecting, state != .idle else { return }
        handingOver = true
        defer { handingOver = false }
        let mine = connection
        AudioHub.log("live: handover starting (\(openAI ? "OpenAI" : "Gemini"))")
        do {
            // Gemini resumes the same session; OpenAI starts a fresh one,
            // minted with the whole conversation so far.
            let ticket = try await backend.mint(openAI ? nil : resumeHandle, true)
            guard mine == connection, state != .idle else { return }
            standbyReady = false
            let task = try await openSocket(ticket, resume: openAI ? nil : resumeHandle, connection: mine, standby: true)
            for _ in 0..<100 where !standbyReady && standby === task && mine == connection {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard standbyReady, standby === task, mine == connection else {
                AudioHub.log("live: handover connection never got ready")
                if standby === task { standby = nil }
                task.cancel(with: .normalClosure, reason: nil)
                return
            }
            // It's up. Wait for a quiet beat if one's coming (up to ~8 s),
            // unless the old one is about to go.
            for _ in 0..<32 where !isQuietIgnoringHandover && !(mustMoveBy.map { $0.timeIntervalSinceNow < 4 } ?? false) {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard standby === task, mine == connection else { return }
            let old = socket
            socket = task
            standby = nil
            socketBox.moveTo(task)
            let age = Int(Date().timeIntervalSince(connectedAt))
            connectedAt = Date()
            mustMoveBy = nil
            handovers += 1
            AudioHub.log("live: handover done, no gap (#\(handovers), after \(age) s)")
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                old?.cancel(with: .normalClosure, reason: nil)
            }
        } catch {
            AudioHub.log("live: handover failed \(error.localizedDescription)")
        }
    }

    private var isQuietIgnoringHandover: Bool {
        (state == .listening || uplinkMuted) && buffersPlaying == 0 && coachTurnDone && openAIToolsPending == 0
            && Date().timeIntervalSince(lastHeardAt) > 2.5
    }

    /// The connection is ending (server's ~10-minute limit, or it dropped):
    /// a new token and the resume handle carry the conversation on.
    private func reconnect(reason: String) {
        guard !reconnecting, state != .idle else { return }
        reconnecting = true
        if gapStartedAt == nil { gapStartedAt = Date(); gapReason = reason }
        AudioHub.log("live: reconnecting (\(reason))")
        let old = socket
        socketBox.socket = nil
        Task {
            let ok = await connect(resume: resumeHandle)
            old?.cancel(with: .normalClosure, reason: nil)
            reconnecting = false
            if !ok {
                AudioHub.log("live: reconnect failed")
                drop()
            }
        }
    }

    // MARK: - Receiving

    private func receive(on task: URLSessionWebSocketTask, connection mine: Int) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, mine == self.connection else { return }
                // An old connection after a handover: done with it.
                let current = task === self.socket, spare = task === self.standby
                guard current || spare || self.socket == nil else { return }
                switch result {
                case .failure(let error):
                    if spare {
                        AudioHub.log("live: handover connection closed \(error.localizedDescription)")
                        self.standby = nil
                        return
                    }
                    AudioHub.log("live: socket closed \(error.localizedDescription)")
                    if self.state != .idle, self.resumeHandle != nil || self.openAI { self.reconnect(reason: "closed") } else { self.drop() }
                case .success(let message):
                    let data: Data?
                    switch message {
                    case .string(let text): data = text.data(using: .utf8)
                    case .data(let raw): data = raw
                    @unknown default: data = nil
                    }
                    if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handle(object, socket: task)
                    }
                    if mine == self.connection, task === self.socket || task === self.standby { self.receive(on: task, connection: mine) }
                }
            }
        }
    }

    private func handle(_ message: [String: Any], socket task: URLSessionWebSocketTask) {
        // The next connection, warming up: only listen for "ready".
        if task === standby {
            if message["setupComplete"] != nil || ["session.created", "session.updated"].contains(message["type"] as? String ?? "") {
                standbyReady = true
                AudioHub.log("live: handover connection ready")
            } else if message["error"] != nil {
                AudioHub.log("live: handover connection refused")
                standby?.cancel(with: .normalClosure, reason: nil)
                standby = nil
            } else if let update = message["sessionResumptionUpdate"] as? [String: Any],
                      update["resumable"] as? Bool != false, let handle = update["newHandle"] as? String, !handle.isEmpty {
                resumeHandle = handle
            }
            return
        }
        guard task === socket else { return }
        if openAI {
            handleOpenAI(message, socket: task)
            return
        }
        if let error = message["error"] as? [String: Any] {
            AudioHub.log("live: provider error \(error["code"] ?? "?") \(String(describing: error["status"] ?? ""))")
            stop()
            return
        }
        if message["setupComplete"] != nil {
            AudioHub.log("live: ready")
            endGap()
            socketBox.socket = task
            if state == .connecting { state = .listening }
            installTap()
            return
        }
        if let update = message["sessionResumptionUpdate"] as? [String: Any],
           update["resumable"] as? Bool != false, let handle = update["newHandle"] as? String, !handle.isEmpty {
            resumeHandle = handle
        }
        if let away = message["goAway"] as? [String: Any] {
            // "timeLeft": "12s" — hand over before then, at a quiet beat if one comes.
            let left = (away["timeLeft"] as? String).flatMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "s"))) } ?? 10
            mustMoveBy = Date().addingTimeInterval(left)
            AudioHub.log("live: connection ends in \(Int(left)) s, handing over")
        }
        if let toolCall = message["toolCall"] as? [String: Any],
           let calls = toolCall["functionCalls"] as? [[String: Any]] {
            for call in calls { runTool(call) }
        }
        guard let content = message["serverContent"] as? [String: Any] else { return }
        if content["interrupted"] as? Bool == true {
            // You talked over it: drop what's queued, right now.
            hub.stopPlayback()
            buffersPlaying = 0
            agentMeter.reset()
            uplink.coachSpeaking = false
            state = .listening
            AudioHub.log("live: interrupted")
            recordTurnIfAny(interrupted: true)
        }
        if let input = (content["inputTranscription"] as? [String: Any])?["text"] as? String,
           !input.trimmingCharacters(in: .whitespaces).isEmpty {
            // Speech after the coach finished answering starts a new turn.
            if coachTurnDone, !turnCoach.isEmpty { recordTurnIfAny(interrupted: false) }
            if turnUser.isEmpty { turnStartedAt = Date() }
            turnUser += input
            heard = turnUser
            lastHeardAt = Date()
        }
        if let parts = (content["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] {
            for part in parts {
                guard let inline = part["inlineData"] as? [String: Any],
                      let b64 = inline["data"] as? String,
                      let pcm = Data(base64Encoded: b64),
                      let buffer = Self.buffer(fromPCM16: pcm) else { continue }
                if coachTurnDone { caption = ""; coachTurnDone = false }
                play(buffer)
            }
        }
        if let output = (content["outputTranscription"] as? [String: Any])?["text"] as? String {
            if coachTurnDone { caption = ""; coachTurnDone = false }
            caption += output
            turnCoach += output
        }
        if content["turnComplete"] as? Bool == true {
            coachTurnDone = true
            if buffersPlaying == 0 { state = .listening; uplink.coachSpeaking = false }
            // A turn that only called a tool has nothing said yet: keep it
            // open so the exchange is saved whole once the coach answers.
            if !turnCoach.isEmpty { recordTurnIfAny(interrupted: false) }
        }
    }

    /// OpenAI Realtime's events, mapped onto the same turn-taking as Gemini's.
    private func handleOpenAI(_ message: [String: Any], socket task: URLSessionWebSocketTask) {
        let type = message["type"] as? String ?? ""
        switch type {
        case "error":
            let error = message["error"] as? [String: Any]
            AudioHub.log("live: OpenAI error \(error?["code"] ?? error?["type"] ?? "?") \(String(describing: error?["message"] ?? "").prefix(120))")
            // Before the session is up, an error means it never will be.
            if state == .connecting { stop() }
        case "session.created", "session.updated":
            guard socketBox.socket == nil else { return }
            AudioHub.log("live: ready (OpenAI)")
            endGap()
            socketBox.socket = task
            if state == .connecting { state = .listening }
            installTap()
        case "input_audio_buffer.speech_started":
            lastHeardAt = Date()
            // You talked over it: drop what's queued, right now. The server
            // cancels the response itself (interrupt_response).
            guard state == .speaking else { return }
            hub.stopPlayback()
            buffersPlaying = 0
            agentMeter.reset()
            uplink.coachSpeaking = false
            state = .listening
            AudioHub.log("live: interrupted")
            recordTurnIfAny(interrupted: true)
        case "conversation.item.input_audio_transcription.completed":
            guard let input = message["transcript"] as? String, !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            if coachTurnDone, !turnCoach.isEmpty { recordTurnIfAny(interrupted: false) }
            if turnUser.isEmpty { turnStartedAt = Date() }
            turnUser += (turnUser.isEmpty ? "" : " ") + input
            heard = turnUser
        case "response.output_audio.delta", "response.audio.delta":
            guard let b64 = message["delta"] as? String, let pcm = Data(base64Encoded: b64),
                  let buffer = Self.buffer(fromPCM16: pcm) else { return }
            if coachTurnDone { caption = ""; coachTurnDone = false }
            play(buffer)
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            guard let delta = message["delta"] as? String else { return }
            if coachTurnDone { caption = ""; coachTurnDone = false }
            caption += delta
            turnCoach += delta
        case "response.function_call_arguments.done":
            guard let name = message["name"] as? String, let callId = message["call_id"] as? String else { return }
            let raw = (message["arguments"] as? String)?.data(using: .utf8)
            let args = raw.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            openAIToolsPending += 1
            runTool(name: name, args: args) { [weak self] response in
                guard let self else { return }
                self.openAIToolsPending = max(0, self.openAIToolsPending - 1)
                guard let socket = self.socket else { return }
                let output = (try? Self.json(response)) ?? "{}"
                let item: [String: Any] = ["type": "conversation.item.create",
                                           "item": ["type": "function_call_output", "call_id": callId, "output": output]]
                if let json = try? Self.json(item) { try? await socket.send(.string(json)) }
                // One reply once every tool in the turn has answered.
                if self.openAIToolsPending == 0, let json = try? Self.json(["type": "response.create"]) {
                    try? await socket.send(.string(json))
                }
            }
        case "response.done":
            coachTurnDone = true
            if buffersPlaying == 0 { state = .listening; uplink.coachSpeaking = false }
            if !turnCoach.isEmpty { recordTurnIfAny(interrupted: false) }
        default:
            break
        }
    }

    // MARK: - Memory: every exchange into the shared conversation

    private func resetTurn() {
        turnId = UUID().uuidString
        turnUser = ""
        turnCoach = ""
        turnStartedAt = Date()
        coachTurnDone = true
    }

    private func recordTurnIfAny(interrupted: Bool) {
        let user = turnUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let coach = turnCoach.trimmingCharacters(in: .whitespacesAndNewlines)
        let startedAt = turnStartedAt
        resetTurn()
        guard !user.isEmpty || !coach.isEmpty, let backend else { return }
        AudioHub.log("live turn: you \"\(user.suffix(50))\" · coach \"\(coach.suffix(50))\"\(interrupted ? " (cut off)" : "")")
        Task {
            do {
                let result = try await backend.recordTurn(user, coach, startedAt, interrupted)
                if result.stop, let line = result.line {
                    AudioHub.log("live: severe stop")
                    stop()
                    onSafetyStop?(line)
                }
            } catch {
                AudioHub.log("live: couldn't save turn \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Tools, run on the server

    private func runTool(_ call: [String: Any]) {
        guard let name = call["name"] as? String else { return }
        let id = call["id"] as? String
        runTool(name: name, args: call["args"] as? [String: Any] ?? [:]) { [weak self] response in
            var functionResponse: [String: Any] = ["name": name, "response": response]
            if let id { functionResponse["id"] = id }
            guard let self, let socket = self.socket,
                  let json = try? Self.json(["toolResponse": ["functionResponses": [functionResponse]]]) else { return }
            try? await socket.send(.string(json))
        }
    }

    /// Runs a tool on the server (or the phone) and hands the result to
    /// `reply`, which sends it back in the provider's own format.
    private func runTool(name: String, args: [String: Any], reply: @escaping @MainActor ([String: Any]) async -> Void) {
        guard let backend else { return }
        let turnId = self.turnId
        let raw = turnUser
        AudioHub.log("live tool: \(name)")
        Task {
            var response: [String: Any]
            do {
                response = try await backend.runTool(name, args, turnId, raw)
            } catch {
                response = ["ok": false, "error": "tool_failed"]
                AudioHub.log("live tool failed: \(name) \(error.localizedDescription)")
            }
            await reply(response)
        }
    }

    // MARK: - The app talking to the coach

    /// Something the coach should know, without answering it ("[app] set 2
    /// logged"). It stays quiet and remembers.
    func note(_ text: String) {
        sendClientTurn("[app] \(text)", respond: false)
    }

    /// A line the app wants said now (a set confirmed, the next exercise):
    /// the coach says it briefly, in its own words.
    @discardableResult
    func say(_ text: String) -> Bool {
        guard socket != nil, state != .idle, state != .connecting else { return false }
        sendClientTurn("[app] Say this to them now, briefly, in your own words: \(text)", respond: true)
        return true
    }

    /// Something you said that the coach didn't hear (the mic was muted for
    /// a count): passed on as your words.
    func forwardUserText(_ text: String) {
        if openAI {
            if turnUser.isEmpty { turnStartedAt = Date() }
            turnUser += text
            sendOpenAIText(text, respond: true)
            return
        }
        guard let socket, let json = try? Self.json(["realtimeInput": ["text": text]]) else { return }
        if turnUser.isEmpty { turnStartedAt = Date() }
        turnUser += text
        socket.send(.string(json)) { _ in }
        AudioHub.log("live: forwarded \"\(text.suffix(50))\"")
    }

    /// Cut the coach off now (you started counting over it).
    func hush() {
        guard state == .speaking else { return }
        if openAI, let socket, let json = try? Self.json(["type": "response.cancel"]) {
            socket.send(.string(json)) { _ in }
        }
        hub.stopPlayback()
        buffersPlaying = 0
        agentMeter.reset()
        uplink.coachSpeaking = false
        state = .listening
        recordTurnIfAny(interrupted: true)
    }

    func setUplinkMuted(_ muted: Bool) {
        guard muted != uplinkMuted else { return }
        uplinkMuted = muted
        uplink.muted = muted
        if muted {
            // Tell the model the stream paused, so it doesn't wait on a
            // half-heard sentence.
            let pause: [String: Any] = openAI ? ["type": "input_audio_buffer.clear"] : ["realtimeInput": ["audioStreamEnd": true]]
            if let socket, let json = try? Self.json(pause) {
                socket.send(.string(json)) { _ in }
            }
        } else {
            unmutedAt = Date()
        }
        AudioHub.log("live: mic to coach \(muted ? "muted (counting)" : "open")")
    }

    private func sendClientTurn(_ text: String, respond: Bool) {
        if openAI {
            sendOpenAIText(text, respond: respond)
            AudioHub.log("live: \(respond ? "say" : "note") \"\(text.suffix(70))\"")
            return
        }
        guard let socket, let json = try? Self.json([
            "clientContent": ["turns": [["role": "user", "parts": [["text": text]]]], "turnComplete": respond],
        ]) else { return }
        socket.send(.string(json)) { _ in }
        AudioHub.log("live: \(respond ? "say" : "note") \"\(text.suffix(70))\"")
    }

    /// A text message into the Realtime conversation; `respond` asks for
    /// a spoken reply to it.
    private func sendOpenAIText(_ text: String, respond: Bool) {
        guard let socket else { return }
        let item: [String: Any] = ["type": "conversation.item.create",
                                   "item": ["type": "message", "role": "user",
                                            "content": [["type": "input_text", "text": text]]]]
        if let json = try? Self.json(item) { socket.send(.string(json)) { _ in } }
        if respond, let json = try? Self.json(["type": "response.create"]) { socket.send(.string(json)) { _ in } }
    }

    // MARK: - Audio out

    private func play(_ buffer: AVAudioPCMBuffer) {
        // You're counting a set (the mic to the coach is muted for it): the
        // coach stays quiet until it's logged, even audio already on its way.
        if uplinkMuted { return }
        if !hub.engine.isRunning { try? hub.start() }
        state = .speaking
        uplink.coachSpeaking = true
        uplink.halfDuplex = !hub.canTalkOver
        buffersPlaying += 1
        agentAnalyzer.process(buffer, into: agentMeter)
        let mine = connection
        hub.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, mine == self.connection || self.reconnecting else { return }
                self.buffersPlaying = max(0, self.buffersPlaying - 1)
                if self.buffersPlaying == 0, self.coachTurnDone {
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

    // MARK: - Audio in

    private func installTap() {
        guard !tapInstalled else { return }
        let input = hub.engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { AudioHub.log("live: no mic"); stop(); return }
        // Gemini takes 16 kHz; OpenAI Realtime 24 kHz.
        let openAI = self.openAI
        uplink.reset(sourceRate: format.sampleRate, targetRate: openAI ? 24_000 : 16_000)
        let uplink = self.uplink
        let box = socketBox
        let meter = youMeter
        let analyzer = MicAnalyzer()
        let side = sideTap
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            side?(buffer)
            analyzer.process(buffer, into: meter)
            guard let chunk = uplink.append(buffer), box.socket != nil else { return }
            let message = openAI
                ? "{\"type\":\"input_audio_buffer.append\",\"audio\":\"\(chunk.base64EncodedString())\"}"
                : "{\"realtimeInput\":{\"audio\":{\"data\":\"\(chunk.base64EncodedString())\",\"mimeType\":\"audio/pcm;rate=16000\"}}}"
            box.send(message)
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
        if openAI {
            forwardUserText(text)
            return
        }
        guard let socket, let json = try? Self.json(["realtimeInput": ["text": text]]) else { return }
        if turnUser.isEmpty { turnStartedAt = Date() }
        turnUser += text
        socket.send(.string(json)) { _ in }
        AudioHub.log("probe: said \"\(text)\"")
    }
    #endif

    private static func json(_ object: [String: Any]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8) ?? "{}"
    }
}

/// The socket the mic tap writes to, swapped on reconnect; read on the
/// audio thread.
private final class SocketBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URLSessionWebSocketTask?
    /// The last ~2 s of mic messages, sent again to the next connection on
    /// a handover so nothing said across it is lost.
    private var recent: [String] = []
    private static let keep = 20
    var socket: URLSessionWebSocketTask? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; if newValue == nil { recent.removeAll() }; lock.unlock() }
    }

    /// A mic message: sent, and remembered for a handover.
    func send(_ message: String) {
        lock.lock()
        let socket = value
        if socket != nil {
            recent.append(message)
            if recent.count > Self.keep { recent.removeFirst(recent.count - Self.keep) }
        }
        lock.unlock()
        socket?.send(.string(message)) { _ in }
    }

    /// The mic moves to `next`: the last two seconds first, then live.
    func moveTo(_ next: URLSessionWebSocketTask) {
        lock.lock()
        let replay = recent
        value = next
        lock.unlock()
        for message in replay { next.send(.string(message)) { _ in } }
    }
}

/// Turns mic buffers into 16 kHz (24 kHz for OpenAI) mono 16-bit chunks of ~100 ms, on the
/// audio thread. On the phone speaker without echo cancellation the mic
/// would hear the coach and cut it off, so there it sends nothing while the
/// coach speaks (half duplex); with headphones or echo cancellation you can
/// talk over it.
private final class MicUplink: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var ratio: Double = 3
    private var chunkBytes = 3_200
    private var _coachSpeaking = false
    private var _halfDuplex = false
    private var _muted = false

    var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _muted }
        set { lock.lock(); _muted = newValue; if newValue { pending.removeAll() }; lock.unlock() }
    }

    var coachSpeaking: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _coachSpeaking }
        set { lock.lock(); _coachSpeaking = newValue; lock.unlock() }
    }
    var halfDuplex: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _halfDuplex }
        set { lock.lock(); _halfDuplex = newValue; lock.unlock() }
    }

    func reset(sourceRate: Double, targetRate: Double = 16_000) {
        lock.lock(); defer { lock.unlock() }
        pending = Data()
        ratio = sourceRate / targetRate
        chunkBytes = Int(targetRate / 10) * 2 // 100 ms, 16-bit
        _coachSpeaking = false
    }

    func append(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength)
        lock.lock(); defer { lock.unlock() }
        if _muted || (_halfDuplex && _coachSpeaking) { pending.removeAll(keepingCapacity: true); return nil }
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
        guard pending.count >= chunkBytes else { return nil }
        let chunk = pending
        pending = Data()
        return chunk
    }
}
