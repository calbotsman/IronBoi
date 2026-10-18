import ActivityKit
import Foundation
import UserNotifications

/// Starts, updates and ends the rest countdown on the lock screen. Quietly
/// does nothing where Live Activities are off or unavailable.
@MainActor
final class RestActivity {
    static let shared = RestActivity()
    private var activity: Activity<RestActivityAttributes>?

    func show(endsAt: Date, next: String) {
        scheduleNudge(at: endsAt, next: next)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = RestActivityAttributes.ContentState(endsAt: endsAt, next: next)
        // It goes stale (greys out) when the rest is over, if the app
        // hasn't ended it by then.
        let content = ActivityContent(state: state, staleDate: endsAt.addingTimeInterval(5))
        if let activity {
            Task { await activity.update(content) }
            return
        }
        activity = try? Activity.request(attributes: RestActivityAttributes(), content: content)
    }

    func end() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.nudgeId])
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private static let nudgeId = "rest-over"

    /// A backstop for when iOS has paused the app anyway: a buzz when the
    /// rest is over. Only if you've already allowed notifications (training
    /// reminders); never asks here, mid-workout.
    private func scheduleNudge(at endsAt: Date, next: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.nudgeId])
        let seconds = endsAt.timeIntervalSinceNow
        guard seconds > 1 else { return }
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = "Rest's over"
            content.body = next.isEmpty ? "Next set." : "Next: \(next)"
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let request = UNNotificationRequest(identifier: Self.nudgeId, content: content,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false))
            center.add(request)
        }
    }
}
