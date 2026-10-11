import SwiftUI

/// Coach's proposed change to your plan, in the Coach screen's card style:
/// what changes and why up top, the sessions underneath (short, expandable),
/// then one decision. × or "Not now" declines it.
struct PlanReviewCard: View {
    @EnvironmentObject private var appModel: AppModel
    let proposal: PlanAdjustmentProposalSummary
    @State private var expandedDays: Set<String> = []

    private var canApply: Bool { proposal.riskLevel == "low" && !proposal.requiresFollowUp }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
                    header
                    if !proposal.dayPatchDetails.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(proposal.dayPatchDetails.enumerated()), id: \.element.id) { index, day in
                                if index > 0 { MyoHairline() }
                                dayRow(day)
                            }
                        }
                    } else if !proposal.changes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(proposal.changes.prefix(4), id: \.self) { change in
                                Text(change)
                                    .font(.subheadline)
                                    .foregroundStyle(MyoColor.Text.secondary.color)
                            }
                        }
                    }
                    if let note = proposal.safetyNotes.first {
                        Label(note, systemImage: "exclamationmark.shield")
                            .font(.caption)
                            .foregroundStyle(MyoColor.redPen)
                    }
                }
                .padding(MyoTheme.Spacing.lg)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)

            MyoHairline()
            actions.padding(MyoTheme.Spacing.md)
        }
        .frame(maxWidth: .infinity)
        .myoCard()
        .shadow(color: MyoTheme.Colors.ink.opacity(0.10), radius: 28, y: 10)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Coach suggests")
                    .myoStyle(.label)
                    .textCase(.uppercase)
                    .kerning(0.5)
                    .foregroundStyle(MyoColor.redPen)
                Spacer()
                Button {
                    Task { await appModel.declinePendingPlanAdjustmentProposal() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MyoColor.Text.tertiary.color)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, -MyoTheme.Spacing.sm)
                .padding(.vertical, -MyoTheme.Spacing.md)
                .accessibilityLabel("Dismiss suggestion")
            }
            Text(proposal.summary)
                .font(.title3.weight(.bold))
                .foregroundStyle(MyoColor.Text.primary.color)
                .fixedSize(horizontal: false, vertical: true)
            if !proposal.rationale.isEmpty {
                Text(proposal.rationale)
                    .font(.subheadline)
                    .foregroundStyle(MyoColor.Text.secondary.color)
                    .lineLimit(3)
            }
        }
    }

    private func dayRow(_ day: ProposalDayPatchDetail) -> some View {
        let expanded = expandedDays.contains(day.id)
        let lines = expanded ? day.exerciseLines : Array(day.exerciseLines.prefix(3))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: MyoTheme.Spacing.sm) {
                Text(day.dayKey.uppercased())
                    .myoStyle(.label)
                    .foregroundStyle(MyoColor.Text.tertiary.color)
                    .frame(width: 44, alignment: .leading)
                Text(day.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MyoColor.Text.primary.color)
            }
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(MyoColor.Text.secondary.color)
                    .padding(.leading, 52)
            }
            if day.exerciseLines.count > 3 {
                Button(expanded ? "Show less" : "+\(day.exerciseLines.count - 3) more") {
                    withAnimation(MyoTheme.Motion.fade) {
                        if expanded { expandedDays.remove(day.id) } else { expandedDays.insert(day.id) }
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(MyoTheme.Colors.ochre)
                .padding(.leading, 52)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var actions: some View {
        if !canApply {
            HStack {
                Text(proposal.requiresFollowUp
                     ? "Coach needs one more detail — just answer out loud."
                     : "Talk this through with Coach first.")
                    .font(.footnote)
                    .foregroundStyle(MyoColor.Text.secondary.color)
                Spacer()
                notNow
            }
        } else if proposal.patchType == "clear_overrides" {
            HStack(spacing: MyoTheme.Spacing.sm) {
                notNow
                primary("Restore my plan") { apply(nil) }
            }
        } else if proposal.scope != nil {
            HStack(spacing: MyoTheme.Spacing.sm) {
                notNow
                primary(presetTitle) { apply(nil) }
            }
        } else {
            VStack(spacing: MyoTheme.Spacing.sm) {
                HStack(spacing: MyoTheme.Spacing.sm) {
                    secondary(justOnceTitle) { apply("today") }
                    if proposal.dayPatchDetails.count > 1 {
                        secondary("This week") { apply("rest_of_week") }
                    }
                    primary("From now on") { apply("going_forward") }
                }
                notNow
            }
        }
    }

    private var notNow: some View {
        Button("Not now") {
            Task { await appModel.declinePendingPlanAdjustmentProposal() }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(MyoColor.Text.tertiary.color)
        .frame(minHeight: 44)
        .padding(.horizontal, MyoTheme.Spacing.sm)
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if appModel.isSending { ProgressView().tint(MyoTheme.Colors.ink) }
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .foregroundStyle(MyoTheme.Colors.ink)
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Capsule())
            .myoGlass(tint: MyoTheme.Colors.coachAmber.opacity(0.35))
        }
        .buttonStyle(.plain)
        .disabled(appModel.isSending)
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(MyoColor.Text.primary.color)
                .frame(maxWidth: .infinity, minHeight: 46)
                .contentShape(Capsule())
                .myoGlass()
        }
        .buttonStyle(.plain)
        .disabled(appModel.isSending)
    }

    private func apply(_ scope: String?) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { await appModel.acceptPendingPlanAdjustmentProposal(scope: scope) }
    }

    private static var todayKey: String {
        ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][Calendar.current.component(.weekday, from: Date()) - 1]
    }

    private var justOnceTitle: String {
        guard let day = proposal.dayKey, day != Self.todayKey else { return "Just today" }
        return "Just \(day)"
    }

    /// The reach has to be on the button — "Apply" alone would hide whether
    /// this is a one-day tweak or a permanent change.
    private var presetTitle: String {
        switch proposal.scope {
        case "today": return justOnceTitle
        case "rest_of_week": return "This week only"
        case "going_forward": return "Apply from now on"
        case "reentry_ramp": return "Start easing back in"
        default: return "Apply"
        }
    }
}
