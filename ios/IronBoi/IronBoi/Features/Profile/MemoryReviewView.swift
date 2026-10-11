import SwiftUI

/// "What Coach remembers" — every memory fact the coach reads before it
/// replies, with a way to keep, discard, or remove each one. Pushed from the
/// You tab. Copy follows the build plan's memory-review kit (Declan), with
/// "Coach" as the entity per decision D-A.
struct MemoryReviewView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var busyFactIds: Set<String> = []
    @State private var factPendingRemoval: MemoryFact?

    private var today: String { appModel.todayISO }

    private var toReview: [MemoryFact] {
        appModel.memoryFacts
            .filter { $0.isProposed && !$0.isExpired() }
    }

    private var active: [MemoryFact] {
        appModel.memoryFacts
            .filter { !$0.isProposed && !$0.isPlanChange && !$0.isLapsed(today: today) }
            .sorted { ($0.priority, -($0.createdAt?.timeIntervalSince1970 ?? 0))
                    < ($1.priority, -($1.createdAt?.timeIntervalSince1970 ?? 0)) }
    }

    private var planChanges: [MemoryFact] {
        appModel.memoryFacts.filter { !$0.isProposed && $0.isPlanChange }
    }

    private var ended: [MemoryFact] {
        appModel.memoryFacts
            .filter { !$0.isProposed && !$0.isPlanChange && $0.isLapsed(today: today) }
    }

    private var isEmpty: Bool {
        toReview.isEmpty && active.isEmpty && planChanges.isEmpty && ended.isEmpty
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MyoTheme.Spacing.xl) {
                header

                if isEmpty {
                    emptyState
                } else {
                    if !toReview.isEmpty {
                        section(
                            title: "For you to review",
                            note: "Coach's guesses. It won't use these until you keep them.",
                            facts: toReview
                        )
                    }
                    if !active.isEmpty {
                        section(title: "Remembered", note: nil, facts: active)
                    }
                    if !planChanges.isEmpty {
                        section(
                            title: "Changes to your plan",
                            note: "What Coach changed and why, so it doesn't re-ask.",
                            facts: planChanges
                        )
                    }
                    if !ended.isEmpty {
                        section(
                            title: "No longer in effect",
                            note: "Past their end date. Coach doesn't use these anymore.",
                            facts: ended
                        )
                    }
                }

                Text("You can also tell Coach \u{201C}forget that\u{201D} in chat.")
                    .myoStyle(.detail)
                    .foregroundStyle(MyoColor.Text.tertiary.color)
            }
            .padding(.horizontal, MyoTheme.Spacing.md)
            .padding(.vertical, MyoTheme.Spacing.lg)
        }
        .background(PaperBackground())
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(MyoTheme.Colors.cream, for: .navigationBar)
        .alert(
            "Remove this from Coach's memory?",
            isPresented: Binding(
                get: { factPendingRemoval != nil },
                set: { if !$0 { factPendingRemoval = nil } }
            ),
            presenting: factPendingRemoval
        ) { fact in
            Button("Remove", role: .destructive) {
                Task { await run(fact.id) { await appModel.deleteMemoryFact(fact.id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { fact in
            Text(fact.category == "safety_note"
                 ? "Coach will stop planning around this. If it still hurts, tell Coach instead."
                 : "Coach stops using it from the next reply.")
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            Text("This is what Coach remembers about you.")
                .myoStyle(.display)
                .foregroundStyle(MyoColor.Text.primary.color)
                .fixedSize(horizontal: false, vertical: true)
            Text("Coach reads these before every reply. Remove anything that's wrong or no longer true.")
                .myoStyle(.body)
                .foregroundStyle(MyoColor.Text.secondary.color)
        }
    }

    private var emptyState: some View {
        MyoGroupCard {
            MyoSectionLabel(text: "Nothing yet")
            Text("Tell Coach about an injury, your schedule, or what you like and don't, and it will show up here.")
                .myoStyle(.body)
                .foregroundStyle(MyoColor.Text.secondary.color)
        }
    }

    private func section(title: String, note: String?, facts: [MemoryFact]) -> some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            MyoSectionLabel(text: "\(title) · \(facts.count)")
            if let note {
                Text(note)
                    .myoStyle(.detail)
                    .foregroundStyle(MyoColor.Text.tertiary.color)
            }
            MyoGroupCard {
                ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                    if index > 0 { MyoHairline() }
                    row(fact)
                }
            }
        }
    }

    private func row(_ fact: MemoryFact) -> some View {
        let busy = busyFactIds.contains(fact.id)
        let ended = fact.isLapsed(today: today)
        return VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            Text(metaLine(fact))
                .myoStyle(.label)
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(fact.category == "safety_note" && !ended
                                 ? MyoColor.redPen
                                 : MyoColor.Text.tertiary.color)

            Text(fact.content)
                .myoStyle(.body)
                .foregroundStyle(ended ? MyoColor.Text.tertiary.color : MyoColor.Text.primary.color)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: MyoTheme.Spacing.md) {
                Text(fact.isUserStated ? "Your words" : "Coach's note")
                    .myoStyle(.detail)
                    .foregroundStyle(MyoColor.Text.tertiary.color)
                Spacer()
                if busy {
                    ProgressView().tint(MyoTheme.Colors.ink)
                } else if fact.isProposed {
                    actionButton("Discard", color: MyoColor.Action.critical.color) {
                        Task { await run(fact.id) { await appModel.deleteMemoryFact(fact.id) } }
                    }
                    actionButton("Keep", color: MyoTheme.Colors.ink, prominent: true) {
                        Task { await run(fact.id) { await appModel.confirmMemoryFact(fact.id) } }
                    }
                } else {
                    actionButton("Remove", color: MyoColor.Action.critical.color) {
                        factPendingRemoval = fact
                    }
                }
            }
        }
        .padding(.vertical, MyoTheme.Spacing.xs)
        .accessibilityElement(children: .contain)
    }

    private func actionButton(
        _ title: String,
        color: Color,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(prominent ? MyoColor.onAction : color)
                .padding(.horizontal, MyoTheme.Spacing.md)
                .frame(minHeight: 36)
                .background(prominent ? color : Color.clear)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(color, lineWidth: prominent ? 0 : 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }

    /// "SAFETY · SINCE 16 JUN · UNTIL 30 JUN"
    private func metaLine(_ fact: MemoryFact) -> String {
        var parts = [fact.categoryLabel]
        if let happenedOn = fact.happenedOn, let date = Self.shortDate(happenedOn) {
            parts.append("since \(date)")
        }
        if let until = fact.until, let date = Self.shortDate(until) {
            parts.append(fact.isLapsed(today: today) ? "ended \(date)" : "until \(date)")
        }
        if fact.happenedOn == nil, fact.until == nil, let createdAt = fact.createdAt {
            parts.append("noted \(createdAt.formatted(.dateTime.day().month(.abbreviated)))")
        }
        return parts.joined(separator: " · ")
    }

    private static func shortDate(_ iso: String) -> String? {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .iso8601)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: iso) else { return nil }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private func run(_ factId: String, _ work: () async -> Bool) async {
        busyFactIds.insert(factId)
        _ = await work()
        withAnimation(MyoTheme.Motion.fade) { _ = busyFactIds.remove(factId) }
    }
}

/// The You-tab entry point: a one-line summary and a link into the full list.
struct MemorySummaryCard: View {
    @EnvironmentObject private var appModel: AppModel

    private var liveCount: Int {
        appModel.memoryFacts.filter {
            !$0.isProposed && !$0.isPlanChange && !$0.isLapsed(today: appModel.todayISO)
        }.count
    }

    private var reviewCount: Int {
        appModel.memoryFacts.filter { $0.isProposed && !$0.isExpired() }.count
    }

    var body: some View {
        MyoGroupCard {
            MyoSectionLabel(text: "What Coach remembers")
            NavigationLink {
                MemoryReviewView()
            } label: {
                HStack(spacing: MyoTheme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(MyoColor.Text.primary.color)
                        if reviewCount > 0 {
                            Text("\(reviewCount) to review")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(MyoTheme.Colors.ochre)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(MyoColor.Text.tertiary.color)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Review and remove things Coach remembers about you")

            Text("Injuries, schedule, likes and dislikes you've told Coach in chat.")
                .font(.caption)
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.5))
        }
    }

    private var summary: String {
        switch liveCount {
        case 0: return "Nothing yet"
        case 1: return "1 thing"
        default: return "\(liveCount) things"
        }
    }
}
