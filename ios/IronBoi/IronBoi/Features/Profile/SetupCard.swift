import SwiftUI

/// The six things onboarding asked, changeable in one place with the same
/// choices — top of the You screen. Each change applies straight away (and
/// rebuilds the plan when it should); there's no Save. You can also just tell
/// the coach: "4 days a week now, I've got kettlebells" goes through the same
/// server path.
struct SetupCard: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject private var reminders = TrainingReminders.shared
    @State private var days: Set<String> = []
    @State private var time = Date()
    @State private var busy = false
    @State private var note: String?

    private static let week = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private static let goals: [(String, GoalType)] = [
        ("Build muscle", .muscleGain), ("Lose fat", .fatLoss), ("Get stronger", .strength),
        ("Feel fitter", .generalFitness), ("Get back into it", .returnToTraining),
    ]
    private static let experience: [(String, TrainingExperience)] = [
        ("New to this", .new), ("A little", .beginner), ("Trained before", .intermediate), ("Experienced", .advanced),
    ]
    /// A place is the whole answer; gear can be combined ("dumbbells and
    /// kettlebells").
    private static let places: [(String, String)] = [
        ("Full gym", "full gym"), ("Home gym", "home gym"), ("Bodyweight", "bodyweight"),
    ]
    private static let gear: [(String, [String])] = [
        ("Dumbbells", ["dumbbells", "bench"]), ("Kettlebells", ["kettlebells"]), ("Resistance bands", ["bands"]),
    ]

    private var profile: UserProfile { appModel.profile }

    /// The plan's days as they are now (what the picker resets to).
    private var planDays: Set<String> {
        let fromPlan = Self.week.filter { key in
            appModel.currentWorkoutPlan?.days.contains { $0.dayKey == key && !$0.exercises.isEmpty } == true
        }
        return Set(fromPlan.isEmpty ? profile.schedule.preferredDays : fromPlan)
    }

    private var scheduleChanged: Bool {
        days != planDays || abs(time.timeIntervalSince(reminders.time)) > 59
    }

    var body: some View {
        MyoGroupCard {
            MyoSectionLabel(text: "Your setup")
            Text("What you told Coach at the start. Change anything; your plan follows. Or just tell Coach.")
                .font(.caption)
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.5))

            row("Goal") {
                ForEach(Self.goals, id: \.0) { label, goal in
                    MyoSelectChip(label: label, isSelected: profile.goals.first == goal) {
                        apply(["goals": [goal.rawValue]], done: "Goal saved.")
                    }
                }
            }

            row("Experience") {
                ForEach(Self.experience, id: \.0) { label, level in
                    MyoSelectChip(label: label, isSelected: profile.trainingExperience == level) {
                        apply(["trainingExperience": level.rawValue], done: "Got it. Your weights are set for that.")
                    }
                }
            }

            row("Where you train") {
                ForEach(Self.places, id: \.0) { label, place in
                    MyoSelectChip(label: label, isSelected: have.contains(place)) {
                        apply(["equipment": [place]], done: "Your plan now uses what you have.")
                    }
                }
                ForEach(Self.gear, id: \.0) { label, items in
                    let on = have.contains(items[0])
                    MyoSelectChip(label: label, isSelected: on) {
                        // Toggle this gear; a "place" answer gives way to a list of gear.
                        var next = have.filter { item in !Self.places.contains { $0.1 == item } }
                        if on { next.removeAll { items.contains($0) } } else { next.append(contentsOf: items) }
                        if next.isEmpty { next = ["bodyweight"] }
                        apply(["equipment": Array(NSOrderedSet(array: next)) as? [String] ?? next],
                              done: "Your plan now uses what you have.")
                    }
                }
            }

            VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
                Text("Training days")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MyoColor.Text.primary.color)
                HStack(spacing: 6) {
                    ForEach(Self.week, id: \.self) { day in
                        let on = days.contains(day)
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if on { days.remove(day) } else { days.insert(day) }
                        } label: {
                            Text(String(day.prefix(1)))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(on ? MyoTheme.Colors.ink : MyoColor.Text.secondary.color)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(Circle().fill(on ? MyoTheme.Colors.coachAmber.opacity(0.55) : Color.clear))
                                .overlay(Circle().stroke(on ? Color.clear : MyoColor.hairline, lineWidth: 1))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(day)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                HStack {
                    Text("At")
                        .font(.subheadline)
                        .foregroundStyle(MyoColor.Text.secondary.color)
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Spacer()
                    if scheduleChanged {
                        Button {
                            saveSchedule()
                        } label: {
                            Text("Save days")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(MyoTheme.Colors.ink)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 40)
                                .myoGlass(tint: MyoTheme.Colors.coachAmber.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .disabled(days.isEmpty || busy)
                    }
                }
            }
            .padding(.top, MyoTheme.Spacing.xs)

            if busy || note != nil {
                HStack(spacing: MyoTheme.Spacing.sm) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(busy ? "Updating your plan…" : note ?? "")
                        .font(.footnote)
                        .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                }
            }
        }
        .onAppear {
            days = planDays
            time = reminders.time
        }
        .onChange(of: appModel.currentWorkoutPlan?.days.map(\.dayKey)) { _, _ in
            if !busy { days = planDays }
        }
    }

    private func row(_ title: String, @ViewBuilder chips: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MyoColor.Text.primary.color)
            FlowLayout(spacing: MyoTheme.Spacing.sm) { chips() }
        }
        .padding(.top, MyoTheme.Spacing.xs)
    }

    private func saveSchedule() {
        let ordered = Self.week.filter { days.contains($0) }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let clock = String(format: "%02d:%02d", parts.hour ?? 18, parts.minute ?? 0)
        reminders.setPreferredTime(time)
        if reminders.enabled { Task { await reminders.enable(at: time) } }
        apply(["preferredDays": ordered, "preferredTime": clock], done: nil)
    }

    private func apply(_ change: [String: Any], done: String?) {
        guard !busy else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        busy = true
        note = nil
        Task {
            let result = await appModel.updateTrainingSetup(change)
            busy = false
            guard let result else { note = "Couldn't save that. Try again."; return }
            let list = Self.list(result.trainingDays)
            note = done.map { result.rebuiltPlan && !list.isEmpty ? "\($0) Training \(list)." : $0 }
                ?? "Saved. Training \(list)."
            if result.keptAdjustments > 0 { note! += " Your current adjustments are kept." }
        }
    }

    /// What they have, normalized ("Dumbbells" → "dumbbells", "kettlebell" → "kettlebells").
    private var have: [String] {
        profile.equipment.map { item in
            let lower = item.lowercased().trimmingCharacters(in: .whitespaces)
            if lower.contains("kettle") { return "kettlebells" }
            if lower.contains("dumbbell") { return "dumbbells" }
            if lower.contains("band") { return "bands" }
            if lower.contains("body") || lower == "none" { return "bodyweight" }
            return lower
        }
    }

    private static func list(_ days: [String]) -> String {
        guard days.count > 1 else { return days.first ?? "" }
        return days.dropLast().joined(separator: ", ") + " and " + days.last!
    }
}

/// What the server sends back after a setup change.
struct TrainingSetupResult: Decodable {
    let ok: Bool
    let changed: [String]
    let rebuiltPlan: Bool
    let trainingDays: [String]
    let keptAdjustments: Int
}
