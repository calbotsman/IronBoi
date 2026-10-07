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
        didSet { if holdOpen { pauseTask?.cancel() } else if isListening, !transcript.isEmpty { schedulePauseCheck() } }
    }
    private static let pauseSeconds: UInt64 = 1_400_000_000

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    /// Shared with Coach's voice so the mic can stay open while Coach talks.
    private var audioEngine: AVAudioEngine { AudioHub.shared.engine }
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInstalledTap = false

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
            do {
                try await start()
            } catch {
                errorMessage = error.localizedDescription
                stop()
            }
        }
    }

    func stop() {
        pauseTask?.cancel()
        pauseTask = nil
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
        try await requestPermissions()
        stop()

        // Our tap is off (stop() above): the hub may retune echo
        // cancellation for whatever's plugged in now.
        try AudioHub.shared.start(reconfigure: true)
        guard !AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty else {
            throw VoiceInputError.microphoneUnavailable
        }

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
        request.contextualStrings = ["MYO", "Coach", "set done", "sets done", "reps"]
        self.request = request
        transcript = ""

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let text = result?.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty, text != self.transcript {
                    self.transcript = text
                    self.schedulePauseCheck()
                }

                if error != nil || result?.isFinal == true {
                    self.stop()
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceInputError.microphoneUnavailable
        }

        let meter = self.meter
        let analyzer = MicAnalyzer()
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
            analyzer.process(buffer, into: meter)
        }
        hasInstalledTap = true
        isListening = true
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
