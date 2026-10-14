import AVFoundation
import Speech

/// What the mic tap feeds: a recognition request of either kind.
protocol SpeechBufferSink: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
}

extension SFSpeechAudioBufferRecognitionRequest: SpeechBufferSink {}

// compiler(>=6.2) ⇔ the Xcode 26 SDK, where SpeechAnalyzer exists; CI's
// older Xcode compiles without it (and listens with SFSpeech only).
#if compiler(>=6.2)
/// One listen on Apple's newer recogniser (iOS 26: SpeechAnalyzer with
/// SpeechTranscriber). It's more accurate on short words like a count,
/// reports sooner, and runs as one continuous listen, so it needs no
/// restarting mid-set. It's fed the same mic buffers as the old recogniser
/// and reports a running transcript: everything settled so far, plus what's
/// still settling.
@available(iOS 26.0, *)
final class AnalyzerRecognition: SpeechBufferSink, @unchecked Sendable {
    private static let locale = Locale(identifier: "en-US")

    /// The model is on the phone: listens can use this recogniser. Until it
    /// is (first launch downloads it), they use the old one.
    nonisolated(unsafe) private(set) static var ready = false
    nonisolated(unsafe) private static var preparing = false

    /// Checks for the model, and downloads it in the background if needed.
    static func prepare() {
        guard !ready, !preparing else { return }
        preparing = true
        Task.detached(priority: .utility) {
            defer { preparing = false }
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Self.locale) else {
                await AudioHub.log("analyzer: en-US not supported")
                return
            }
            let probe = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                          reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
            do {
                if await AssetInventory.status(forModules: [probe]) != .installed,
                   let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                    await AudioHub.log("analyzer: downloading the speech model")
                    try await request.downloadAndInstall()
                }
                ready = await AssetInventory.status(forModules: [probe]) == .installed
                await AudioHub.log("analyzer: \(ready ? "ready" : "not installed")")
            } catch {
                await AudioHub.log("analyzer: model unavailable: \(error.localizedDescription)")
            }
        }
    }

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var tasks: [Task<Void, Never>] = []

    /// `onText` gets the whole running transcript each time it changes;
    /// `onEnd` fires once if the recogniser stops on its own (an error).
    init(words: [String], onText: @escaping @Sendable (String) -> Void, onEnd: @escaping @Sendable (Error?) -> Void) {
        transcriber = SpeechTranscriber(locale: Self.locale, transcriptionOptions: [],
                                        reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        analyzer = SpeechAnalyzer(modules: [transcriber],
                                  options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        (input, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(256))

        let transcriber = transcriber, analyzer = analyzer, input = input
        tasks.append(Task { [weak self] in
            do {
                let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                self?.setFormat(format)
                let context = AnalysisContext()
                context.contextualStrings[.general] = words
                try await analyzer.setContext(context)
                try await analyzer.start(inputSequence: input)
            } catch {
                onEnd(error)
            }
        })
        tasks.append(Task {
            var settled = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let whole: String
                    if result.isFinal {
                        settled = (settled + " " + text).trimmingCharacters(in: .whitespaces)
                        whole = settled
                    } else {
                        whole = (settled + " " + text).trimmingCharacters(in: .whitespaces)
                    }
                    if !whole.isEmpty { onText(whole) }
                }
            } catch is CancellationError {
                return
            } catch {
                onEnd(error)
            }
        })
    }

    private func setFormat(_ format: AVAudioFormat?) {
        self.format = format
    }

    /// From the mic tap (audio thread): converted to what the model wants.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let format else { return }
        if buffer.format == format {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }

    /// This listen is over.
    func cancel() {
        continuation.finish()
        let analyzer = analyzer
        let tasks = tasks
        Task {
            await analyzer.cancelAndFinishNow()
            tasks.forEach { $0.cancel() }
        }
    }
}
#endif
