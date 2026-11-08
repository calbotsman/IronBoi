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
///
/// Nothing but the setup and the mic goes on a connection before it's
/// ready (setupComplete / session.created): notes, lines, forwarded text and
/// tool answers queue and flush in order, so the log reads connect → ready →
/// note. If it ends without `stop()` (refused, dropped, timed out, network
/// gone), `onEnded` says why and the stage puts the regular coach back on
/// the mic at once (LiveVoicePolicy).
@MainActor
final class LiveVoiceSession: ObservableObject {
    /// `standby`: connected and ready, but the regular coach still has the
    /// mic until the stage hands it over (`takeMic`).
    enum State: Equatable { case idle, connecting, standby, listening, speaking }

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

    /// The live coach has the mic: it's the one you're talking to.
    var isActive: Bool { state == .listening || state == .speaking }
    /// Connecting, standing by, or active.
    var isRunning: Bool { state != .idle }

    /// Which live voice model: Gemini Live, or OpenAI Realtime for an A/B.
    /// Same coach brain, tools and memory either way.
    enum Provider: String, CaseIterable {
        case gemini, openai
        var label: String { self == .gemini ? "Gemini" : "OpenAI" }
    }
    static let providerKey = "liveVoiceProvider"
    /// The engine the server last gave a live session (its default when
    /// nothing is picked in settings).
    static let servedProviderKey = "liveVoiceServedProvider"
    /// The engine picked on this phone, or nil for the server's default
    /// (what staging serves). Sent only when picked, so the picker never
    /// claims one engine while the server uses the other.
    static var chosenProvider: Provider? {
        Provider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "")
    }
    /// Set while a count is running: the coach's audio is dropped (its mic
    /// can be closed for a whole set, but the exercise intro still has to
    /// play, so playback follows the count, not the mic).
    var quietForCount = false {
        didSet { if !quietForCount { settleOwedAnswer() } }
    }
    /// When you last asked the coach something it should answer.
    private var lastAskedAt = Date.distantPast
    /// What you asked, kept so an unanswered question can be passed on again.
    private var lastAsked = ""
    /// Its answer started while the app had the floor (an app line, a
    /// count) and was dropped before you heard it: it answers again after.
    private var owedAnswer = false
    /// When the coach's voice last actually played.
    private(set) var lastPlayedAt = Date.distantPast
    /// The provider of the connection that's open now.
    private(set) var activeProvider: Provider = .gemini
    private var openAI: Bool { activeProvider == .openai }
    /// OpenAI tool calls still running this turn.
    private var openAIToolsPending = 0
    /// A Realtime response is being generated: a second `response.create`
    /// now would be refused ("active response"), so it waits for
    /// `response.done` (B2).
    private var openAIResponseActive = false
    private var openAIResponseWanted = false

    struct Ticket: Decodable { let token: String; let model: String; let provider: String? }
    struct TurnResult: Decodable { let saved: Bool; let stop: Bool; let line: String? }

    /// The server, as the session needs it.
    struct Backend {
        /// `handover`: a fresh connection mid-conversation (its own cap).
        /// `memoryBriefBuiltAt`: we hold a cached brief and will send it as
        /// the first [app] line, so the server skips reading memory.
        var mint: (_ resumeHandle: String?, _ handover: Bool, _ memoryBriefBuiltAt: String?) async throws -> Ticket
        /// The memory brief cached on disk (MemoryBriefCache), if any.
        var memoryBrief: () -> MemoryBrief?
        var recordTurn: (_ user: String, _ coach: String, _ startedAt: Date, _ interrupted: Bool) async throws -> TurnResult
        var runTool: (_ name: String, _ args: [String: Any], _ turnId: String, _ rawUserText: String) async throws -> [String: Any]
    }

    /// The server's severe screen fired on what you said: the session ends
    /// and the caller says this line.
    var onSafetyStop: ((String) -> Void)?
    /// Connected and ready, in standby: the stage hands over the mic.
    var onReady: (() -> Void)?
    /// It ended without `stop()` — refused, dropped and couldn't come back,
    /// timed out, network gone. The stage carries on with the regular coach.
    var onEnded: ((LiveVoicePolicy.EndReason) -> Void)?
    /// A new connection is up (first one, reconnect or handover): the
    /// caller re-sends where the workout is, so a fresh session (OpenAI
    /// can't resume) never answers about the wrong set.
    var onReconnected: (() -> Void)?
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
    /// Between connections (what you say meanwhile is held and sent on).
    @Published private(set) var reconnecting = false
    /// The connection in use has said it's ready; until then, sends queue.
    private var ready = false
    private var outbox: [(json: String, label: String)] = []
    private var readyTimeout: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var startedAt = Date()
    /// One latency line per answer.
    private var answerAudioLogged = false
    /// How long a connection gets from start (mint + socket + setup) to
    /// ready. Adaptive: 2.5× the slowest of the last few that made it, so a
    /// slow gym connection that does get there isn't cut off, kept between
    /// 6 s and 20 s. 10 s until there's a measurement (Josh's log: mint
    /// alone ~1–3 s, setup a few hundred ms). The regular coach is listening
    /// the whole time, so waiting costs nothing you can hear.
    private static var recentReadyTimes: [Double] = []
    static var readyTimeoutSeconds: Double {
        guard let slowest = recentReadyTimes.max() else { return 10 }
        return min(20, max(6, slowest * 2.5))
    }
    private static func noteReady(after seconds: Double) {
        recentReadyTimes = Array((recentReadyTimes + [seconds]).suffix(5))
    }
    /// A reconnect mid-conversation gets only as long as the mic hold
    /// buffer (SocketBox, ~6 s): past that what you say would be lost, so
    /// the regular coach takes over instead.
    static let reconnectTimeoutSeconds: Double = 6
    /// Reconnects inside this window without the connection staying up
    /// mean it isn't recovering; the policy's backoff takes over (B5).
    /// Real time-limit handovers are ≥ 7.5 min apart.
    private var recentReconnects: [Date] = []
    static let reconnectBurstWindow: TimeInterval = 120
    static let reconnectBurstLimit = 2

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
    private var networkUp = true

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

    // Memory brief: the cached copy waits for setupComplete, then goes in as
    // the first [app] line; a newer one arriving mid-session follows it.
    private var briefToSend: MemoryBrief?
    private var briefInSession: MemoryBrief?
    private var briefObserver: NSObjectProtocol?

    // Time to first coach word, from start(): logged once per session.
    private var firstAudioLogged = false
    /// Connects and starts listening. False if it couldn't (the caller
    /// falls back to the regular coach).
    func start(_ backend: Backend) async -> Bool {
        guard state == .idle else { return true }
        self.backend = backend
        resumeHandle = nil
        caption = ""
        heard = ""
        resetTurn()
        outbox = []
        ready = false
        state = .connecting
        startedAt = Date()
        firstAudioLogged = false
        briefInSession = nil
        observeBriefUpdates()
        watchNetwork()
        armReadyTimeout()
        return await connect(resume: nil)
    }

    private func observeBriefUpdates() {
        if let briefObserver { NotificationCenter.default.removeObserver(briefObserver) }
        briefObserver = NotificationCenter.default.addObserver(forName: MemoryBriefCache.updated, object: nil, queue: .main) { [weak self] note in
            guard let brief = note.object as? MemoryBrief else { return }
            Task { @MainActor in self?.briefUpdated(brief) }
        }
    }

    /// Background refresh landed mid-session: pass on a brief newer than
    /// what the coach has (or, if the server supplied it, newer than the
    /// session itself).
    private func briefUpdated(_ brief: MemoryBrief) {
        guard state != .idle, let built = brief.builtDate else { return }
        let have = briefInSession?.builtDate ?? startedAt
        guard built > have else { return }
        if !ready { briefToSend = brief; return }
        note(brief.appLine(replacing: true))
        briefInSession = brief
    }

    /// Ready and standing by: take the mic. The regular coach must have
    /// let go of its own tap first.
    /// False if it couldn't (no mic input): it has ended, and the caller
    /// must put the regular coach back on the mic.
    @discardableResult
    func takeMic() -> Bool {
        guard state == .standby else { return false }
        state = .listening
        installTap()
        guard tapInstalled else { return false }
        AudioHub.log("live: has the mic (\(Self.ms(since: startedAt)) ms after start)")
        return true
    }

    private func armReadyTimeout(seconds given: Double? = nil) {
        let seconds = given ?? Self.readyTimeoutSeconds
        readyTimeout?.cancel()
        readyTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.ready, self.state != .idle else { return }
            AudioHub.log("live: not ready after \(String(format: "%.1f", seconds)) s")
            self.end(.timeout)
        }
    }

    /// A silent stall (the socket's still "open" but nothing gets through):
    /// a ping every 5 s, each allowed 5× the connection's own round trip
    /// (2–10 s), and only two misses in a row count — one late pong on gym
    /// cellular is normal. And only once a pong has come back on this
    /// connection, so a server that doesn't answer pings can never end a
    /// healthy session. A stall reconnects (or falls back).
    private func keepAlive(_ task: URLSessionWebSocketTask) {
        pingTask?.cancel()
        let box = PongBox()
        pingTask = Task { [weak self] in
            var rtt: Double = 0.5
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self, self.socket === task else { return }
                let sent = Date()
                box.waiting = true
                task.sendPing { error in
                    box.waiting = false
                    if error == nil { box.answered = true; box.answeredAt = Date() }
                }
                let deadline = min(10, max(2, rtt * 5))
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                guard !Task.isCancelled, self.socket === task else { return }
                if !box.waiting, let at = box.answeredAt {
                    rtt = rtt * 0.7 + max(0.05, at.timeIntervalSince(sent)) * 0.3
                    misses = 0
                } else if box.waiting, box.answered {
                    misses += 1
                    AudioHub.log("live: no pong in \(Self.ms(since: sent)) ms (miss \(misses))")
                    if misses >= 2 {
                        AudioHub.log("live: connection stalled")
                        if self.resumeHandle != nil || self.openAI { self.reconnect(reason: "stalled") } else { self.end(.network) }
                        return
                    }
                }
            }
        }
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
        networkUp = interface != nil
        // No network at all (airplane mode, out of range) for a second —
        // not just the blink between Wi-Fi and cellular: nothing to hand
        // over to. End, so the regular coach is listening within ~1 s
        // rather than after the socket times out.
        if interface == nil, state != .idle {
            let mine = connection
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !self.networkUp, self.state != .idle, self.connection >= mine else { return }
                AudioHub.log("live: network lost")
                self.end(.network)
            }
            return
        }
        guard state != .idle, socket != nil, let interface, let before = lastInterface, interface != before else { return }
        AudioHub.log("live: network \(before) → \(interface), handing over now")
        // Go now: the old connection is riding a network that's leaving.
        mustMoveBy = Date()
    }

    /// You ended it. `releaseAudio: false` keeps the audio session up, for
    /// when the regular coach is taking the mic straight back.
    func stop(releaseAudio: Bool = true) {
        teardown(releaseAudio: releaseAudio, why: nil)
    }

    /// It ended on its own: tear down (keeping the audio session for the
    /// regular coach) and say why.
    private func end(_ reason: LiveVoicePolicy.EndReason) {
        guard state != .idle else { return }
        teardown(releaseAudio: false, why: reason)
        onEnded?(reason)
    }

    private func teardown(releaseAudio: Bool, why: LiveVoicePolicy.EndReason?) {
        connection += 1
        ready = false
        outbox = []
        readyTimeout?.cancel()
        readyTimeout = nil
        pingTask?.cancel()
        pingTask = nil
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
        openAIResponseActive = false
        openAIResponseWanted = false
        gapStartedAt = nil
        socketBox.release()
        removeTap()
        uplinkMuted = false
        uplink.muted = false
        // Not left set: live dropped mid-count must not stay silent later.
        owedAnswer = false
        quietForCount = false
        recentReconnects = []
        hub.stopPlayback()
        buffersPlaying = 0
        youMeter.reset()
        agentMeter.reset()
        if state != .idle { AudioHub.log("live: ended\(why.map { " (\($0.rawValue))" } ?? "")") }
        state = .idle
        caption = ""
        reconnecting = false
        briefToSend = nil
        briefInSession = nil
        if let briefObserver { NotificationCenter.default.removeObserver(briefObserver) }
        briefObserver = nil
        if releaseAudio { hub.stop() }
    }

    /// The cached memory brief goes in as the first [app] line once the
    /// connection is up.
    private func sendBriefIfAny() {
        guard let brief = briefToSend else { return }
        note(brief.appLine())
        briefInSession = brief
        briefToSend = nil
    }

    /// A reconnect finished: how long you were without the coach.
    private func endGap() {
        guard let started = gapStartedAt else { return }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        gaps.append(ms)
        gapStartedAt = nil
        AudioHub.log("live: GAP \(ms) ms (\(gapReason))")
    }


    // MARK: - Connecting

    private func connect(resume handle: String?) async -> Bool {
        guard let backend else { return false }
        connection += 1
        let mine = connection
        do {
            let handover = handle != nil || gapStartedAt != nil
            // A fresh session (Gemini new, or any OpenAI one) opens with the
            // cached brief; a resumed one already has it in its context.
            let cached = handle == nil ? backend.memoryBrief() : nil
            if handle == nil { briefToSend = cached }
            let briefAt = cached?.builtAt ?? (handle != nil ? briefInSession?.builtAt : nil)
            let mintStarted = Date()
            let ticket = try await withDeadline(5) { try await backend.mint(handle, handover, briefAt) }
            AudioHub.log("live timing: mint \(Self.ms(since: mintStarted))ms (memory \(cached != nil ? "from phone cache, \(cached!.ageLabel())" : handle != nil ? "resumed" : "from server"))")
            guard mine == connection else { return false }
            AudioHub.log("live timing: mint \(Self.ms(since: mintStarted)) ms")
            model = ticket.model
            activeProvider = Provider(rawValue: ticket.provider ?? "") ?? .gemini
            // Remember which engine the server gave us: with no pick in
            // settings, the phone's own lines must be read by this same
            // engine (VoiceCache.engine), not a guess.
            UserDefaults.standard.set(activeProvider.rawValue, forKey: Self.servedProviderKey)
            // Never retune echo cancellation here: the regular coach may
            // have its tap on the mic right now, and it set the session up.
            try hub.start()
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
                end(.connectFailed)
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
            let handle = openAI ? nil : resumeHandle
            let briefAt = openAI ? nil : briefInSession?.builtAt
            let ticket = try await withDeadline(5) { try await backend.mint(handle, true, briefAt) }
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
            // A new Realtime session: nothing is being generated on it yet.
            openAIResponseActive = false
            socketBox.moveTo(task)
            keepAlive(task)
            let age = Int(Date().timeIntervalSince(connectedAt))
            connectedAt = Date()
            mustMoveBy = nil
            handovers += 1
            onReconnected?()
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
        // Dropping again and again right after coming back: it isn't
        // recovering. End, so the policy's backoff (and its cap) decides
        // when to mint again, instead of a mint per drop.
        let now = Date()
        recentReconnects = recentReconnects.filter { now.timeIntervalSince($0) < Self.reconnectBurstWindow } + [now]
        if recentReconnects.count > Self.reconnectBurstLimit {
            AudioHub.log("live: \(recentReconnects.count) reconnects in \(Int(Self.reconnectBurstWindow)) s — backing off")
            end(.closed)
            return
        }
        reconnecting = true
        if gapStartedAt == nil { gapStartedAt = Date(); gapReason = reason }
        socketBox.hold()
        // A handover in progress is moot now; don't leave its spare open.
        standby?.cancel(with: .normalClosure, reason: nil)
        standby = nil
        standbyReady = false
        AudioHub.log("live: reconnecting (\(reason))")
        let old = socket
        socketBox.socket = nil
        ready = false
        armReadyTimeout(seconds: Self.reconnectTimeoutSeconds)
        Task {
            let ok = await connect(resume: resumeHandle)
            old?.cancel(with: .normalClosure, reason: nil)
            reconnecting = false
            if !ok, state != .idle {
                AudioHub.log("live: reconnect failed")
                end(.connectFailed)
            }
        }
    }

    // MARK: - Receiving

    /// Reads a connection off the main thread: each message is parsed and
    /// its audio decoded on URLSession's queue, the next receive is armed at
    /// once, and only the result goes to the main thread, in order. Before,
    /// the parse, base64 and PCM conversion ran on main and the next receive
    /// waited for them, so any main-thread work (the stage redrawing, the
    /// shader) gapped or delayed the coach's voice.
    private func receive(on task: URLSessionWebSocketTask, connection mine: Int) {
        Self.pump(task) { [weak self] incoming in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, mine == self.connection else { return }
                    // An old connection after a handover: done with it.
                    let current = task === self.socket, spare = task === self.standby
                    guard current || spare || self.socket == nil else { return }
                    switch incoming {
                    case .failure(let error):
                        if spare {
                            AudioHub.log("live: handover connection closed \(error.localizedDescription)")
                            self.standby = nil
                            return
                        }
                        AudioHub.log("live: socket closed \(error.localizedDescription)")
                        if self.state != .idle, self.ready, self.resumeHandle != nil || self.openAI {
                            self.reconnect(reason: "closed")
                        } else {
                            self.end(self.ready ? .closed : .connectFailed)
                        }
                    case .success(let message):
                        let waited = Self.ms(since: message.receivedAt)
                        if waited >= 50 { AudioHub.log("live timing: message waited \(waited) ms for the main thread") }
                        self.handle(message.object, audio: message.audio, socket: task)
                    }
                }
            }
        }
    }

    /// One received message, already parsed, with its audio decoded.
    private struct Incoming: @unchecked Sendable {
        let object: [String: Any]
        let audio: [AVAudioPCMBuffer]
        let receivedAt: Date
    }

    nonisolated private static func pump(_ task: URLSessionWebSocketTask,
                                         deliver: @escaping @Sendable (Result<Incoming, Error>) -> Void) {
        task.receive { result in
            switch result {
            case .failure(let error):
                deliver(.failure(error))
            case .success(let message):
                // The next one is armed before this one is even parsed.
                pump(task, deliver: deliver)
                let receivedAt = Date()
                let data: Data?
                switch message {
                case .string(let text): data = text.data(using: .utf8)
                case .data(let raw): data = raw
                @unknown default: data = nil
                }
                guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                deliver(.success(Incoming(object: object, audio: decodeAudio(in: object), receivedAt: receivedAt)))
            }
        }
    }

    /// The coach's audio in a message, Gemini's or OpenAI's, as buffers.
    nonisolated private static func decodeAudio(in object: [String: Any]) -> [AVAudioPCMBuffer] {
        if let type = object["type"] as? String {
            guard type == "response.output_audio.delta" || type == "response.audio.delta",
                  let b64 = object["delta"] as? String, let pcm = Data(base64Encoded: b64),
                  let buffer = buffer(fromPCM16: pcm) else { return [] }
            return [buffer]
        }
        guard let content = object["serverContent"] as? [String: Any],
              let parts = (content["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] else { return [] }
        return parts.compactMap { part in
            guard let inline = part["inlineData"] as? [String: Any],
                  let b64 = inline["data"] as? String,
                  let pcm = Data(base64Encoded: b64) else { return nil }
            return buffer(fromPCM16: pcm)
        }
    }

    /// The connection in use is up: send what queued, then either carry on
    /// (a reconnect — the mic never stopped) or stand by for the stage.
    private func markReady(_ task: URLSessionWebSocketTask, label: String) {
        guard !ready else { return }
        ready = true
        readyTimeout?.cancel()
        readyTimeout = nil
        AudioHub.log("live: ready\(label) (\(Self.ms(since: startedAt)) ms after start)")
        if !tapInstalled { Self.noteReady(after: Date().timeIntervalSince(startedAt)) }
        endGap()
        socketBox.attach(task)
        keepAlive(task)
        // The memory brief is the first [app] line, then whatever queued.
        sendBriefIfAny()
        flushOutbox(to: task)
        onReconnected?()
        if tapInstalled {
            if state == .connecting { state = .listening }
        } else if state == .connecting {
            state = .standby
            onReady?()
        }
    }

    private func handle(_ message: [String: Any], audio: [AVAudioPCMBuffer], socket task: URLSessionWebSocketTask) {
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
            handleOpenAI(message, audio: audio, socket: task)
            return
        }
        if let error = message["error"] as? [String: Any] {
            AudioHub.log("live: provider error \(error["code"] ?? "?") \(String(describing: error["status"] ?? ""))")
            end(.providerError)
            return
        }
        if message["setupComplete"] != nil {
            markReady(task, label: "")
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
            answerAudioLogged = false
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
        for buffer in audio {
            if coachTurnDone { caption = ""; coachTurnDone = false }
            if !firstAudioLogged {
                firstAudioLogged = true
                AudioHub.log("live timing: first coach audio \(Self.ms(since: startedAt))ms after start, \(Self.ms(since: turnStartedAt))ms after you started speaking")
            }
            play(buffer)
        }
        if let output = (content["outputTranscription"] as? [String: Any])?["text"] as? String {
            if coachTurnDone { caption = ""; coachTurnDone = false }
            caption += output
            turnCoach += output
        }
        if content["turnComplete"] as? Bool == true {
            coachTurnDone = true
            answerAudioLogged = false
            if buffersPlaying == 0 { state = .listening; uplink.coachSpeaking = false }
            // A turn that only called a tool has nothing said yet: keep it
            // open so the exchange is saved whole once the coach answers.
            if !turnCoach.isEmpty { recordTurnIfAny(interrupted: false) }
        }
    }

    /// OpenAI Realtime's events, mapped onto the same turn-taking as Gemini's.
    private func handleOpenAI(_ message: [String: Any], audio: [AVAudioPCMBuffer], socket task: URLSessionWebSocketTask) {
        let type = message["type"] as? String ?? ""
        switch type {
        case "error":
            let error = message["error"] as? [String: Any]
            AudioHub.log("live: OpenAI error \(error?["code"] ?? error?["type"] ?? "?") \(String(describing: error?["message"] ?? "").prefix(120))")
            // Before the session is up, an error means it never will be.
            if !ready { end(.providerError) }
        case "session.created", "session.updated":
            openAIResponseActive = false
            markReady(task, label: " (OpenAI)")
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
            answerAudioLogged = false
            AudioHub.log("live: interrupted")
            recordTurnIfAny(interrupted: true)
        case "conversation.item.input_audio_transcription.completed":
            guard let input = message["transcript"] as? String, !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            if coachTurnDone, !turnCoach.isEmpty { recordTurnIfAny(interrupted: false) }
            if turnUser.isEmpty { turnStartedAt = Date() }
            turnUser += (turnUser.isEmpty ? "" : " ") + input
            heard = turnUser
        case "response.output_audio.delta", "response.audio.delta":
            // Decoded off the main thread, in `pump`.
            for buffer in audio {
                if coachTurnDone { caption = ""; coachTurnDone = false }
                play(buffer)
            }
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            guard let delta = message["delta"] as? String else { return }
            if coachTurnDone { caption = ""; coachTurnDone = false }
            caption += delta
            turnCoach += delta
        case "response.created":
            openAIResponseActive = true
        case "response.done":
            openAIResponseActive = false
            let response = message["response"] as? [String: Any]
            let status = response?["status"] as? String ?? "completed"
            coachTurnDone = true
            answerAudioLogged = false
            if buffersPlaying == 0 { state = .listening; uplink.coachSpeaking = false }
            if !turnCoach.isEmpty { recordTurnIfAny(interrupted: false) }
            // Tools run from the finished response, and only if it finished:
            // a response cut off by barge-in (status "cancelled") still
            // emits its calls, and one of them could be replace_session.
            let calls = (response?["output"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "function_call" }
            if status == "completed" {
                for call in calls { runOpenAITool(call) }
            } else if !calls.isEmpty {
                AudioHub.log("live: \(calls.count) tool call(s) dropped — response \(status)")
            }
            if openAIResponseWanted, openAIToolsPending == 0 { requestOpenAIResponse() }
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
            guard let self, self.state != .idle,
                  let json = try? Self.json(["toolResponse": ["functionResponses": [functionResponse]]]) else { return }
            self.send(json, label: "tool \(name) answer")
        }
    }

    /// Runs a tool on the server (or the phone) and hands the result to
    /// `reply`, which sends it back in the provider's own format.
    private func runTool(name: String, args: [String: Any], reply: @escaping @MainActor ([String: Any]) async -> Void) {
        guard let backend else { return }
        let turnId = self.turnId
        let raw = turnUser
        AudioHub.log("live tool: \(name)")
        lastToolAt = Date()
        toolsInFlight += 1
        Task {
            var response: [String: Any]
            do {
                response = try await backend.runTool(name, args, turnId, raw)
            } catch {
                response = ["ok": false, "error": "tool_failed"]
                AudioHub.log("live tool failed: \(name) \(error.localizedDescription)")
            }
            await reply(response)
            self.toolsInFlight -= 1
        }
    }
    /// When a tool last started, and how many are still running: a re-ask
    /// must never land while one is in flight or after one ran for the
    /// question, or "add a set" happens twice (watchdog F53).
    private var lastToolAt = Date.distantPast
    private var toolsInFlight = 0

    // MARK: - The app talking to the coach

    /// The phone is about to say an app line itself ("Set 2 done, rest
    /// ninety seconds"): live goes quiet for about as long as that takes —
    /// anything it was saying is dropped — and is told what was said.
    private var quietUntil = Date.distantPast
    func yieldTo(_ line: String) {
        let seconds = min(14, 1.0 + Double(line.split(separator: " ").count) * 0.4)
        quietUntil = Date().addingTimeInterval(seconds)
        if state == .speaking || buffersPlaying > 0 {
            hub.stopPlayback()
            buffersPlaying = 0
            agentMeter.reset()
            uplink.coachSpeaking = false
            if state == .speaking { state = .listening }
        }
        sendClientTurn("[app] The app just said this to them out loud, in your voice: \"\(line)\" Don't repeat it.", respond: false)
    }

    /// Something the coach should know, without answering it ("[app] set 2
    /// logged"). It stays quiet and remembers.
    func note(_ text: String) {
        sendClientTurn("[app] \(text)", respond: false)
    }

    /// A line the app wants said now (a set confirmed, the next exercise):
    /// the coach says it briefly, in its own words.
    @discardableResult
    func say(_ text: String) -> Bool {
        guard isActive else { return false }
        sendClientTurn("[app] Say this to them now, briefly, in your own words: \(text)", respond: true)
        return true
    }

    /// Something you said that the coach didn't hear (the mic was muted for
    /// a count): passed on as your words.
    func forwardUserText(_ text: String) {
        noteAsked(text)
        if openAI {
            if turnUser.isEmpty { turnStartedAt = Date() }
            turnUser += text
            sendOpenAIText(text, respond: true)
            return
        }
        guard state != .idle, let json = try? Self.json(["realtimeInput": ["text": text]]) else { return }
        if turnUser.isEmpty { turnStartedAt = Date() }
        turnUser += text
        send(json, label: "forwarded \"\(text.suffix(50))\"")
    }

    /// You asked the coach something (it heard you directly, or it was
    /// passed on). If no answer plays within a few seconds, and nothing had
    /// the floor, the question goes to it again — once. Mid-workout,
    /// questions were vanishing: the answer was dropped under an app line
    /// or never started, and nothing noticed.
    func expectAnswer(to text: String) {
        noteAsked(text)
        let asked = lastAskedAt
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.isActive, self.lastAskedAt == asked else { return }
            guard self.lastPlayedAt < asked, self.state != .speaking, !self.owedAnswer,
                  !self.quietForCount, Date() >= self.quietUntil else { return }
            // Something is still working on it, or already acted on it: a
            // re-ask now could repeat the action.
            guard !self.openAIResponseActive, self.openAIToolsPending == 0,
                  self.toolsInFlight == 0, self.lastToolAt < asked else { return }
            AudioHub.log("live: no answer in 8 s, asking again: \"\(text.suffix(50))\"")
            self.sendClientTurn("[app] They asked you this and haven't heard an answer: \"\(text)\" Answer it now, briefly. Answer only: don't repeat or take any action.", respond: true)
        }
    }

    private func noteAsked(_ text: String) {
        lastAskedAt = Date()
        lastAsked = text
    }

    /// An answer dropped while the app had the floor: say it now that the
    /// floor is free.
    private func settleOwedAnswer() {
        guard owedAnswer, isActive, !quietForCount, Date() >= quietUntil else { return }
        // Still working on it (a response or a tool in flight): wait for
        // that to finish rather than talk over it or start it again.
        if openAIResponseActive || openAIToolsPending > 0 || toolsInFlight > 0 {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.settleOwedAnswer()
            }
            return
        }
        owedAnswer = false
        AudioHub.log("live: answering again after it was cut off")
        let question = lastAsked.isEmpty ? "" : " They asked: \"\(lastAsked)\""
        // A tool already ran for it (a set added, a lift swapped): the cut-off
        // audio was its confirmation. Say it, never do it again.
        let done = lastToolAt >= lastAskedAt ? " What they asked for is already done; just tell them." : ""
        sendClientTurn("[app] Your answer to what they just asked was cut off before they heard it.\(question)\(done) Answer it now, briefly. Answer only: don't repeat or take any action.", respond: true)
    }

    /// Cut the coach off now (you started counting over it).
    func hush() {
        guard state == .speaking else { return }
        if openAI, ready, let socket, let json = try? Self.json(["type": "response.cancel"]) {
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
            // Only on a ready connection: queued, it would mean nothing.
            if ready, let socket, let json = try? Self.json(pause) {
                socket.send(.string(json)) { _ in }
            }
        } else {
            unmutedAt = Date()
        }
        AudioHub.log("live: mic to coach \(muted ? "muted (counting)" : "open")")
    }

    private func sendClientTurn(_ text: String, respond: Bool) {
        let label = "\(respond ? "say" : "note") \"\(text.suffix(70))\""
        if openAI {
            sendOpenAIText(text, respond: respond, label: label)
            return
        }
        guard state != .idle, let json = try? Self.json([
            "clientContent": ["turns": [["role": "user", "parts": [["text": text]]]], "turnComplete": respond],
        ]) else { return }
        send(json, label: label)
    }

    /// Everything but the setup and the mic goes through here: straight out
    /// once the connection is ready, queued in order until then.
    private func send(_ json: String, label: String) {
        guard ready, let socket else {
            outbox.append((json, label))
            AudioHub.log("live: queued until ready: \(label)")
            return
        }
        socket.send(.string(json)) { error in
            if let error {
                let text = "live: send failed (\(label.prefix(30))): \(error.localizedDescription)"
                Task { @MainActor in AudioHub.log(text) }
            }
        }
        AudioHub.log("live: \(label)")
    }

    private func flushOutbox(to task: URLSessionWebSocketTask) {
        let queued = outbox
        outbox = []
        for item in queued {
            task.send(.string(item.json)) { error in
                if let error {
                    let text = "live: send failed (\(item.label.prefix(30))): \(error.localizedDescription)"
                    Task { @MainActor in AudioHub.log(text) }
                }
            }
            AudioHub.log("live: \(item.label) (sent after ready)")
        }
    }

    /// A text message into the Realtime conversation; `respond` asks for
    /// a spoken reply to it.
    /// A Realtime tool call from a completed response: runs, answers with
    /// its output, and once every call of the turn has answered, asks for
    /// one reply.
    private func runOpenAITool(_ call: [String: Any]) {
        guard let name = call["name"] as? String, let callId = call["call_id"] as? String else { return }
        let raw = (call["arguments"] as? String)?.data(using: .utf8)
        let args = raw.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        openAIToolsPending += 1
        runTool(name: name, args: args) { [weak self] response in
            guard let self else { return }
            self.openAIToolsPending = max(0, self.openAIToolsPending - 1)
            guard self.state != .idle else { return }
            let output = (try? Self.json(response)) ?? "{}"
            let item: [String: Any] = ["type": "conversation.item.create",
                                       "item": ["type": "function_call_output", "call_id": callId, "output": output]]
            if let json = try? Self.json(item) { self.send(json, label: "tool \(name) answer") }
            if self.openAIToolsPending == 0 { self.requestOpenAIResponse() }
        }
    }

    /// `response.create`, unless a response is still being generated: then
    /// it's sent the moment that one is done (B2).
    private func requestOpenAIResponse() {
        guard !openAIResponseActive else {
            openAIResponseWanted = true
            return
        }
        openAIResponseWanted = false
        guard let json = try? Self.json(["type": "response.create"]) else { return }
        send(json, label: "response")
    }

    private func sendOpenAIText(_ text: String, respond: Bool, label: String? = nil) {
        guard state != .idle else { return }
        let item: [String: Any] = ["type": "conversation.item.create",
                                   "item": ["type": "message", "role": "user",
                                            "content": [["type": "input_text", "text": text]]]]
        if let json = try? Self.json(item) { send(json, label: label ?? "text \"\(text.suffix(50))\"") }
        if respond { requestOpenAIResponse() }
    }

    // MARK: - Audio out

    private func play(_ buffer: AVAudioPCMBuffer) {
        // You're counting a set (the mic to the coach is muted for it): the
        // coach stays quiet until it's logged, even audio already on its way.
        if quietForCount || Date() < quietUntil {
            // Dropping an answer to something just asked: owe it, and say
            // it once the floor is free (an app line ends, a count closes).
            if !owedAnswer, Date().timeIntervalSince(lastAskedAt) < 20 {
                owedAnswer = true
                AudioHub.log("live: answer dropped under an app line or a count; will answer after")
                let wait = max(0, quietUntil.timeIntervalSinceNow) + 0.3
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    self?.settleOwedAnswer()
                }
            }
            return
        }
        lastPlayedAt = Date()
        // Standing by: the regular coach still has the stage.
        if state == .standby || state == .connecting { return }
        if !answerAudioLogged {
            answerAudioLogged = true
            let spokeUntil = uplink.lastVoiceAt
            if Date().timeIntervalSince(spokeUntil) < 15 {
                AudioHub.log("live latency: speech end → coach audio \(Self.ms(since: spokeUntil)) ms")
            }
        }
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
    nonisolated static func buffer(fromPCM16 data: Data) -> AVAudioPCMBuffer? {
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
        guard format.sampleRate > 0 else { AudioHub.log("live: no mic"); end(.noMic); return }
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
            // No socket check: between connections SocketBox holds the
            // audio (up to ~6 s) and sends it once the next one is ready.
            guard let chunk = uplink.append(buffer) else { return }
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
        guard let json = try? Self.json(["realtimeInput": ["text": text]]) else { return }
        if turnUser.isEmpty { turnStartedAt = Date() }
        turnUser += text
        send(json, label: "probe: said \"\(text)\"")
    }
    #endif

    private static func ms(since date: Date) -> Int { Int((Date().timeIntervalSince(date) * 1000).rounded()) }

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

    /// Between connections (a reconnect): the mic is held, up to ~6 s,
    /// and sent once the next one is up — a dropped second loses nothing.
    private var holding = false
    private var held: [String] = []
    private static let holdMax = 60

    /// A mic message: sent, and remembered for a handover — or held, if
    /// the connection is being replaced.
    func send(_ message: String) {
        lock.lock()
        if holding {
            held.append(message)
            if held.count > Self.holdMax { held.removeFirst(held.count - Self.holdMax) }
            lock.unlock()
            return
        }
        let socket = value
        if socket != nil {
            recent.append(message)
            if recent.count > Self.keep { recent.removeFirst(recent.count - Self.keep) }
        }
        lock.unlock()
        socket?.send(.string(message)) { _ in }
    }

    /// The connection dropped: hold the mic (with the last two seconds, in
    /// case they never arrived) until `attach`.
    func hold() {
        lock.lock()
        if !holding {
            holding = true
            held = recent
            recent = []
        }
        lock.unlock()
    }

    /// The new connection is up: what was held goes first, then live.
    func attach(_ next: URLSessionWebSocketTask) {
        lock.lock()
        let backlog = holding ? held : []
        holding = false
        held = []
        value = next
        lock.unlock()
        for message in backlog { next.send(.string(message)) { _ in } }
    }

    func release() {
        lock.lock()
        holding = false
        held = []
        value = nil
        recent = []
        lock.unlock()
    }

    /// The mic moves to `next`: the last two seconds first, then live.
    fileprivate func moveTo(_ next: URLSessionWebSocketTask) {
        lock.lock()
        let replay = recent
        value = next
        lock.unlock()
        for message in replay { next.send(.string(message)) { _ in } }
    }
}

/// Whether a ping is still unanswered, and whether any ever was answered.
private final class PongBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _waiting = false
    private var _answered = false
    var waiting: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _waiting }
        set { lock.lock(); _waiting = newValue; lock.unlock() }
    }
    var answered: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _answered }
        set { lock.lock(); _answered = newValue; lock.unlock() }
    }
    private var _answeredAt: Date?
    var answeredAt: Date? {
        get { lock.lock(); defer { lock.unlock() }; return _answeredAt }
        set { lock.lock(); _answeredAt = newValue; lock.unlock() }
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
    private var _lastVoiceAt = Date.distantPast

    /// The last time the mic heard speech-level sound going to the coach:
    /// roughly when you stopped talking, for the latency line.
    var lastVoiceAt: Date {
        lock.lock(); defer { lock.unlock() }; return _lastVoiceAt
    }

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
        var energy: Float = 0
        for i in 0..<count { energy += channel[i] * channel[i] }
        // About -40 dBFS: speech close to the phone, above room noise.
        if energy / Float(max(count, 1)) > 0.0001 { _lastVoiceAt = Date() }
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
