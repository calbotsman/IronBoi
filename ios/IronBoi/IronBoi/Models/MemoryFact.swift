import Foundation
import FirebaseFirestore

/// One thing Coach remembers about the user — a `users/{uid}/memoryFacts`
/// doc. Written server-side only (the remember_user_fact tool, accepted plan
/// adjustments, upsertMemoryFact); the client reads them and can confirm a
/// proposed fact or soft-delete any fact via callables.
struct MemoryFact: Identifiable, Equatable {
    let id: String
    let category: String
    let content: String
    /// user_stated | coach_inferred | log_derived | healthkit_derived
    let source: String
    /// proposed | confirmed | rejected
    let state: String
    /// YYYY-MM-DD — when the thing happened, if the user said.
    let happenedOn: String?
    /// YYYY-MM-DD — last day a temporary fact applies.
    let until: String?
    let createdAt: Date?
    /// Proposed facts expire unreviewed after 14 days.
    let expiresAt: Date?

    var isProposed: Bool { state == "proposed" }
    var isPlanChange: Bool { category == "plan_change" }
    var isUserStated: Bool { source == "user_stated" }

    /// A temporary fact past its `until` date. The server drops these from
    /// Coach's context, so the UI shows them as ended rather than active.
    func isLapsed(today: String) -> Bool {
        guard let until else { return false }
        return until < today
    }

    func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt < now
    }

    /// Same ranking Coach's prompt window uses: safety first, then
    /// constraints, then everything else by recency.
    var priority: Int {
        switch category {
        case "safety_note": return 0
        case "constraint": return 1
        default: return 2
        }
    }

    var categoryLabel: String {
        switch category {
        case "safety_note": return "Safety"
        case "constraint": return "Limit"
        case "preference": return "Preference"
        case "equipment": return "Equipment"
        case "schedule": return "Schedule"
        case "motivation": return "Motivation"
        case "exercise_response": return "How you respond"
        case "adherence_pattern": return "Habits"
        case "plan_change": return "Plan change"
        default: return category.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Returns nil for deleted or rejected facts — the UI never shows them.
    static func make(id: String, data: [String: Any]) -> MemoryFact? {
        guard
            data["userDeletedAt"] == nil,
            let content = data["content"] as? String,
            !content.isEmpty
        else { return nil }
        let state = data["state"] as? String ?? "confirmed"
        guard state != "rejected" else { return nil }
        return MemoryFact(
            id: id,
            category: data["category"] as? String ?? "preference",
            content: content,
            source: data["source"] as? String ?? "coach_inferred",
            state: state,
            happenedOn: data["happenedOn"] as? String,
            until: data["until"] as? String,
            createdAt: parseDate(data["createdAt"]),
            expiresAt: parseDate(data["expiresAt"])
        )
    }

    /// The backend writes ISO strings (with or without fractional seconds);
    /// tolerate a Firestore Timestamp too.
    private static func parseDate(_ value: Any?) -> Date? {
        if let timestamp = value as? Timestamp { return timestamp.dateValue() }
        guard let raw = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
