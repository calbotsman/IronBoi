import SwiftUI

/// Rest, a hold, or a warm-up/cooldown move: one big countdown, what's
/// next, one line of advice, and two quiet buttons. Nothing else, so it
/// reads from across the room.
struct TimerPanel: View {
    let title: String
    let endsAt: Date?
    let next: String?
    let tip: String?
    var primary: (label: String, action: () -> Void)?
    var secondary: (label: String, action: () -> Void)?

    /// Full panel when there's room; otherwise the tip goes, then the clock
    /// shrinks, so it never runs into the workout card under it.
    var body: some View {
        // Kept to the clock, what's next, and two buttons: the tip line made
        // the stage crowded and ran into the workout card. The clock shrinks
        // if even that doesn't fit.
        ViewThatFits(in: .vertical) {
            panel(showTip: false, clockSize: 64)
            panel(showTip: false, clockSize: 44)
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    private func panel(showTip: Bool, clockSize: CGFloat) -> some View {
        VStack(spacing: MyoTheme.Spacing.sm) {
            Text(title)
                .myoStyle(.label)
                .textCase(.uppercase)
                .kerning(0.8)
                .foregroundStyle(MyoColor.Text.tertiary.color)

            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                Text(Self.clock(endsAt))
                    .font(.system(size: clockSize, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(MyoColor.Text.primary.color)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.easeOut(duration: 0.2), value: Self.clock(endsAt))
            }
            .accessibilityLabel("\(title), \(Self.clock(endsAt)) left")

            if let next, !next.isEmpty {
                Text(next)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MyoColor.Text.secondary.color)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if showTip, let tip, !tip.isEmpty {
                Text(tip)
                    .font(.system(size: 14))
                    .foregroundStyle(MyoColor.Text.tertiary.color)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, MyoTheme.Spacing.lg)
            }
            if primary != nil || secondary != nil {
                HStack(spacing: MyoTheme.Spacing.lg) {
                    if let secondary {
                        Button(secondary.label, action: secondary.action)
                    }
                    if let primary {
                        Button(primary.label, action: primary.action)
                    }
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MyoColor.Text.secondary.color)
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }
        }
    }

    /// "1:30"; "–" while the clock hasn't started (Coach is still talking).
    static func clock(_ endsAt: Date?) -> String {
        guard let endsAt, endsAt != .distantFuture else { return "–" }
        let left = max(0, Int(endsAt.timeIntervalSinceNow.rounded(.up)))
        return String(format: "%d:%02d", left / 60, left % 60)
    }
}
