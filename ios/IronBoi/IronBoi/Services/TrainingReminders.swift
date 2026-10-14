import Foundation
import UserNotifications

/// Training-day nudges, scheduled on the phone (docs/product/habit-journey-plan.md §4).
///
/// The cue is a time *you* picked, on your plan's training days only:
/// - one reminder on each training day, at your time;
/// - one "missed it?" note the next morning, only when that next day isn't a
///   training day itself (never two nudges in a day);
/// - nothing on rest days, nothing once you've trained today.
///
/// Everything is local: nothing leaves the phone, and the lock-screen text
/// never says anything about your body or your plan. Reminders are scheduled
/// two weeks ahead and refreshed each time the app runs, so someone who stops
/// opening MYO stops hearing from it after two weeks instead of forever.
@MainActor
final class TrainingReminders: ObservableObject {
    static let shared = TrainingReminders()

    @Published private(set) var enabled: Bool
    @Published private(set) var hour: Int
    @Published private(set) var minute: Int

    private let defaults = UserDefaults.standard
    private let center = UNUserNotificationCenter.current()
    private static let idPrefix = "myo.reminder."
    private static let horizonDays = 14
    private static let missedNoteHour = 9
    private static let weekdayKeys = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] // Calendar weekday 1…7

    private enum Key {
        static let enabled = "reminders.enabled"
        static let hour = "reminders.hour"
        static let minute = "reminders.minute"
        static let asked = "reminders.asked"
        static let trainedOn = "reminders.trainedOn"
        static let timeChosen = "reminders.timeChosen"
        static let serverTime = "reminders.serverTime"
    }

    /// The training days last seen in the plan ("Mon", "Wed"…).
    private var trainingDays: Set<String> = []

    private init() {
        enabled = defaults.bool(forKey: Key.enabled)
        hour = defaults.object(forKey: Key.hour) as? Int ?? 18
        minute = defaults.object(forKey: Key.minute) as? Int ?? 0
    }

    /// Asked once, after the first workout. Not again unless you go to settings.
    var hasAsked: Bool { defaults.bool(forKey: Key.asked) }

    func markAsked() { defaults.set(true, forKey: Key.asked) }

    /// The time as a Date today, for a picker.
    var time: Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    /// A sensible default the first time: when you started today's workout,
    /// to the half hour — you already showed up then.
    static func suggestedTime(startedAt: Date?) -> Date {
        let base = startedAt ?? Date()
        let parts = Calendar.current.dateComponents([.hour, .minute], from: base)
        let minute = (parts.minute ?? 0) < 15 ? 0 : (parts.minute ?? 0) < 45 ? 30 : 0
        let hour = ((parts.hour ?? 18) + ((parts.minute ?? 0) >= 45 ? 1 : 0)) % 24
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? base
    }

    /// Turns reminders on at this time. Asks iOS for permission if it hasn't
    /// yet; returns false if notifications are off for MYO.
    @discardableResult
    func enable(at time: Date) async -> Bool {
        markAsked()
        let granted: Bool
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            granted = true
        case .notDetermined:
            granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            granted = false
        }
        guard granted else {
            setEnabled(false)
            return false
        }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        hour = parts.hour ?? 18
        minute = parts.minute ?? 0
        defaults.set(hour, forKey: Key.hour)
        defaults.set(minute, forKey: Key.minute)
        setEnabled(true)
        await reschedule()
        return true
    }

    /// The time picked in onboarding: remembered for the reminder card after
    /// the first workout, but nothing is scheduled until they say yes there.
    func setPreferredTime(_ time: Date) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        hour = parts.hour ?? hour
        minute = parts.minute ?? minute
        defaults.set(hour, forKey: Key.hour)
        defaults.set(minute, forKey: Key.minute)
        defaults.set(true, forKey: Key.timeChosen)
    }

    /// The profile's training time changed on the server ("I train at 6am
    /// now", told to the coach): follow it. Only acts when the server value
    /// itself changes, so the time picked on this phone isn't overridden on
    /// every profile update.
    func adoptServerTime(_ hhmm: String) {
        guard defaults.string(forKey: Key.serverTime) != hhmm else { return }
        defaults.set(hhmm, forKey: Key.serverTime)
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2,
              let date = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date())
        else { return }
        setPreferredTime(date)
        if enabled { Task { await reschedule() } }
    }

    /// They picked a time in onboarding; the reminder card offers that one.
    var hasChosenTime: Bool { defaults.bool(forKey: Key.timeChosen) }

    func disable() {
        setEnabled(false)
        Task { await clearPending() }
    }

    /// The plan's training days changed (or the app just loaded it).
    func update(trainingDays days: [String]) {
        let next = Set(days)
        guard next != trainingDays else { return }
        trainingDays = next
        Task { await reschedule() }
    }

    /// A workout was finished today: today's reminder and tomorrow's
    /// "missed it?" note are no longer needed.
    func markTrainedToday() {
        defaults.set(Self.dayString(Date()), forKey: Key.trainedOn)
        Task { await reschedule() }
    }

    /// Rebuilds every pending reminder from the plan and today's state.
    func reschedule(now: Date = Date()) async {
        await clearPending()
        guard enabled, !trainingDays.isEmpty else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let trainedToday = defaults.string(forKey: Key.trainedOn) == Self.dayString(now)

        for offset in 0..<Self.horizonDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  isTrainingDay(day) else { continue }
            let doneAlready = offset == 0 && trainedToday

            // The nudge on the day, at your time.
            if !doneAlready, let fireAt = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), fireAt > now {
                add(id: "train.\(Self.dayString(day))", at: fireAt,
                    body: "Today's session is ready when you are.")
            }

            // One "missed it?" note the next morning — unless the next day
            // trains anyway (its own nudge covers it) or you already trained.
            guard !doneAlready,
                  let next = calendar.date(byAdding: .day, value: 1, to: day),
                  !isTrainingDay(next),
                  let fireAt = calendar.date(bySettingHour: Self.missedNoteHour, minute: 0, second: 0, of: next),
                  fireAt > now else { continue }
            add(id: "missed.\(Self.dayString(next))", at: fireAt,
                body: "Yesterday's session slipped by. No big deal. Want to do it today?")
        }
    }

    #if DEBUG
    /// Proves delivery: a reminder in ten seconds (lock the phone to see it).
    func sendTest() async {
        _ = await enable(at: time)
        add(id: "test.\(UUID().uuidString)", at: Date().addingTimeInterval(10),
            body: "Today's session is ready when you are.")
    }
    #endif

    // MARK: - Private

    private func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: Key.enabled)
    }

    private func isTrainingDay(_ date: Date) -> Bool {
        let weekday = Calendar.current.component(.weekday, from: date)
        return trainingDays.contains(Self.weekdayKeys[weekday - 1])
    }

    private func add(id: String, at date: Date, body: String) {
        let content = UNMutableNotificationContent()
        content.title = "MYO"
        content.body = body
        content.sound = .default
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        center.add(UNNotificationRequest(identifier: Self.idPrefix + id, content: content, trigger: trigger))
    }

    private func clearPending() async {
        let ours = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
    }

    private static func dayString(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
