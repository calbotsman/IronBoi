import SwiftUI

/// After a workout where you lifted a different weight than planned, Coach
/// asks once whether to carry it into next time. Nothing changes in the
/// plan until you say keep.
struct WeightFollowUpCard: View {
    @EnvironmentObject private var appModel: AppModel
    let suggestions: [BaselineSuggestion]

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
            Text("Workout done · next time")
                .myoStyle(.label)
                .textCase(.uppercase)
                .foregroundStyle(MyoColor.redPen)
            Text(suggestions.count == 1 ? "Keep the new weight?" : "Keep the new weights?")
                .font(.system(.title2).weight(.bold))
                .foregroundStyle(MyoColor.Text.primary.color)

            VStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, s in
                    if index > 0 { MyoHairline() }
                    HStack {
                        Text(s.exerciseName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(MyoColor.Text.primary.color)
                        Spacer()
                        Text("\(LiveWorkoutCard.pounds(s.fromLb)) → \(LiveWorkoutCard.pounds(s.toLb)) lb")
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                            .foregroundStyle(s.toLb > s.fromLb ? MyoTheme.Colors.ochre : MyoColor.Text.secondary.color)
                    }
                    .padding(.vertical, 10)
                }
            }

            HStack(spacing: MyoTheme.Spacing.sm) {
                Button {
                    appModel.dismissBaselineSuggestions()
                } label: {
                    Text("Not now")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(MyoColor.Text.secondary.color)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .overlay(Capsule().stroke(MyoColor.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 130)

                Button {
                    Task { await appModel.applyBaselineSuggestions(suggestions) }
                } label: {
                    HStack(spacing: MyoTheme.Spacing.sm) {
                        if appModel.isWorkoutBusy { ProgressView().tint(MyoTheme.Colors.cream) }
                        Text("Keep for next time").font(.body.weight(.semibold))
                    }
                    .foregroundStyle(MyoTheme.Colors.cream)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(MyoTheme.Colors.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(appModel.isWorkoutBusy)
            }
        }
        .padding(MyoTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .myoCard()
        .shadow(color: MyoTheme.Colors.ink.opacity(0.10), radius: 28, y: 10)
    }
}
