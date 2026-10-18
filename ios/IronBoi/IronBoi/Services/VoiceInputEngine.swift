import AVFoundation
import Foundation
import Speech

@MainActor
final class VoiceInputEngine: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published var errorMessage: String?

    /// Live mic loudness and syllable onsets, for the orb.
    let meter = VoiceMeter()
    /// Called once with the final text when the speaker pauses — the user
    /// talks, stops, and the message sends without a tap.
    var onPause: ((String) -> Void)?
    private var pauseTask: Task<Void, Never>?
    /// While true, a pause doesn't end the utterance — set during a rep
    /// count, where the gaps between reps are long and expected.
    var holdOpen = false {
        didSet {
            if holdOpen {
                pauseTask?.cancel()
                scheduleRotation()
            } else {
                rotationTask?.cancel()
                rotationTask = nil
                if isListening, !transcript.isEmpty { schedulePauseCheck() }
            }
        }
    }
    private static let pauseSeconds: UInt64 = 1_400_000_000
    /// Added to every pause — set where answers run long (onboarding).
    var extraPause: UInt64 = 0

    /// How long a quiet stretch ends your turn. A finished sentence ("…
    /// seated?") goes quickly; a short command ("set done") nearly as
    /// quickly; anything mid-thought ("the dumbbell shoulder press, the
    /// one that I'm…") gets room, so one thought isn't sent as two.
    static func pauseDelay(after text: String) -> UInt64 {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = t.last, ".?!".contains(last) { return 1_100_000_000 }
        if t.split(separator: " ").count <= 2 { return pauseSeconds }
        return 2_100_000_000
    }
    /// A set can run a minute or more on one open request, and the
    /// recogniser goes quiet on a request that old: while a count is held
    /// open, the request is swapped for a fresh one this often. The tap
    /// stays; the count carries over (a blank transcript tells the count
    /// to continue from where it was).
    private static let rotationSeconds: UInt64 = 25_000_000_000
    private var rotationTask: Task<Void, Never>?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    /// Shared with Coach's voice so the mic can stay open while Coach talks.
    private var audioEngine: AVAudioEngine { AudioHub.shared.engine }
    private var request: SFSpeechAudioBufferRecognitionRequest? {
        didSet { requestBox.current = request }
    }
    /// What the mic tap appends to — read on the audio thread, so it lives
    /// outside the main actor behind a lock.
    private let requestBox = RequestBox()
    private var recognitionTask: SFSpeechRecognitionTask?
    /// The newer recogniser's listen (iOS 26, once its model is on the
    /// phone); the old SFSpeech request otherwise.
    private var analyzerRecognition: AnyObject?
    /// Bumped on every new recognition request; a callback from an older
    /// request is ignored (its "final" must not stop a fresh one).
    private var requestGeneration = 0
    /// The recogniser (iOS 26, on device) hands over each utterance on its
    /// own: after a pause, the next result is just "Two", not "One two".
    /// Everything downstream reads a running transcript, so finished
    /// utterances are kept here and the live one is appended.
    private var settledUtterances = ""
    private var liveUtterance = ""
    private var liveUtteranceStart: TimeInterval = -1
    /// The mic tap stays installed for a whole conversation: taking it off
    /// between sentences made iOS shut the microphone down and bring it
    /// back each time (the indicator blinking, a deaf moment after every
    /// pause). Between listens its buffers simply go nowhere.
    private var hasInstalledTap = false
    private var tapFormat: AVAudioFormat?
    private var resetObserver: NSObjectProtocol?
    /// Bumped on every stop; callbacks and starts carry the value they began
    /// with and drop out if it's moved on.
    private var session = 0
    /// Starting the mic failed (no input, a call, a route change).
    var onFailure: (() -> Void)?

    /// Starts listening if it isn't already (safe to call while Coach talks).
    func listen() {
        guard !isListening else { return }
        toggle()
    }

    func toggle() {
        #if DEBUG
        // MYO_NO_MIC=1: never open the mic — for watching Coach in the
        // simulator, whose mic hears the Mac's speakers.
        if ProcessInfo.processInfo.environment["MYO_NO_MIC"] == "1", !isListening, Self.fakeUtterances.isEmpty { return }
        #endif
        if isListening {
            stop()
            return
        }

        Task {
            // A fresh listen: an earlier failure no longer applies.
            errorMessage = nil
            do {
                try await start()
            } catch {
                // A route still settling (AirPods just connected, a call
                // just ended) refuses the session once; it usually takes
                // a moment later. One retry before giving up.
                AudioHub.log("listen failed: \(error.localizedDescription) — retrying once")
                let before = session
                // Start the retry from nothing: a tap or engine left over
                // from the failed attempt is the usual cause (-50).
                removeTap()
                if audioEngine.isRunning { audioEngine.stop() }
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard session == before else { return }
                do {
                    try await start()
                } catch {
                    // Still refused: rebuild the audio from scratch, without
                    // echo cancellation, and try a last time.
                    AudioHub.log("listen failed again: \(error.localizedDescription) — rebuilding audio")
                    AudioHub.shared.recover()
                    removeTap()
                    guard session == before else { return }
                    do {
                        try await start()
                    } catch {
                        errorMessage = error.localizedDescription
                        AudioHub.log("listen failed: \(error.localizedDescription)")
                        stop()
                        onFailure?()
                    }
                }
            }
        }
    }

    init() {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { AnalyzerRecognition.prepare() }
        #endif
        // Audio was rebuilt under us (AirPods in or out, a call): the tap's
        // format is stale, so take it off; the next listen puts a new one on.
        resetObserver = NotificationCenter.default.addObserver(
            forName: AudioHub.resetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeTap() }
        }
    }

    /// Ends this listen. The microphone itself stays open (see
    /// `hasInstalledTap`); `release()` closes it when the conversation ends.
    func stop() {
        // Anything still in flight from this listen is now stale.
        session += 1
        pauseTask?.cancel()
        pauseTask = nil
        rotationTask?.cancel()
        rotationTask = nil
        meter.reset()
        endRecognition()
        isListening = false
    }

    /// Ends whichever recogniser this listen is on; the tap keeps running.
    private func endRecognition() {
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let recognition = analyzerRecognition as? AnalyzerRecognition {
            recognition.cancel()
        }
        #endif
        analyzerRecognition = nil
        requestBox.current = nil
    }

    /// Live voice owns the mic tap during a workout and hands every buffer
    /// here, so counting and local commands keep working on the phone.
    private(set) var externalFeed = false
    lazy var audioSink: (AVAudioPCMBuffer) -> Void = { [box = requestBox, meter = self.meter] in
        let analyzer = MicAnalyzer()
        return { buffer in
            guard let request = box.current else { return }
            request.append(buffer)
            analyzer.process(buffer, into: meter)
        }
    }()

    func useExternalFeed(_ on: Bool) {
        if on { removeTap() }
        externalFeed = on
    }

    /// The conversation is over: stop listening and close the microphone.
    func release() {
        stop()
        removeTap()
    }

    private func removeTap() {
        guard hasInstalledTap else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        hasInstalledTap = false
        tapFormat = nil
    }

    private func start() async throws {
        #if DEBUG
        if playFakeUtteranceIfAny() { return }
        #endif
        let before = session
        try await requestPermissions()
        // Stopped (conversation ended) while we waited for permission: don't
        // open the mic after all.
        guard session == before else { return }
        stop()
        let mine = session

        // Only when our tap is off (a new conversation, or audio was
        // rebuilt) may the hub retune echo cancellation; with the tap on,
        // retuning would pull the format out from under it.
        try AudioHub.shared.start(reconfigure: !hasInstalledTap && !externalFeed)
        guard !AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty else {
            throw VoiceInputError.microphoneUnavailable
        }

        beginRequest(session: mine)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceInputError.microphoneUnavailable
        }

        if hasInstalledTap, let tapFormat, tapFormat != format { removeTap() }
        if !hasInstalledTap, !externalFeed {
            let meter = self.meter
            let analyzer = MicAnalyzer()
            let box = requestBox
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                // Between listens the mic is open but nothing is listening:
                // the buffers go nowhere, and the orb doesn't react.
                guard let request = box.current else { return }
                request.append(buffer)
                analyzer.process(buffer, into: meter)
            }
            hasInstalledTap = true
            tapFormat = format
            AudioHub.log("mic opened")
        }
        isListening = true
        if holdOpen { scheduleRotation() }
    }

    /// The words a workout is made of, so the recogniser leans toward
    /// them: a count ("seven" over "heaven"), and the set being called.
    private static let workoutWords: [String] = [
        "MYO", "Coach", "set done", "sets done", "done", "reps", "skip rest", "I can't", "too heavy", "seconds", "pounds", "go",
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
        "eighteen", "nineteen", "twenty",
    ]

    /// A new recognition request on the open mic. `session` is the listen
    /// it belongs to; the request's own generation keeps a late result from
    /// an earlier request away from this one.
    private func beginRequest(session mine: Int) {
        requestGeneration += 1
        let generation = requestGeneration
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), AnalyzerRecognition.ready {
            transcript = ""
            settledUtterances = ""
            liveUtterance = ""
            liveUtteranceStart = -1
            beginAnalyzer(session: mine, generation: generation)
            return
        }
        #endif
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // On the phone where it can: the mic can be open for a whole
        // workout, so keep that audio off the network (and off a weak gym
        // connection).
        // (Not in the simulator: it claims support but has no model, and
        // every request fails a few seconds in.)
        #if !targetEnvironment(simulator)
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        #endif
        request.contextualStrings = Self.workoutWords
        self.request = request
        transcript = ""
        settledUtterances = ""
        liveUtterance = ""
        liveUtteranceStart = -1

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                // A late callback from an earlier listen or an earlier
                // request must not touch this one.
                guard let self, self.session == mine, self.requestGeneration == generation else { return }

                if let result,
                   case let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty, text != self.liveUtterance {
                    let start = result.bestTranscription.segments.first?.timestamp ?? -1
                    if !self.liveUtterance.isEmpty,
                       Self.isNewUtterance(text, after: self.liveUtterance, start: start, previousStart: self.liveUtteranceStart) {
                        self.settledUtterances = (self.settledUtterances + " " + self.liveUtterance)
                            .trimmingCharacters(in: .whitespaces)
                    }
                    self.liveUtterance = text
                    self.liveUtteranceStart = start
                    let whole = (self.settledUtterances + " " + text).trimmingCharacters(in: .whitespaces)
                    if whole != self.transcript {
                        self.transcript = whole
                        // Every partial, so a device test shows exactly what the
                        // recogniser made of a count.
                        AudioHub.log("heard: \(text.suffix(60)) @\(String(format: "%.1f", start)) → \(whole.suffix(60))")
                        self.schedulePauseCheck()
                    }
                }

                if error != nil || result?.isFinal == true {
                    if let error { AudioHub.log("recogniser ended: \(error.localizedDescription)") }
                    if self.holdOpen {
                        // Mid-count: the recogniser gave up on this
                        // request (quiet too long, or just old). Keep the
                        // mic open and start it a fresh one; the count
                        // carries over.
                        self.rotateRequest()
                    } else {
                        self.stop()
                    }
                }
            }
        }
    }

    #if compiler(>=6.2)
    /// A listen on the newer recogniser: one continuous stream, so it needs
    /// no utterance stitching and no rotation mid-count.
    @available(iOS 26.0, *)
    private func beginAnalyzer(session mine: Int, generation: Int) {
        let recognition = AnalyzerRecognition(words: Self.workoutWords, onText: { [weak self] whole in
            Task { @MainActor in
                guard let self, self.session == mine, self.requestGeneration == generation,
                      whole != self.transcript else { return }
                self.transcript = whole
                AudioHub.log("heard (analyzer): \(whole.suffix(60))")
                self.schedulePauseCheck()
            }
        }, onEnd: { [weak self] error in
            Task { @MainActor in
                guard let self, self.session == mine, self.requestGeneration == generation else { return }
                AudioHub.log("analyzer ended: \(error?.localizedDescription ?? "finished")")
                if self.holdOpen { self.rotateRequest() } else { self.stop() }
            }
        })
        analyzerRecognition = recognition
        requestBox.current = recognition
    }
    #endif

    /// Is this result a new utterance, or a revision of the one in
    /// progress? A revision keeps the same start time and most of its
    /// opening words ("one two tree" → "one two three"); a new utterance
    /// starts later, or shares nothing with what it replaces ("One" →
    /// "Two"). Start times are used when the recogniser gives them.
    static func isNewUtterance(_ text: String, after current: String, start: TimeInterval, previousStart: TimeInterval) -> Bool {
        if start >= 0, previousStart >= 0, abs(start - previousStart) > 0.75 { return true }
        let new = text.lowercased(), cur = current.lowercased()
        if new.hasPrefix(cur) { return false }
        let newWords = new.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let curWords = cur.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !newWords.isEmpty, !curWords.isEmpty else { return false }
        // A revision doesn't lose most of its words; "One two three" → "One"
        // is the next utterance starting with the same word.
        if newWords.count * 2 < curWords.count { return true }
        let shared = zip(newWords, curWords).prefix { $0 == $1 }.count
        if shared >= max(1, curWords.count / 2) { return false }
        if newWords.count >= 3, newWords.count == curWords.count, newWords.dropFirst() == curWords.dropFirst() { return false }
        return true
    }

    /// Swaps the open request for a fresh one without touching the tap.
    private func rotateRequest() {
        guard isListening, hasInstalledTap else { return }
        AudioHub.log("recogniser rotated (count open)")
        endRecognition()
        beginRequest(session: session)
        scheduleRotation()
    }

    private func scheduleRotation() {
        rotationTask?.cancel()
        // The newer recogniser listens continuously: nothing to rotate.
        guard isListening, holdOpen, analyzerRecognition == nil else { return }
        rotationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.rotationSeconds)
            guard let self, !Task.isCancelled, self.isListening, self.holdOpen else { return }
            self.rotateRequest()
        }
    }

    #if DEBUG
    /// Simulator testing: the simulator's mic often hears nothing, so
    /// `MYO_FAKE_SPEECH="1 2 3 | went up to 165"` plays each `|`-separated
    /// utterance word by word through the same transcript/pause path real
    /// speech takes, one utterance per listen.
    private static var fakeUtterances: [String] = ProcessInfo.processInfo.environment["MYO_FAKE_SPEECH"]?
        .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []

    private func playFakeUtteranceIfAny() -> Bool {
        guard !Self.fakeUtterances.isEmpty else { return false }
        let words = Self.fakeUtterances.removeFirst().split(separator: " ").map(String.init)
        isListening = true
        transcript = ""
        Task { @MainActor in
            // "~" is a 3-second silence, like the gap between reps.
            var said: [String] = []
            for word in words {
                try? await Task.sleep(nanoseconds: word == "~" ? 3_000_000_000 : 450_000_000)
                guard self.isListening else { return }
                if word == "~" { continue }
                said.append(word)
                self.transcript = said.joined(separator: " ")
                self.schedulePauseCheck()
            }
        }
        return true
    }
    #endif

    /// Waits for a quiet stretch after the last new words, then hands the
    /// transcript to `onPause`. Every new partial result restarts the wait.
    private func schedulePauseCheck() {
        pauseTask?.cancel()
        guard !holdOpen else { return }
        // Onboarding answers are lists and descriptions ("I have kettlebells…
        // dumbbells… a barbell for benching"): give them room.
        let wait = Self.pauseDelay(after: transcript) + extraPause
        pauseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            guard let self, !Task.isCancelled, self.isListening else { return }
            let text = self.transcript
            guard !text.isEmpty else { return }
            self.stop()
            self.onPause?(text)
        }
    }

    // MARK: - Permissions, asked before a workout rather than mid-set

    /// Speech recognition or the mic hasn't been asked about yet.
    static var permissionsUndetermined: Bool {
        SFSpeechRecognizer.authorizationStatus() == .notDetermined || micPermission == .undetermined
    }

    /// Both granted: counting reps out loud can work.
    static var permissionsGranted: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized && micPermission == .granted
    }

    private enum MicPermission { case granted, denied, undetermined }

    private static var micPermission: MicPermission {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            default: return .undetermined
            }
        }
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }

    /// Shows iOS's prompts now (after MYO has said why). True if both granted.
    func requestPermissionsIfNeeded() async -> Bool {
        do {
            try await requestPermissions()
            return true
        } catch {
            return false
        }
    }

    private func requestPermissions() async throws {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard speechStatus == .authorized else {
            throw VoiceInputError.speechPermissionDenied
        }

        let micGranted = await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

        guard micGranted else {
            throw VoiceInputError.microphonePermissionDenied
        }
    }
}

/// Hands the mic tap (audio thread) the request to feed, under a lock.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SpeechBufferSink?
    var current: SpeechBufferSink? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

private enum VoiceInputError: LocalizedError {
    case speechPermissionDenied
    case microphonePermissionDenied
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied:
            return "Speech recognition access is off. Enable it in iOS Settings for MYO."
        case .microphonePermissionDenied:
            return "Microphone access is off. Enable it in iOS Settings for MYO."
        case .microphoneUnavailable:
            return "No microphone input is available right now."
        }
    }
}
