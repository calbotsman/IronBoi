import ActivityKit
import Foundation

/// The rest countdown on the lock screen and in the Dynamic Island, so you
/// can see it with the phone in your pocket or another app open. Shared by
/// the app (which starts and ends it) and the widget (which draws it).
struct RestActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// When the rest is over.
        var endsAt: Date
        /// "Squat · Set 2 of 3 · 135 lb"
        var next: String
    }
}
