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
    /// Bumped on every new recognition request; a callback from an older
    /// request is ignored (its "final" must not stop a fresh one).
    private var requestGeneration = 0
    private var hasInstalledTap = false
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
                try? await Task.sleep(nanoseconds: 800_000_000)
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

    func stop() {
        // Anything still in flight from this listen is now stale.
        session += 1
        pauseTask?.cancel()
        pauseTask = nil
        rotationTask?.cancel()
        rotationTask = nil
        meter.reset()
        // The engine stays up — Coach may be mid-sentence on it.
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        isListening = false
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

        // Our tap is off (stop() above): the hub may retune echo
        // cancellation for whatever's plugged in now.
        try AudioHub.shared.start(reconfigure: true)
        guard !AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty else {
            throw VoiceInputError.microphoneUnavailable
        }

        beginRequest(session: mine)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceInputError.microphoneUnavailable
        }

        let meter = self.meter
        let analyzer = MicAnalyzer()
        let box = requestBox
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            box.current?.append(buffer)
            analyzer.process(buffer, into: meter)
        }
        hasInstalledTap = true
        isListening = true
        if holdOpen { scheduleRotation() }
    }

    /// The words a workout is made of, so the recogniser leans toward
    /// them: a count ("seven" over "heaven"), and the set being called.
    private static let workoutWords: [String] = [
        "MYO", "Coach", "set done", "sets done", "done", "reps",
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

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                // A late callback from an earlier listen or an earlier
                // request must not touch this one.
                guard let self, self.session == mine, self.requestGeneration == generation else { return }

                if let text = result?.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty, text != self.transcript {
                    self.transcript = text
                    // Every partial, so a device test shows exactly what the
                    // recogniser made of a count.
                    AudioHub.log("heard: \(text.suffix(80))")
                    self.schedulePauseCheck()
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

    /// Swaps the open request for a fresh one without touching the tap.
    private func rotateRequest() {
        guard isListening, hasInstalledTap else { return }
        AudioHub.log("recogniser rotated (count open)")
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        beginRequest(session: session)
        scheduleRotation()
    }

    private func scheduleRotation() {
        rotationTask?.cancel()
        guard isListening, holdOpen else { return }
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
        pauseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.pauseSeconds)
            guard let self, !Task.isCancelled, self.isListening else { return }
            let text = self.transcript
            guard !text.isEmpty else { return }
            self.stop()
            self.onPause?(text)
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
    private var value: SFSpeechAudioBufferRecognitionRequest?
    var current: SFSpeechAudioBufferRecognitionRequest? {
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
