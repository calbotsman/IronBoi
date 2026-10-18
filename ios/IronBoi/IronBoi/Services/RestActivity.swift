import ActivityKit
import Foundation

/// Starts, updates and ends the rest countdown on the lock screen. Quietly
/// does nothing where Live Activities are off or unavailable.
@MainActor
final class RestActivity {
    static let shared = RestActivity()
    private var activity: Activity<RestActivityAttributes>?

    func show(endsAt: Date, next: String) {
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
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
