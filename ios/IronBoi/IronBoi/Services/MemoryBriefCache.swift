import Foundation

/// The coach's memory brief (functions/src/coach/memoryBrief.ts), kept on
/// disk so a live voice session opens with it straight away: no network
/// wait for memory. The server rebuilds it after every workout and coach
/// conversation; AppModel's listener saves each new copy here. One file per
/// signed-in user, so a second account on the phone never sees the first's.
struct MemoryBrief: Codable, Equatable {
    static let schema = "memory_brief.v1"

    let builtAt: String
    let text: String

    init?(firestore data: [String: Any]) {
        guard data["schema"] as? String == Self.schema,
              let builtAt = data["builtAt"] as? String, Self.date(builtAt) != nil,
              let text = data["text"] as? String, !text.isEmpty else { return nil }
        self.builtAt = builtAt
        self.text = text
    }

    var builtDate: Date? { Self.date(builtAt) }

    /// The opening [app] line of a live session. Always says how old it is,
    /// so a stale brief reads as history, never as news.
    func appLine(now: Date = Date(), replacing: Bool = false) -> String {
        "Memory brief (\(ageLabel(now: now))\(replacing ? ", replaces the earlier one" : "")): \(text)"
    }

    func ageLabel(now: Date = Date()) -> String {
        guard let built = builtDate else { return "age unknown" }
        let minutes = max(0, Int((now.timeIntervalSince(built) / 60).rounded()))
        let ago: String
        switch minutes {
        case ..<2: ago = "just now"
        case ..<90: ago = "\(minutes) minutes ago"
        case ..<(48 * 60): ago = "\(Int((Double(minutes) / 60).rounded())) hours ago"
        default: ago = "\(Int((Double(minutes) / 1440).rounded())) days ago"
        }
        return "built \(String(builtAt.prefix(16)).replacingOccurrences(of: "T", with: " ")) UTC, \(ago)"
    }

    private static func date(_ iso: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }
}

enum MemoryBriefCache {
    /// Posted (object: MemoryBrief) when a newer brief lands, so a live
    /// session in progress can pass it on.
    static let updated = Notification.Name("MemoryBriefCache.updated")

    private static func url(userId: String) -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let safe = userId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safe.isEmpty else { return nil }
        return dir.appendingPathComponent("MemoryBrief", isDirectory: true).appendingPathComponent("\(safe).json")
    }

    static func load(userId: String) -> MemoryBrief? {
        guard let url = url(userId: userId), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MemoryBrief.self, from: data)
    }

    /// Saves over the old copy only when this one is newer.
    @discardableResult
    static func save(_ brief: MemoryBrief, userId: String) -> Bool {
        guard let url = url(userId: userId) else { return false }
        if let current = load(userId: userId), let old = current.builtDate, let new = brief.builtDate, new <= old {
            return false
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try JSONEncoder().encode(brief).write(to: url, options: options)
            return true
        } catch {
            NSLog("[IronBoi] Memory brief cache write failed: \(error.localizedDescription)")
            return false
        }
    }

    static func clear(userId: String) {
        guard let url = url(userId: userId) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
