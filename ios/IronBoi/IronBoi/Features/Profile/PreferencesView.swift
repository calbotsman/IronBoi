import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject private var appModel: AppModel

    // Local editing copy. Seeded from appModel.profile on appear and
    // refreshed if Firestore pushes a new version while we're not editing.
    @State private var draft: UserProfile = .empty
    @State private var newEquipment: String = ""
    @State private var newInjury: String = ""
    @State private var newDietaryConstraint: String = ""
    @State private var newDislikedExercise: String = ""
    @State private var saveMessage: String?
    @State private var showRegenerateConfirm = false
    @State private var regenerateMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                aboutYouSection
                goalsSection
                experienceSection
                scheduleSection
                equipmentSection
                coachingStyleSection
                injuriesSection
                dietarySection
                dislikedExercisesSection

                if let saveMessage {
                    Section {
                        Text(saveMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        showRegenerateConfirm = true
                    } label: {
                        HStack {
                            if appModel.isWorkoutBusy {
                                ProgressView().padding(.trailing, 4)
                            }
                            Text("Rebuild my workout plan")
                        }
                    }
                    .disabled(appModel.isWorkoutBusy)

                    if let regenerateMessage {
                        Text(regenerateMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Overwrites your current week with a fresh plan that matches your current preferences. Coach-chat customizations will be lost.")
                }
                .alert("Rebuild plan?", isPresented: $showRegenerateConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Rebuild", role: .destructive) {
                        Task { await regenerate() }
                    }
                } message: {
                    Text("This overwrites your current weekly plan with one built from your preferences. Anything you've adjusted via the coach will be lost.")
                }
            }
            .navigationTitle("You")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if appModel.isSavingProfile {
                            ProgressView()
                        } else {
                            Text("Save").bold()
                        }
                    }
                    .disabled(appModel.isSavingProfile || draft == appModel.profile)
                }
            }
            .onAppear { draft = appModel.profile }
            .onChange(of: appModel.profile) { _, next in
                // Refresh local draft if the server pushes a newer version
                // and we have no unsaved edits.
                if !appModel.isSavingProfile, !hasLocalEdits {
                    draft = next
                }
            }
        }
    }

    private var hasLocalEdits: Bool { draft != appModel.profile }

    // MARK: - Sections

    private var aboutYouSection: some View {
        Section("About you") {
            HStack {
                Text("Age")
                Spacer()
                TextField("years", value: $draft.ageYears, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80)
            }

            Picker("Sex / gender", selection: $draft.sexOrGender) {
                Text("—").tag(UserSex?.none)
                ForEach(UserSex.allCases) { s in
                    Text(s.displayName).tag(UserSex?.some(s))
                }
            }

            if draft.sexOrGender == .selfDescribed {
                TextField("Self-described", text: Binding(
                    get: { draft.sexOrGenderSelfDescription ?? "" },
                    set: { draft.sexOrGenderSelfDescription = $0.isEmpty ? nil : $0 },
                ))
            }

            HStack {
                Text("Height (cm)")
                Spacer()
                TextField("optional", value: $draft.heightCm, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
            }

            HStack {
                Text("Weight (kg)")
                Spacer()
                TextField("optional", value: $draft.weightKg, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
            }
        }
    }

    private var goalsSection: some View {
        Section("Goals") {
            ForEach(GoalType.allCases) { goal in
                Toggle(goal.displayName, isOn: Binding(
                    get: { draft.goals.contains(goal) },
                    set: { isOn in
                        if isOn, !draft.goals.contains(goal) {
                            draft.goals.append(goal)
                        } else if !isOn {
                            draft.goals.removeAll { $0 == goal }
                        }
                    },
                ))
            }
            TextField("Anything specific? (e.g. \"squat 2x bodyweight\")",
                      text: Binding(get: { draft.goalNotes ?? "" },
                                    set: { draft.goalNotes = $0.isEmpty ? nil : $0 }),
                      axis: .vertical)
                .lineLimit(2...4)
        }
    }

    private var experienceSection: some View {
        Section("Experience") {
            Picker("Training experience", selection: $draft.trainingExperience) {
                Text("—").tag(TrainingExperience?.none)
                ForEach(TrainingExperience.allCases) { e in
                    Text(e.displayName).tag(TrainingExperience?.some(e))
                }
            }
        }
    }

    private var scheduleSection: some View {
        Section("Schedule") {
            Stepper(value: Binding(
                get: { draft.schedule.daysPerWeek ?? 3 },
                set: { draft.schedule.daysPerWeek = $0 },
            ), in: 1...7) {
                HStack {
                    Text("Days per week")
                    Spacer()
                    Text("\(draft.schedule.daysPerWeek ?? 3)")
                        .foregroundStyle(.secondary)
                }
            }

            Stepper(value: Binding(
                get: { draft.schedule.sessionLengthMin ?? 45 },
                set: { draft.schedule.sessionLengthMin = $0 },
            ), in: 15...180, step: 15) {
                HStack {
                    Text("Session length")
                    Spacer()
                    Text("\(draft.schedule.sessionLengthMin ?? 45) min")
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Preferred time", selection: $draft.preferences.preferredWorkoutTime) {
                ForEach(PreferredWorkoutTime.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }
        }
    }

    private var equipmentSection: some View {
        Section {
            tagList($draft.equipment)
            HStack {
                TextField("Add equipment (e.g. \"barbell\")", text: $newEquipment)
                Button("Add") {
                    addTag($newEquipment, to: \.equipment)
                }
                .disabled(newEquipment.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: { Text("Equipment / gear") }
          footer: { Text("What you have access to. Helps MYO pick exercises you can actually do.") }
    }

    private var coachingStyleSection: some View {
        Section("Coaching style") {
            Picker("Tone", selection: $draft.preferences.coachingTone) {
                ForEach(CoachingTone.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }
            Picker("Methodology", selection: $draft.preferences.trainingFocus) {
                ForEach(TrainingFocus.allCases) { f in
                    Text(f.displayName).tag(f)
                }
            }
        }
    }

    private var injuriesSection: some View {
        Section {
            tagList($draft.injuriesOrLimitations)
            HStack {
                TextField("e.g. \"left knee meniscus\"", text: $newInjury)
                Button("Add") {
                    addTag($newInjury, to: \.injuriesOrLimitations)
                }
                .disabled(newInjury.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: { Text("Injuries / limitations") }
          footer: { Text("MYO avoids exercises that aggravate these.") }
    }

    private var dietarySection: some View {
        Section {
            tagList($draft.dietaryConstraints)
            HStack {
                TextField("e.g. \"vegetarian\", \"lactose-free\"", text: $newDietaryConstraint)
                Button("Add") {
                    addTag($newDietaryConstraint, to: \.dietaryConstraints)
                }
                .disabled(newDietaryConstraint.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: { Text("Dietary") }
    }

    private var dislikedExercisesSection: some View {
        Section {
            tagList($draft.preferences.dislikedExercises)
            HStack {
                TextField("e.g. \"burpees\", \"deadlifts\"", text: $newDislikedExercise)
                Button("Add") {
                    let next = newDislikedExercise.trimmingCharacters(in: .whitespaces)
                    if !next.isEmpty {
                        draft.preferences.dislikedExercises.append(next)
                        newDislikedExercise = ""
                    }
                }
                .disabled(newDislikedExercise.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: { Text("Disliked exercises") }
          footer: { Text("MYO will try to avoid these unless you opt in.") }
    }

    // MARK: - Helpers

    /// A simple in-place tag list — each item shows as a row with a delete
    /// button. Done as a reusable helper for the four free-text tag fields.
    private func tagList(_ binding: Binding<[String]>) -> some View {
        ForEach(Array(binding.wrappedValue.enumerated()), id: \.offset) { idx, item in
            HStack {
                Text(item)
                Spacer()
                Button(role: .destructive) {
                    binding.wrappedValue.remove(at: idx)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func addTag(_ field: Binding<String>, to keyPath: WritableKeyPath<UserProfile, [String]>) {
        let next = field.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard !next.isEmpty else { return }
        draft[keyPath: keyPath].append(next)
        field.wrappedValue = ""
    }

    private func save() async {
        saveMessage = nil
        await appModel.upsertProfile(draft)
        if appModel.errorMessage == nil {
            saveMessage = "Saved."
        }
    }

    private func regenerate() async {
        regenerateMessage = nil
        await appModel.regenerateWorkoutPlan()
        if appModel.errorMessage == nil {
            regenerateMessage = "Plan rebuilt. Check the Workout tab."
        }
    }
}
