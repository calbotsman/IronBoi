import CryptoKit
import Foundation

/// The coach's lines, kept on the phone once spoken (or prepared ahead), so
/// the same sentence never waits on the network twice — and a workout keeps
/// its voice when the signal goes. Keyed by engine, voice and exact words.
final class VoiceCache: @unchecked Sendable {
    static let shared = VoiceCache()

    private let directory: URL
    private let lock = NSLock()
    /// About 600 short lines; oldest go first.
    private static let maxBytes = 60 * 1024 * 1024

    // Signal health, from how the last fetches went.
    private var failures: [Date] = []
    private var lowSignalUntil = Date.distantPast

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("coach-voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The engine that reads app lines right now: the live engine's own
    /// voice when live is on, so a saved line and a live reply match.
    static var engine: String {
        // Read straight from settings (the same keys LiveVoiceSession uses),
        // so this works off the main thread too.
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "liveVoiceBeta") as? Bool ?? true else { return "chirp" }
        return defaults.string(forKey: "liveVoiceProvider") == "openai" ? "openai" : "gemini"
    }

    private func url(for text: String, engine: String) -> URL {
        let key = "\(engine)|\(CoachVoiceOption.current)|\(text)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".wav")
    }

    func audio(for text: String, engine: String = VoiceCache.engine) -> Data? {
        let file = url(for: text, engine: engine)
        guard let data = try? Data(contentsOf: file) else { return nil }
        // Touch it, so it's the last to be trimmed.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    func has(_ text: String, engine: String = VoiceCache.engine) -> Bool {
        FileManager.default.fileExists(atPath: url(for: text, engine: engine).path)
    }

    /// Kept under the engine that actually read it — so a line the server
    /// had to read in its fallback voice is never filed as the live one.
    func store(_ data: Data, for text: String, engine: String) {
        try? data.write(to: url(for: text, engine: engine), options: .atomic)
        trimIfNeeded()
    }

    private func trimIfNeeded() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > Self.maxBytes else { return }
        entries.sort { $0.2 < $1.2 }
        for (file, size, _) in entries where total > Self.maxBytes {
            try? FileManager.default.removeItem(at: file)
            total -= size
        }
    }

    // MARK: - Signal

    /// Two failed fetches within a minute: treat the signal as gone for a
    /// little while, so lines that aren't saved don't each wait out a
    /// deadline. One good fetch ends it.
    var lowSignal: Bool {
        lock.lock(); defer { lock.unlock() }
        return Date() < lowSignalUntil
    }

    func noteFailure() {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        failures = failures.filter { now.timeIntervalSince($0) < 60 } + [now]
        if failures.count >= 2 { lowSignalUntil = now.addingTimeInterval(30) }
    }

    func noteSuccess() {
        lock.lock(); defer { lock.unlock() }
        failures = []
        lowSignalUntil = .distantPast
    }
}

/// Waits for `operation` at most `seconds`, then throws `.timedOut` — and
/// really stops waiting: the operation is left to finish (or not) on its
/// own. A task group would wait for it, and a network call that ignores
/// cancellation would turn a 2-second deadline into a 70-second stall.
func withDeadline<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let once = ResumeOnce()
    return try await withCheckedThrowingContinuation { continuation in
        Task {
            do {
                let value = try await operation()
                if once.claim() { continuation.resume(returning: value) }
            } catch {
                if once.claim() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if once.claim() { continuation.resume(throwing: URLError(.timedOut)) }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
