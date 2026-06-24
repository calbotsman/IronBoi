import SwiftUI

/// The "You" tab — the training Dossier. Cream paper, typewriter labels,
/// brick/ochre selection, sticky save bar. No stock Form chrome.
/// Built to docs/design/myo-you-tab-layout-spec.md.
struct PreferencesView: View {
    @EnvironmentObject private var appModel: AppModel

    // Local editing copy. Seeded from appModel.profile on appear and
    // refreshed if Firestore pushes a new version while we're not editing.
    @State private var draft: UserProfile = .empty
    @State private var newEquipment = ""
    @State private var newInjury = ""
    @State private var newDietaryConstraint = ""
    @State private var newDislikedExercise = ""
    @State private var showRegenerateConfirm = false
    @State private var showRebuildOffer = false
    @State private var regenerateMessage: String?
    @State private var lastSaveSucceeded: Bool?
    @State private var saveGeneration = 0
    @State private var contentVisible = false

    private var hasLocalEdits: Bool { draft != appModel.profile }

    // The four fields that gate a "good first save" (spec §1).
    private var requiredFilled: Int {
        var n = 0
        if draft.ageYears != nil { n += 1 }
        if draft.trainingExperience != nil { n += 1 }
        if draft.schedule.daysPerWeek != nil { n += 1 }
        if draft.schedule.sessionLengthMin != nil { n += 1 }
        return n
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: MyoTheme.Spacing.xl) {
                    whoYouAreCard
                    goalsCard
                    setupCard
                    coachCard
                    limitsCard
                    regenerateCard
                }
                .padding(.horizontal, MyoTheme.Spacing.md)
                .padding(.top, MyoTheme.Spacing.lg)
                .padding(.bottom, MyoTheme.Spacing.md)
                .opacity(contentVisible ? 1 : 0)
            }
            .background(PaperBackground())
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { EmptyView() } }
            .safeAreaInset(edge: .top) { header }
            .safeAreaInset(edge: .bottom) { saveBar }
            .confirmationDialog(
                "Saved. Rebuild your plan?",
                isPresented: $showRebuildOffer,
                titleVisibility: .visible
            ) {
                Button("Rebuild plan now") { Task { await regenerate() } }
                Button("Later", role: .cancel) {}
            } message: {
                Text("These changes affect how Coach programs your week. Rebuild now to apply them, or keep your current plan and let Coach adjust as you train.")
            }
            .onAppear {
                draft = appModel.profile
                withAnimation(.easeOut(duration: 0.2)) { contentVisible = true }
            }
            .onChange(of: appModel.profile) { _, next in
                if !appModel.isSavingProfile, !hasLocalEdits { draft = next }
            }
        }
    }

    // MARK: - Header (non-scrolling)

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This is how I see you, today.")
                .myoStyle(.display)
                .foregroundStyle(MyoColor.Text.primary.color)
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.72)

            HStack(spacing: MyoTheme.Spacing.sm) {
                completionPill
                if hasLocalEdits {
                    Circle()
                        .fill(MyoTheme.Colors.ochre)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("Unsaved changes")
                }
            }

            Text("Coach uses this to write your plan. Keep it honest.")
                .myoStyle(.body)
                .foregroundStyle(MyoColor.Text.secondary.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MyoTheme.Spacing.md)
        .padding(.top, MyoTheme.Spacing.sm)
        .padding(.bottom, MyoTheme.Spacing.md)
        .background(MyoTheme.Colors.cream)
    }

    private var completionPill: some View {
        let complete = requiredFilled == 4
        return Text(complete ? "Profile complete" : "\(requiredFilled) of 4 required")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(complete ? MyoTheme.Colors.cream : MyoTheme.Colors.ink)
            .padding(.horizontal, MyoTheme.Spacing.md)
            .padding(.vertical, 6)
            .background(complete ? MyoTheme.Colors.ink : MyoTheme.Colors.ochreLight)
            .clipShape(Capsule())
    }

    // MARK: - Group 1: Who you are

    private var whoYouAreCard: some View {
        MyoGroupCard {
            MyoSectionLabel(text: "Your profile")

            MyoValueRow(label: "Age") {
                TextField("e.g. 32", value: $draft.ageYears, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: 72)
            }

            MyoValueRow(label: "Sex / gender") {
                Picker("Sex / gender", selection: $draft.sexOrGender) {
                    Text("—").tag(UserSex?.none)
                    ForEach(UserSex.allCases) { Text($0.displayName).tag(UserSex?.some($0)) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            if draft.sexOrGender == .selfDescribed {
                TextField("Self-described", text: Binding(
                    get: { draft.sexOrGenderSelfDescription ?? "" },
                    set: { draft.sexOrGenderSelfDescription = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }

            MyoValueRow(label: "Height (cm)") {
                TextField("optional", value: $draft.heightCm, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: 96)
            }

            MyoValueRow(label: "Weight (kg)") {
                TextField("optional", value: $draft.weightKg, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: 96)
            }

            MyoHairline().padding(.vertical, MyoTheme.Spacing.xs)

            MyoSectionLabel(text: "Experience")
            // Single-select chip row instead of a system segmented control,
            // to hold the cream palette (Deter: no system chrome on paper).
            FlowLayout(spacing: MyoTheme.Spacing.sm) {
                ForEach(TrainingExperience.allCases) { level in
                    MyoSelectChip(
                        label: level.displayName,
                        isSelected: draft.trainingExperience == level
                    ) {
                        draft.trainingExperience = level
                    }
                }
            }
        }
    }

    // MARK: - Group 2: What you're after

    private var goalsCard: some View {
        MyoGroupCard {
            MyoSectionLabel(text: "Your goals")

            FlowLayout(spacing: MyoTheme.Spacing.sm) {
                ForEach(GoalType.allCases) { goal in
                    MyoSelectChip(
                        label: goal.displayName,
                        isSelected: draft.goals.contains(goal)
                    ) {
                        if let i = draft.goals.firstIndex(of: goal) {
                            draft.goals.remove(at: i)
                        } else {
                            draft.goals.append(goal)
                        }
                    }
                }
            }

            if draft.goals.isEmpty {
                Text("Pick at least one.")
                    .font(.caption)
                    .foregroundStyle(MyoTheme.Colors.ochre)
            }

            TextField(
                "Any specific target? e.g. squat 2× bodyweight",
                text: Binding(
                    get: { draft.goalNotes ?? "" },
                    set: { draft.goalNotes = $0.isEmpty ? nil : $0 }
                ),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...4)
        }
    }

    // MARK: - Group 3: Your setup

    private var setupCard: some View {
        MyoGroupCard {
            MyoSectionLabel(text: "Your program")

            Stepper(value: Binding(
                get: { draft.schedule.daysPerWeek ?? 3 },
                set: { draft.schedule.daysPerWeek = $0 }
            ), in: 1...7) {
                MyoValueRow(label: "Days per week") {
                    Text("\(draft.schedule.daysPerWeek ?? 3)")
                        .font(.body).monospacedDigit()
                        .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                }
            }

            Stepper(value: Binding(
                get: { draft.schedule.sessionLengthMin ?? 45 },
                set: { draft.schedule.sessionLengthMin = $0 }
            ), in: 15...180, step: 15) {
                MyoValueRow(label: "Session length") {
                    Text("\(draft.schedule.sessionLengthMin ?? 45) min")
                        .font(.body).monospacedDigit()
                        .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                }
            }

            MyoValueRow(label: "Preferred time") {
                Picker("Preferred time", selection: $draft.preferences.preferredWorkoutTime) {
                    ForEach(PreferredWorkoutTime.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            MyoHairline().padding(.vertical, MyoTheme.Spacing.xs)

            MyoSectionLabel(text: "Equipment")
            tagEditor(
                tags: $draft.equipment,
                draft: $newEquipment,
                placeholder: "Add equipment (e.g. barbell)",
                sentinel: "Bodyweight"
            )
            Text("What you have access to. Helps Coach pick exercises you can actually do.")
                .font(.caption)
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.5))
        }
    }

    // MARK: - Group 4: Your coach

    private var coachCard: some View {
        MyoGroupCard {
            MyoSectionLabel(text: "Your coach")

            MyoValueRow(label: "Tone") {
                Picker("Tone", selection: $draft.preferences.coachingTone) {
                    ForEach(CoachingTone.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            MyoValueRow(label: "Methodology") {
                Picker("Methodology", selection: $draft.preferences.trainingFocus) {
                    ForEach(TrainingFocus.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            MyoHairline().padding(.vertical, MyoTheme.Spacing.xs)

            MyoSectionLabel(text: "Coaching protocol")
            MyoValueRow(label: "Protocol") {
                Picker("Protocol", selection: $draft.preferences.coachingLens) {
                    ForEach(CoachingLens.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            Text(draft.preferences.coachingLens.blurb)
                .font(.caption)
                .foregroundStyle(MyoColor.Text.tertiary.color)
            Text("Shapes how Coach reasons and explains — never what's safe.")
                .font(.caption2)
                .foregroundStyle(MyoColor.Text.disabled.color)
        }
    }

    // MARK: - Group 5: Limits + avoids

    private var limitsCard: some View {
        MyoGroupCard {
            MyoSectionLabel(text: "Your non-negotiables")

            MyoSectionLabel(text: "Injuries / limitations")
            tagEditor(
                tags: $draft.injuriesOrLimitations,
                draft: $newInjury,
                placeholder: "e.g. left knee meniscus",
                sentinel: "None right now"
            )
            Text("Coach avoids exercises that aggravate these.")
                .font(.caption)
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.5))

            MyoHairline().padding(.vertical, MyoTheme.Spacing.xs)

            MyoSectionLabel(text: "Dietary")
            tagEditor(
                tags: $draft.dietaryConstraints,
                draft: $newDietaryConstraint,
                placeholder: "e.g. vegetarian, lactose-free"
            )

            MyoHairline().padding(.vertical, MyoTheme.Spacing.xs)

            MyoSectionLabel(text: "Disliked exercises")
            tagEditor(
                tags: $draft.preferences.dislikedExercises,
                draft: $newDislikedExercise,
                placeholder: "e.g. burpees, deadlifts"
            )
            Text("Coach will try to avoid these unless you opt in.")
                .font(.caption)
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.5))
        }
    }

    // MARK: - Rebuild plan

    private var regenerateCard: some View {
        MyoGroupCard {
            MyoSectionLabel(text: "Plan")
            Button {
                showRegenerateConfirm = true
            } label: {
                HStack(spacing: MyoTheme.Spacing.sm) {
                    if appModel.isWorkoutBusy { ProgressView().tint(MyoTheme.Colors.ink) }
                    Text("Rebuild my workout plan")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(MyoTheme.Colors.ink)
                    Spacer()
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(MyoTheme.Colors.ink.opacity(0.5))
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(appModel.isWorkoutBusy)

            Text("Overwrites your current week with a fresh plan from your preferences. Coach-chat customizations will be lost.")
                .font(.caption)
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.5))

            if let regenerateMessage {
                Text(regenerateMessage)
                    .font(.caption)
                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
            }
        }
        .alert("Rebuild plan?", isPresented: $showRegenerateConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Rebuild", role: .destructive) { Task { await regenerate() } }
        } message: {
            Text("This overwrites your current weekly plan with one built from your preferences. Anything you've adjusted via the coach will be lost.")
        }
    }

    // MARK: - Sticky save bar

    private var saveBar: some View {
        VStack(spacing: 0) {
            MyoHairline()
            Button {
                Task { await save() }
            } label: {
                Group {
                    if appModel.isSavingProfile {
                        ProgressView().tint(MyoTheme.Colors.cream)
                    } else if let icon = saveIcon {
                        Label(saveLabel, systemImage: icon)
                            .font(.body.weight(.semibold))
                    } else {
                        Text(saveLabel)
                            .font(.body.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(saveTint)
            .foregroundStyle(MyoTheme.Colors.cream)
            // Disabled unless there are edits to save, OR we're in the failed
            // state (so "tap to retry" works). The "Saved" confirmation is NOT
            // a CTA — disable it so it can't trigger a redundant re-save.
            .disabled(appModel.isSavingProfile || (!hasLocalEdits && lastSaveSucceeded != false))
            .padding(.horizontal, MyoTheme.Spacing.md)
            .padding(.vertical, MyoTheme.Spacing.sm)
        }
        .background(MyoTheme.Colors.cream)
    }

    private var saveLabel: String {
        if lastSaveSucceeded == true { return "Saved" }
        if lastSaveSucceeded == false { return "Failed — tap to retry" }
        return "Save"
    }

    /// Icon shown only for the success/failure states; nil keeps idle "Save" clean.
    private var saveIcon: String? {
        if lastSaveSucceeded == true { return "checkmark.circle.fill" }
        if lastSaveSucceeded == false { return "exclamationmark.triangle.fill" }
        return nil
    }

    private var saveTint: Color {
        if lastSaveSucceeded == false { return MyoColor.State.danger.color }
        if lastSaveSucceeded == true { return MyoColor.State.success.color }
        return MyoTheme.Colors.ink
    }

    // MARK: - Tag editor helper

    @ViewBuilder
    private func tagEditor(
        tags: Binding<[String]>,
        draft: Binding<String>,
        placeholder: String,
        sentinel: String? = nil
    ) -> some View {
        if !tags.wrappedValue.isEmpty {
            FlowLayout(spacing: MyoTheme.Spacing.sm) {
                ForEach(Array(tags.wrappedValue.enumerated()), id: \.offset) { idx, item in
                    MyoTagChip(label: item) { tags.wrappedValue.remove(at: idx) }
                }
            }
        }

        HStack(spacing: MyoTheme.Spacing.sm) {
            if let sentinel, tags.wrappedValue.isEmpty {
                MyoSelectChip(label: sentinel, isSelected: false) {
                    tags.wrappedValue.append(sentinel)
                }
            }
            TextField(placeholder, text: draft)
                .textFieldStyle(.roundedBorder)
            Button("Add") {
                let next = draft.wrappedValue.trimmingCharacters(in: .whitespaces)
                guard !next.isEmpty else { return }
                tags.wrappedValue.append(next)
                draft.wrappedValue = ""
            }
            .controlSize(.small)
            .tint(MyoColor.Action.primary.color)
            .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Actions

    private func save() async {
        if lastSaveSucceeded == false { lastSaveSucceeded = nil }
        // Snapshot the currently-saved profile before the write so we can tell
        // whether the user changed anything that affects how the plan is built.
        let baseline = appModel.profile
        await appModel.upsertProfile(draft)
        let succeeded = appModel.errorMessage == nil
        withAnimation(MyoTheme.Motion.fade) { lastSaveSucceeded = succeeded }
        guard succeeded else { return }

        // The dead-end fix: if a programming-affecting field changed, don't
        // leave the user wondering — offer to rebuild the plan so the change
        // is actually visible. Lens/tone changes are explanation-only and the
        // coach picks them up on the next message, so they don't trigger this.
        if Self.programmingChanged(from: baseline, to: draft) {
            showRebuildOffer = true
        }

        // Generation guard: if another save fires during the 1.5s window, only
        // the latest one's reset should win — otherwise an earlier reset clears
        // a newer save's "Saved"/"Failed" state.
        saveGeneration += 1
        let generation = saveGeneration
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard generation == saveGeneration else { return }
        withAnimation(MyoTheme.Motion.fade) { lastSaveSucceeded = nil }
    }

    /// Fields that change how the weekly plan is generated. A change here means
    /// the user's current plan no longer matches their stated preferences.
    private static func programmingChanged(from old: UserProfile, to new: UserProfile) -> Bool {
        old.goals != new.goals
            || old.trainingExperience != new.trainingExperience
            || old.equipment != new.equipment
            || old.schedule.daysPerWeek != new.schedule.daysPerWeek
            || old.schedule.sessionLengthMin != new.schedule.sessionLengthMin
            || old.preferences.trainingFocus != new.preferences.trainingFocus
    }

    private func regenerate() async {
        regenerateMessage = nil
        await appModel.regenerateWorkoutPlan()
        if appModel.errorMessage == nil {
            regenerateMessage = "Plan rebuilt. Check the Train tab."
        }
    }
}

#Preview {
    PreferencesView()
        .environmentObject(AppModel())
}
