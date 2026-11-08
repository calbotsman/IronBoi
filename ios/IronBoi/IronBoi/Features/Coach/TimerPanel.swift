import SwiftUI

/// Rest, a hold, or a warm-up/cooldown move: one big clock, what's next,
/// and its buttons. Nothing else, so it reads from across the room and never
/// runs into the workout card under it.
struct TimerPanel: View {
    let title: String
    let endsAt: Date?
    let next: String?
    /// One short line under "next" — only where it earns its place ("Then:
    /// the next stretch" in a warm-up). Dropped first when space is short.
    var note: String? = nil
    /// Paused: the time that was left, shown frozen instead of a dash.
    var frozen: TimeInterval? = nil
    /// Before the clock starts (Coach still talking): its full length,
    /// greyed, instead of a dash.
    var pending: Int? = nil
    var primary: (label: String, action: () -> Void)?
    var secondary: (label: String, action: () -> Void)?

    /// The biggest layout that fits the room above the workout card; the
    /// smallest is just the clock and the buttons.
    var body: some View {
        ViewThatFits(in: .vertical) {
            panel(clockSize: 64, showTitle: true, showNext: true, showNote: true)
            panel(clockSize: 48, showTitle: true, showNext: true, showNote: false)
            // Tightest: the clock and the buttons on one 44 pt row, so the
            // buttons can never be the part that's cut off.
            compactRow
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    private func panel(clockSize: CGFloat, showTitle: Bool, showNext: Bool, showNote: Bool) -> some View {
        VStack(spacing: MyoTheme.Spacing.sm) {
            if showTitle {
                Text(title)
                    .myoStyle(.label)
                    .textCase(.uppercase)
                    .kerning(0.8)
                    .foregroundStyle(MyoColor.Text.tertiary.color)
            }

            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let running = Self.isRunning(endsAt)
                Text(clockText)
                    .font(.system(size: clockSize, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(running || frozen != nil ? MyoColor.Text.primary.color : MyoColor.Text.tertiary.color)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.easeOut(duration: 0.2), value: clockText)
            }
            .accessibilityLabel("\(title), \(clockText) left")

            if showNext, let next, !next.isEmpty {
                Text(next)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MyoColor.Text.secondary.color)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if showNote, let note, !note.isEmpty {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(MyoColor.Text.tertiary.color)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, MyoTheme.Spacing.lg)
            }
            if primary != nil || secondary != nil {
                HStack(spacing: MyoTheme.Spacing.sm) {
                    if let secondary { pill(secondary.label, action: secondary.action) }
                    if let primary { pill(primary.label, action: primary.action) }
                }
            }
        }
    }

    private var compactRow: some View {
        HStack(spacing: MyoTheme.Spacing.sm) {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                Text(clockText)
                    .font(.system(.title, design: .rounded).weight(.light))
                    .monospacedDigit()
                    .foregroundStyle(MyoColor.Text.primary.color)
            }
            .accessibilityLabel("\(title), \(clockText) left")
            if let secondary { pill(secondary.label, action: secondary.action) }
            if let primary { pill(primary.label, action: primary.action) }
        }
    }

    /// The same 44 pt glass pill as the quick taps by the mic — these were
    /// bare grey words with a tap area a third that size.
    private func pill(_ label: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(MyoColor.Text.primary.color)
                .lineLimit(1)
                .padding(.horizontal, MyoTheme.Spacing.md)
                .frame(minWidth: 72, minHeight: 44)
                .contentShape(Capsule())
                .myoGlass()
        }
        .buttonStyle(.plain)
    }

    private var clockText: String {
        if Self.isRunning(endsAt) { return Self.clock(endsAt) }
        if let frozen { return Self.format(Int(frozen.rounded(.up))) }
        if let pending { return Self.format(pending) }
        return "–"
    }

    private static func isRunning(_ endsAt: Date?) -> Bool {
        guard let endsAt else { return false }
        return endsAt != .distantFuture
    }

    private static func format(_ seconds: Int) -> String {
        let left = max(0, seconds)
        return String(format: "%d:%02d", left / 60, left % 60)
    }

    /// "1:30"; "–" while the clock hasn't started (Coach is still talking).
    static func clock(_ endsAt: Date?) -> String {
        guard let endsAt, endsAt != .distantFuture else { return "–" }
        return format(Int(endsAt.timeIntervalSinceNow.rounded(.up)))
    }
}
