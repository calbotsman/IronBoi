import SwiftUI

/// "How did that feel?" — one tap, right after the recap. Saved on the
/// workout's log; skipping is fine.
struct EffortCard: View {
    let onAnswer: (WorkoutEffort) -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Workout done")
                    .myoStyle(.label)
                    .textCase(.uppercase)
                    .foregroundStyle(MyoColor.redPen)
                Spacer()
                Button(action: onSkip) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MyoColor.Text.tertiary.color)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -MyoTheme.Spacing.md)
                .padding(.trailing, -MyoTheme.Spacing.sm)
                .accessibilityLabel("Skip")
            }
            Text("How did that feel?")
                .font(.system(.title2).weight(.bold))
                .foregroundStyle(MyoColor.Text.primary.color)

            HStack(spacing: MyoTheme.Spacing.sm) {
                ForEach(WorkoutEffort.allCases) { effort in
                    Button { onAnswer(effort) } label: {
                        Text(effort.label)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(effort == .aboutRight ? MyoTheme.Colors.ink : MyoColor.Text.primary.color)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .contentShape(Capsule())
                            .myoGlass(tint: effort == .aboutRight ? MyoTheme.Colors.coachAmber.opacity(0.35) : nil)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(MyoTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .myoCard()
        .shadow(color: MyoTheme.Colors.shadow.opacity(0.10), radius: 28, y: 10)
    }
}

/// After the workout, once "How did that feel?" is answered: what it moved.
/// Records set, weights that go up next time, the streak — a few lines,
/// closed with the cross.
struct TrainingRecapCard: View {
    let recap: TrainingRecapModel
    let onClose: () -> Void

    private struct Line: Identifiable {
        let id: String
        let icon: String
        let text: String
    }

    private var lines: [Line] {
        var lines: [Line] = []
        for record in recap.records.prefix(2) {
            let label: String
            switch record.kind {
            case "heaviest": label = "Heaviest yet"
            case "most_reps": label = "Most reps yet"
            default: label = "Best set yet"
            }
            let load = record.weightLb > 0 ? " \(WeightLoad.number(record.weightLb)) lb" : ""
            let reps = record.reps > 0 ? " × \(record.reps)" : ""
            lines.append(Line(id: "record-\(record.id)", icon: "trophy.fill",
                              text: "\(label): \(record.exerciseName)\(load)\(reps)"))
        }
        for next in recap.nextWeights.prefix(3) {
            let delta = next.toLb - next.fromLb
            let change = delta == 0 ? "" : " (\(delta > 0 ? "+" : "−")\(WeightLoad.number(abs(delta))))"
            lines.append(Line(id: "next-\(next.id)", icon: delta < 0 ? "arrow.down" : "arrow.up",
                              text: "Next time: \(next.exerciseName) \(WeightLoad.number(next.toLb)) lb\(change)"))
        }
        if recap.streakWeeks > 0 {
            lines.append(Line(id: "streak", icon: "flame.fill",
                              text: recap.streakWeeks == 1 ? "1-week streak" : "\(recap.streakWeeks)-week streak"))
        }
        return lines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your progress")
                    .myoStyle(.label)
                    .textCase(.uppercase)
                    .foregroundStyle(MyoColor.redPen)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MyoColor.Text.tertiary.color)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -MyoTheme.Spacing.md)
                .padding(.trailing, -MyoTheme.Spacing.sm)
                .accessibilityLabel("Close")
            }

            VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: MyoTheme.Spacing.sm) {
                        Image(systemName: line.icon)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MyoTheme.Colors.coachAmber)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        Text(line.text)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(MyoColor.Text.primary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(MyoTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .myoCard()
        .shadow(color: MyoTheme.Colors.shadow.opacity(0.10), radius: 28, y: 10)
    }
}

/// Once, after a workout: a nudge on training days, at a time you pick.
/// Asked here — when you've just shown up — rather than on first launch.
struct ReminderSetupCard: View {
    /// "Mon, Wed and Fri".
    let days: String
    @Binding var time: Date
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
            Text("Training days")
                .myoStyle(.label)
                .textCase(.uppercase)
                .foregroundStyle(MyoColor.redPen)
            Text("Want a nudge on training days?")
                .font(.system(.title2).weight(.bold))
                .foregroundStyle(MyoColor.Text.primary.color)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(days)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MyoColor.Text.primary.color)
                Spacer()
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }

            Text("One reminder on those days, nothing on rest days. If you miss one, one note the next morning. That's it.")
                .font(.footnote)
                .foregroundStyle(MyoColor.Text.tertiary.color)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: MyoTheme.Spacing.sm) {
                Button(action: onDecline) {
                    Text("No thanks")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(MyoColor.Text.secondary.color)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .overlay(Capsule().stroke(MyoColor.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 130)

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onAccept()
                } label: {
                    Text("Remind me")
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
        .shadow(color: MyoTheme.Colors.shadow.opacity(0.10), radius: 28, y: 10)
    }
}

/// The first thing you see after onboarding: a title, not a chat line. Same
/// voice as the intro screen — big and centred, one line under it, your week
/// as a strip of days, and a quiet nudge to start.
struct WelcomeCaption: View {
    let name: String?
    let trainingDays: [String]

    private static let week = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        VStack(spacing: MyoTheme.Spacing.sm) {
            Text(name.map { "Welcome, \($0)." } ?? "Welcome.")
                .font(.system(size: 40, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(MyoColor.Text.primary.color)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text("Your first week is ready.")
                .myoStyle(.title)
                .foregroundStyle(MyoColor.Text.secondary.color)

            HStack(spacing: 6) {
                ForEach(Self.week, id: \.self) { day in
                    let on = trainingDays.contains(day)
                    Text(String(day.prefix(1)))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(on ? MyoTheme.Colors.ink : MyoColor.Text.tertiary.color)
                        .frame(width: 28, height: 28)
                        .background {
                            Circle().fill(on ? MyoTheme.Colors.coachAmber.opacity(0.55) : Color.clear)
                        }
                        .overlay {
                            Circle().stroke(on ? Color.clear : MyoColor.hairline, lineWidth: 1)
                        }
                        .accessibilityLabel(on ? "\(day), training day" : "\(day), rest")
                }
            }
            .padding(.top, MyoTheme.Spacing.sm)

            Text("First session today. Short on purpose.")
                .myoStyle(.body)
                .foregroundStyle(MyoColor.Text.tertiary.color)
                .multilineTextAlignment(.center)
                .padding(.top, MyoTheme.Spacing.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, MyoTheme.Spacing.md)
        .accessibilityElement(children: .combine)
    }
}
