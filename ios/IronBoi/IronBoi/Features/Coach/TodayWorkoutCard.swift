import SwiftUI

/// Today's session as a card — what pops up when you ask Coach for your
/// workout. Reads the live plan, so it's always the real numbers, not the
/// coach's retelling of them.
struct TodayWorkoutCard: View {
    @EnvironmentObject private var appModel: AppModel
    let onClose: () -> Void
    let onBegin: () -> Void

    private static var todayKey: String {
        let weekday = Calendar.current.component(.weekday, from: Date())
        return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][weekday - 1]
    }

    /// Today's session; nil on a rest day (a day with nothing in it counts).
    private var today: PlannedWorkoutDay? { appModel.todayPlanDay }

    /// The next planned day after today, for the rest-day card.
    private var nextDay: PlannedWorkoutDay? {
        let order = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        guard let days = appModel.currentWorkoutPlan?.days, !days.isEmpty,
              let index = order.firstIndex(of: Self.todayKey) else { return nil }
        for offset in 1...7 {
            let key = order[(index + offset) % 7]
            if let day = days.first(where: { $0.dayKey == key }) { return day }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MyoHairline()
            if let day = today {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(day.exercises.enumerated()), id: \.offset) { index, exercise in
                            if index > 0 { MyoHairline().padding(.leading, 52) }
                            row(index: index + 1, exercise: exercise)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                MyoHairline()
                footer
            } else {
                restDay
            }
        }
        .frame(maxWidth: .infinity)
        .myoCard()
        .shadow(color: MyoTheme.Colors.ink.opacity(0.10), radius: 28, y: 10)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today · \(Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))")
                    .myoStyle(.label)
                    .textCase(.uppercase)
                    .kerning(0.5)
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
                .padding(.trailing, -MyoTheme.Spacing.sm)
                .accessibilityLabel("Close")
            }
            .padding(.bottom, -MyoTheme.Spacing.sm)

            Text(today?.name ?? "Rest day")
                .font(.system(.title, design: .default).weight(.bold))
                .foregroundStyle(MyoColor.Text.primary.color)
                .fixedSize(horizontal: false, vertical: true)

            if let day = today {
                HStack(spacing: MyoTheme.Spacing.lg) {
                    stat("\(day.exercises.count)", "exercises")
                    stat("\(day.totalSets)", "sets")
                    if let minutes = appModel.profile.schedule.sessionLengthMin {
                        stat("~\(minutes)", "min")
                    }
                }
                .padding(.top, 2)

                if !day.muscles.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(day.muscles, id: \.self) { muscle in
                            Text(muscle)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(MyoColor.Text.secondary.color)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(MyoTheme.Colors.coachAmber.opacity(0.14), in: Capsule())
                        }
                    }
                    .padding(.top, 2)
                }

                if day.isAdjusted {
                    Text("Adjusted by Coach for today")
                        .myoStyle(.label)
                        .textCase(.uppercase)
                        .foregroundStyle(MyoTheme.Colors.ochre)
                }
            }
        }
        .padding(.horizontal, MyoTheme.Spacing.lg)
        .padding(.top, MyoTheme.Spacing.md)
        .padding(.bottom, MyoTheme.Spacing.lg)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(MyoColor.Text.primary.color)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(MyoColor.Text.tertiary.color)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(index: Int, exercise: PlannedExercise) -> some View {
        HStack(alignment: .center, spacing: MyoTheme.Spacing.md) {
            Text(String(format: "%02d", index))
                .font(.system(.footnote, design: .monospaced).weight(.medium))
                .foregroundStyle(MyoColor.Text.disabled.color)
                .frame(width: 20, alignment: .leading)

            Text(exercise.name)
                .font(.body.weight(.semibold))
                .foregroundStyle(MyoColor.Text.primary.color)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: MyoTheme.Spacing.sm)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(exercise.sets) × \(exercise.reps)")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(MyoColor.Text.primary.color)
                Text(exercise.weight > 0 ? "\(Self.pounds(exercise.weight)) lb" : "bodyweight")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(MyoColor.Text.tertiary.color)
            }
        }
        .padding(.horizontal, MyoTheme.Spacing.lg)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: MyoTheme.Spacing.sm) {
            Button(action: onClose) {
                Text("Later")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MyoColor.Text.secondary.color)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .overlay(Capsule().stroke(MyoColor.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 120)

            Button(action: onBegin) {
                HStack(spacing: MyoTheme.Spacing.sm) {
                    if appModel.isWorkoutBusy { ProgressView().tint(MyoTheme.Colors.cream) }
                    Text(appModel.activeWorkout == nil ? "Begin workout" : "Resume workout")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(MyoTheme.Colors.cream)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(MyoTheme.Colors.ink, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(appModel.isWorkoutBusy)
        }
        .padding(MyoTheme.Spacing.md)
    }

    private var restDay: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            Text("Nothing planned today. Recover, walk, sleep well.")
                .myoStyle(.body)
                .foregroundStyle(MyoColor.Text.secondary.color)
            if let next = nextDay {
                HStack {
                    Text("Next · \(next.dayKey)")
                        .myoStyle(.label)
                        .textCase(.uppercase)
                        .foregroundStyle(MyoColor.Text.tertiary.color)
                    Text(next.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MyoColor.Text.primary.color)
                }
            }
        }
        .padding(MyoTheme.Spacing.lg)
    }

    private static func pounds(_ weight: Double) -> String {
        weight.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(weight)) : String(format: "%.1f", weight)
    }
}

/// "What's my workout today?" and the many ways people say it.
enum WorkoutAsk {
    static func matches(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let patterns = [
            #"\b(workout|session|training|lift|lifting|plan|program)\b.*\b(today|tonight)\b"#,
            #"\b(today|tonight)'?s? (workout|session|training|lift|plan)\b"#,
            #"\bwhat('s| is| am i| do i| should i)\b.*\b(do|doing|train|training|lift|lifting)\b.*\btoday\b"#,
            #"\b(show|give|tell)\b.*\b(me|my)\b.*\b(workout|session)\b"#,
            #"\bwhat('s| is) my (workout|session)\b"#,
        ]
        return patterns.contains { t.range(of: $0, options: .regularExpression) != nil }
    }
}
