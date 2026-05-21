import AVFoundation
import Foundation
import Speech

@MainActor
final class VoiceInputEngine: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInstalledTap = false

    func toggle() {
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
        if audioEngine.isRunning {
            audioEngine.stop()
        }

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
        try await requestPermissions()
        stop()

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        guard !audioSession.currentRoute.inputs.isEmpty else {
            throw VoiceInputError.microphoneUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        transcript = ""

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let text = result?.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    self.transcript = text
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

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        hasInstalledTap = true

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
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
