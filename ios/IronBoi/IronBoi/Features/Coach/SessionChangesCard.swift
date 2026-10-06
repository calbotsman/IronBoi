import SwiftUI

/// After a workout where you changed things on the fly — added a lift,
/// swapped one, skipped one, changed sets — asks whether to keep them.
/// Today's workout is already in your history as you did it either way;
/// "Keep them" asks Coach to carry the changes into your plan, which comes
/// back as a plan change to approve.
struct SessionChangesCard: View {
    @EnvironmentObject private var appModel: AppModel
    let changes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Workout done · your changes")
                    .myoStyle(.label)
                    .textCase(.uppercase)
                    .foregroundStyle(MyoColor.redPen)
                Spacer()
                Button {
                    appModel.dismissSessionChanges()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MyoColor.Text.tertiary.color)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -MyoTheme.Spacing.md)
                .padding(.trailing, -MyoTheme.Spacing.sm)
                .accessibilityLabel("Dismiss")
            }
            Text("Keep these for next time?")
                .font(.system(.title2).weight(.bold))
                .foregroundStyle(MyoColor.Text.primary.color)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(changes.enumerated()), id: \.offset) { index, change in
                    if index > 0 { MyoHairline() }
                    Text(change)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(MyoColor.Text.primary.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                }
            }

            Text("Today's workout is saved to your history either way.")
                .font(.footnote)
                .foregroundStyle(MyoColor.Text.tertiary.color)

            HStack(spacing: MyoTheme.Spacing.sm) {
                Button {
                    appModel.dismissSessionChanges()
                } label: {
                    Text("Just today")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(MyoColor.Text.secondary.color)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .overlay(Capsule().stroke(MyoColor.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 130)

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    Task { await appModel.keepSessionChanges() }
                } label: {
                    Text("Keep them")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(MyoTheme.Colors.ink)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .contentShape(Capsule())
                        .myoGlass(tint: MyoTheme.Colors.coachAmber.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(MyoTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .myoCard()
        .shadow(color: MyoTheme.Colors.ink.opacity(0.10), radius: 28, y: 10)
    }
}
