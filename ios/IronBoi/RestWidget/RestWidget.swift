import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RestWidgetBundle: WidgetBundle {
    var body: some Widget {
        RestLiveActivity()
    }
}

/// Minimal on purpose: the time left, and what's next.
struct RestLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestActivityAttributes.self) { context in
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("REST")
                        .font(.system(size: 12, weight: .semibold))
                        .kerning(0.8)
                        .foregroundStyle(.secondary)
                    Text(context.state.next)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                }
                Spacer()
                Text(timerInterval: Date()...max(Date(), context.state.endsAt), countsDown: true)
                    .font(.system(size: 40, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 140, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("Rest").font(.system(size: 15, weight: .semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date()...max(Date(), context.state.endsAt), countsDown: true)
                        .font(.system(size: 28, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .frame(maxWidth: 90)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.next).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "timer")
            } compactTrailing: {
                Text(timerInterval: Date()...max(Date(), context.state.endsAt), countsDown: true)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "timer")
            }
        }
    }
}
