import SwiftUI

/// The workout in progress, living on the Coach screen under the coach's
/// body — never over it. Minimized it's a slim bar: what you're on and how
/// far through. Tap it open for every exercise, set dots and weights.
struct LiveWorkoutCard: View {
    @EnvironmentObject private var appModel: AppModel
    let workout: ActiveWorkoutSession
    @Binding var expanded: Bool

    private var totalSets: Int { workout.exercises.reduce(0) { $0 + $1.targetSets } }
    private var doneSets: Int { workout.exercises.reduce(0) { $0 + $1.completedSetCount } }
    private var progress: Double { totalSets == 0 ? 0 : Double(doneSets) / Double(totalSets) }
    private var currentIndex: Int? { workout.exercises.firstIndex { !$0.exerciseDone } }
    @State private var confirmDiscard = false

    /// Started on an earlier day: it's a leftover, not today's session.
    private var startedDay: String? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: workout.startedAt) ?? ISO8601DateFormatter().date(from: workout.startedAt),
              !Calendar.current.isDateInToday(date) else { return nil }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    private var statusLabel: String {
        startedDay.map { "Unfinished · \($0)" } ?? "In progress"
    }

    var body: some View {
        Group {
            if expanded { full } else { mini }
        }
        .frame(maxWidth: .infinity)
        .myoCard()
        .shadow(color: MyoTheme.Colors.ink.opacity(0.08), radius: 20, y: 8)
    }

    // MARK: - Minimized

    private var mini: some View {
        Button {
            withAnimation(MyoTheme.Motion.fade) { expanded = true }
        } label: {
            HStack(spacing: MyoTheme.Spacing.md) {
                ProgressRing(progress: progress)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(statusLabel)
                            .myoStyle(.label)
                            .textCase(.uppercase)
                            .foregroundStyle(MyoColor.redPen)
                        if startedDay == nil {
                            ElapsedText(startedAt: workout.startedAt)
                                .myoStyle(.label)
                                .foregroundStyle(MyoColor.Text.tertiary.color)
                        }
                    }
                    if let i = currentIndex {
                        let exercise = workout.exercises[i]
                        Text(exercise.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(MyoColor.Text.primary.color)
                            .lineLimit(1)
                        Text(nextSetLine(exercise))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(MyoColor.Text.tertiary.color)
                    } else {
                        Text("All sets done")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(MyoColor.Text.primary.color)
                        Text("Tap to finish")
                            .font(.caption)
                            .foregroundStyle(MyoColor.Text.tertiary.color)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.up")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MyoColor.Text.tertiary.color)
            }
            .padding(.horizontal, MyoTheme.Spacing.md)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows every exercise and set")
    }

    // MARK: - Expanded

    private var full: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 6) {
                        Text(statusLabel)
                            .myoStyle(.label)
                            .textCase(.uppercase)
                            .foregroundStyle(MyoColor.redPen)
                        if startedDay == nil {
                            ElapsedText(startedAt: workout.startedAt)
                                .myoStyle(.label)
                                .foregroundStyle(MyoColor.Text.tertiary.color)
                        }
                    }
                    Spacer()
                    Button {
                        withAnimation(MyoTheme.Motion.fade) { expanded = false }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MyoColor.Text.tertiary.color)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, -MyoTheme.Spacing.sm)
                    .accessibilityLabel("Minimize workout")
                }
                .padding(.bottom, -MyoTheme.Spacing.sm)

                Text(workout.workoutName)
                    .font(.system(.title2).weight(.bold))
                    .foregroundStyle(MyoColor.Text.primary.color)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: MyoTheme.Spacing.sm) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(MyoTheme.Colors.ink.opacity(0.08))
                            Capsule().fill(MyoTheme.Colors.coachAmber)
                                .frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 6)
                    Text("\(doneSets)/\(totalSets) sets")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(MyoColor.Text.tertiary.color)
                }
            }
            .padding(.horizontal, MyoTheme.Spacing.lg)
            .padding(.top, MyoTheme.Spacing.md)
            .padding(.bottom, MyoTheme.Spacing.md)

            MyoHairline()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(workout.exercises) { exercise in
                            if exercise.exerciseIndex > 0 { MyoHairline().padding(.leading, MyoTheme.Spacing.lg) }
                            exerciseRow(exercise, isCurrent: exercise.exerciseIndex == currentIndex)
                                .id(exercise.exerciseIndex)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onAppear { if let i = currentIndex { proxy.scrollTo(i, anchor: .top) } }
            }

            MyoHairline()

            Button {
                Task {
                    await appModel.finishActiveWorkout()
                    if appModel.activeWorkout == nil { expanded = false }
                }
            } label: {
                HStack(spacing: MyoTheme.Spacing.sm) {
                    if appModel.isWorkoutBusy { ProgressView().tint(MyoTheme.Colors.cream) }
                    Text("Finish workout").font(.body.weight(.semibold))
                }
                .foregroundStyle(MyoTheme.Colors.cream)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(MyoTheme.Colors.ink, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(appModel.isWorkoutBusy || doneSets == 0)
            .opacity(doneSets == 0 ? 0.4 : 1)
            .padding(.horizontal, MyoTheme.Spacing.md)
            .padding(.top, MyoTheme.Spacing.md)

            Button("Discard workout") { confirmDiscard = true }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(MyoColor.Text.tertiary.color)
                .frame(minHeight: 44)
                .padding(.bottom, MyoTheme.Spacing.xs)
                .disabled(appModel.isWorkoutBusy)
        }
        .alert("Discard this workout?", isPresented: $confirmDiscard) {
            Button("Keep it", role: .cancel) {}
            Button("Discard", role: .destructive) {
                Task {
                    await appModel.discardActiveWorkout()
                    expanded = false
                }
            }
        } message: {
            Text("Nothing from it will be saved to your history.")
        }
    }

    private func exerciseRow(_ exercise: ActiveWorkoutExercise, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: MyoTheme.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(exercise.exerciseDone ? MyoColor.Text.tertiary.color : MyoColor.Text.primary.color)
                        .strikethrough(exercise.exerciseDone, color: MyoColor.Text.tertiary.color)
                        .lineLimit(2)
                    Text("\(exercise.targetSets) × \(exercise.targetReps)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(MyoColor.Text.tertiary.color)
                }
                Spacer(minLength: 0)
                if exercise.targetWeight > 0 {
                    weightStepper(exercise)
                } else {
                    Text("bodyweight")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(MyoColor.Text.tertiary.color)
                }
            }

            // Set dots: tap one when the set's done.
            FlowLayout(spacing: 4) {
                ForEach(exercise.completedSets) { set in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(MyoTheme.Motion.fade) {
                            appModel.toggleWorkoutSet(exerciseIndex: exercise.exerciseIndex, setIndex: set.setIndex)
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(set.completed ? MyoTheme.Colors.ink : Color.clear)
                            Circle()
                                .stroke(set.completed ? Color.clear : MyoTheme.Colors.ink.opacity(0.25), lineWidth: 1.5)
                            Text("\(set.setIndex + 1)")
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .foregroundStyle(set.completed ? MyoTheme.Colors.cream : MyoColor.Text.secondary.color)
                        }
                        .frame(width: 34, height: 34)
                        .frame(width: 42, height: 44)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Set \(set.setIndex + 1)")
                    .accessibilityValue(set.completed ? "Done" : "Not done")
                }
            }
            .padding(.leading, -4)
        }
        .padding(.horizontal, MyoTheme.Spacing.lg)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? MyoTheme.Colors.coachAmber.opacity(0.08) : Color.clear)
    }

    private func weightStepper(_ exercise: ActiveWorkoutExercise) -> some View {
        let weight = appModel.workingWeight(for: exercise)
        return HStack(spacing: 2) {
            stepButton("minus", label: "Less weight") {
                appModel.setWorkoutExerciseWeight(exerciseIndex: exercise.exerciseIndex, weight: weight - 5)
            }
            Text("\(Self.pounds(weight)) lb")
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .foregroundStyle(MyoColor.Text.primary.color)
                .frame(minWidth: 54)
                .lineLimit(1)
            stepButton("plus", label: "More weight") {
                appModel.setWorkoutExerciseWeight(exerciseIndex: exercise.exerciseIndex, weight: weight + 5)
            }
        }
    }

    private func stepButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(MyoColor.Text.secondary.color)
                .frame(width: 30, height: 30)
                .background(MyoTheme.Colors.ink.opacity(0.06), in: Circle())
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func nextSetLine(_ exercise: ActiveWorkoutExercise) -> String {
        let next = min(exercise.completedSetCount + 1, exercise.targetSets)
        let weight = appModel.workingWeight(for: exercise)
        let load = weight > 0 ? " · \(Self.pounds(weight)) lb" : ""
        return "Set \(next) of \(exercise.targetSets) · \(exercise.targetReps) reps\(load)"
    }

    static func pounds(_ weight: Double) -> String {
        weight.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(weight)) : String(format: "%.1f", weight)
    }
}

private struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(MyoTheme.Colors.ink.opacity(0.08), lineWidth: 4)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(MyoTheme.Colors.coachAmber, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((progress * 100).rounded()))")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(MyoColor.Text.secondary.color)
        }
        .accessibilityLabel("\(Int((progress * 100).rounded())) percent done")
    }
}

/// "12:04" since the session started, ticking each second.
private struct ElapsedText: View {
    let startedAt: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(Self.start(startedAt) ?? context.date)))
                .monospacedDigit()
        }
    }

    private static func start(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
