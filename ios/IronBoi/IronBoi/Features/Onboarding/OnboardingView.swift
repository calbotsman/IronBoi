import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var voiceInput = VoiceInputEngine()
    @State private var draft = ""
    @State private var showsResetConfirmation = false
    @State private var multiSelectDraft: [String: Set<String>] = [:]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
                if let proposal = appModel.pendingProgramProposal {
                    ProposalReviewCard(proposal: proposal) {
                        Task { await appModel.acceptPendingProgramProposal() }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 10)
                } else {
                    choiceStrip
                }
                composer
            }
            .background(PaperBackground())
            .navigationTitle("MYO Coach")
            .toolbar {
                Button("Reset") {
                    showsResetConfirmation = true
                }
                .font(.caption.weight(.semibold))
                .disabled(appModel.isOnboardingBusy)

                Button("Sign Out") {
                    appModel.signOut()
                }
                .font(.caption.weight(.semibold))
            }
            .confirmationDialog(
                "Start onboarding over?",
                isPresented: $showsResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset MYO data", role: .destructive) {
                    Task { await appModel.resetMyData() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears your staging profile, onboarding chat, proposals, plans, and logs for this signed-in account.")
            }
            .safeAreaInset(edge: .top) {
                progressHeader
            }
            .alert("MYO", isPresented: Binding(
                get: { appModel.errorMessage != nil || voiceInput.errorMessage != nil },
                set: {
                    if !$0 {
                        appModel.errorMessage = nil
                        voiceInput.errorMessage = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) {
                    appModel.errorMessage = nil
                    voiceInput.errorMessage = nil
                }
            } message: {
                Text(appModel.errorMessage ?? voiceInput.errorMessage ?? "")
            }
            .onChange(of: voiceInput.transcript) { _, transcript in
                guard voiceInput.isListening else { return }
                draft = transcript
            }
        }
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusLabel)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                        .textCase(.uppercase)

                    Text("Building your private MYO profile")
                        .font(.caption2)
                        .foregroundStyle(MyoTheme.Colors.ink.opacity(0.45))
                }

                Spacer()

                Text("\(completedCount)/13")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))

                Button {
                    showsResetConfirmation = true
                } label: {
                    Label("Start over", systemImage: "arrow.counterclockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appModel.isOnboardingBusy)
            }

            ProgressView(value: Double(completedCount), total: 13)
                .tint(MyoTheme.Colors.ochre)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if appModel.onboardingMessages.isEmpty {
                        CoachPromptCard(step: appModel.onboardingStep)
                            .padding(.top, 40)
                    } else {
                        ForEach(appModel.onboardingMessages) { message in
                            CoachMessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: appModel.onboardingMessages) { _, messages in
                guard let last = messages.last else { return }
                withAnimation(MyoTheme.Motion.fade) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .background(MyoTheme.Colors.cream)
        }
    }

    private var choiceStrip: some View {
        let choices = choicesForCurrentStep
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(choices) { choice in
                    Button {
                        send(choice)
                    } label: {
                        Text(choice.label)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(choiceBackground(for: choice))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(appModel.isOnboardingBusy)
                }

                if isMultiSelectStep(appModel.onboardingStep) {
                    Button {
                        sendMultiSelectDraft()
                    } label: {
                        Label("Continue", systemImage: "arrow.right")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(canContinueMultiSelect ? MyoColor.Surface.selected.color : MyoTheme.Colors.ink.opacity(0.06))
                            .foregroundStyle(canContinueMultiSelect ? MyoColor.Text.primary.color : MyoColor.Text.tertiary.color)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(appModel.isOnboardingBusy || !canContinueMultiSelect)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, choices.isEmpty ? 0 : 10)
        }
        .background(.bar)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Button {
                voiceInput.toggle()
            } label: {
                Image(systemName: voiceInput.isListening ? "mic.circle.fill" : "mic.circle")
                    .font(.system(size: 32))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(voiceInput.isListening ? MyoTheme.Colors.brick : MyoTheme.Colors.ink)
            }
            .disabled(appModel.isOnboardingBusy)
            .accessibilityLabel(voiceInput.isListening ? "Stop talk input" : "Talk to Coach")

            TextField("Continue by typing...", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(appModel.isOnboardingBusy)

            Button {
                sendDraft()
            } label: {
                Image(systemName: appModel.isOnboardingBusy ? "hourglass" : "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.hierarchical)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appModel.isOnboardingBusy)
            .accessibilityLabel("Send onboarding answer")
        }
        .padding()
        .background(.bar)
    }

    private var completedCount: Int {
        max(0, 13 - appModel.onboardingMissingFields.count)
    }

    private var statusLabel: String {
        switch appModel.onboardingStatus {
        case .proposalReady:
            return "Review plan"
        case .complete:
            return "Complete"
        case .notStarted, .collecting:
            return "Onboarding"
        }
    }

    private var choicesForCurrentStep: [OnboardingChoice] {
        switch appModel.onboardingStep {
        case "goals":
            return [
                choice("muscle_gain", "Build muscle", "goals", ["muscle_gain"]),
                choice("fat_loss", "Lose fat", "goals", ["fat_loss"]),
                choice("strength", "Get stronger", "goals", ["strength"]),
                choice("general_fitness", "General fitness", "goals", ["general_fitness"]),
            ]
        case "sexOrGender":
            return [
                choice("male", "Male", "sexOrGender", "male"),
                choice("female", "Female", "sexOrGender", "female"),
                choice("non_binary", "Non-binary", "sexOrGender", "non_binary"),
                choice("prefer_not", "Prefer not", "sexOrGender", "prefer_not_to_say"),
            ]
        case "trainingExperience":
            return [
                choice("new", "New", "trainingExperience", "new"),
                choice("beginner", "Beginner", "trainingExperience", "beginner"),
                choice("intermediate", "Intermediate", "trainingExperience", "intermediate"),
                choice("advanced", "Advanced", "trainingExperience", "advanced"),
            ]
        case "equipment":
            return [
                choice("bodyweight", "Bodyweight", "equipment", ["bodyweight"]),
                choice("dumbbells", "Dumbbells", "equipment", ["dumbbells"]),
                choice("home_gym", "Home gym", "equipment", ["home gym"]),
                choice("full_gym", "Full gym", "equipment", ["full gym"]),
            ]
        case "daysPerWeek":
            return (2...6).map { choice("days_\($0)", "\($0) days", "daysPerWeek", $0) }
        case "sessionLengthMin":
            return [30, 45, 60, 75].map { choice("length_\($0)", "\($0) min", "sessionLengthMin", $0) }
        case "trainingFocus":
            return [
                choice("myo_recommended", "Coach recommended", "trainingFocus", "myo_recommended"),
                choice("muscle_split", "Muscle split", "trainingFocus", "muscle_split"),
                choice("full_body", "Full body", "trainingFocus", "full_body"),
                choice("strength_conditioning", "Strength + conditioning", "trainingFocus", "strength_conditioning"),
                choice("mobility_recovery", "Mobility/recovery", "trainingFocus", "mobility_recovery"),
            ]
        case "coachingLens":
            return [
                choice("lens_none", "MYO default", "coachingLens", "none"),
                choice("lens_huberman", "Andrew Huberman", "coachingLens", "huberman"),
                choice("lens_schoenfeld", "Brad Schoenfeld", "coachingLens", "schoenfeld"),
                choice("lens_sims", "Stacy Sims", "coachingLens", "sims"),
                choice("lens_blueprint", "Bryan Johnson", "coachingLens", "blueprint"),
            ]
        case "injuriesOrLimitations":
            return [
                choice("none", "No limitations", "injuriesOrLimitations", ["none"]),
                choice("type", "I'll type it", "injuriesOrLimitations", []),
            ]
        case "dietaryConstraints":
            return [
                choice("none", "No constraints", "dietaryConstraints", ["none"]),
                choice("high_protein", "High protein", "dietaryConstraints", ["high protein"]),
                choice("vegetarian", "Vegetarian", "dietaryConstraints", ["vegetarian"]),
                choice("no_dairy", "No dairy", "dietaryConstraints", ["no dairy"]),
            ]
        default:
            return []
        }
    }

    private func choice(_ id: String, _ label: String, _ key: String, _ value: Any) -> OnboardingChoice {
        OnboardingChoice(id: id, label: label, structuredAnswer: [key: value])
    }

    private func send(_ choice: OnboardingChoice) {
        if isMultiSelectStep(appModel.onboardingStep),
           let values = choice.structuredAnswer[appModel.onboardingStep] as? [String],
           values.isEmpty == false {
            toggleMultiSelect(values)
            return
        }

        Task {
            await appModel.sendOnboardingAnswer(
                choice.label,
                inputMode: .tap,
                structuredAnswer: choice.structuredAnswer
            )
        }
    }

    private func sendDraft() {
        let content = draft
        let mode: CoachInputMode = voiceInput.transcript == content && !content.isEmpty ? .dictation : .text
        let step = appModel.onboardingStep
        voiceInput.stop()
        draft = ""
        Task {
            if isMultiSelectStep(step) {
                let values = mergedMultiSelectValues(with: content)
                let structuredAnswer = values.isEmpty ? nil : [step: values]
                await appModel.sendOnboardingAnswer(
                    content,
                    inputMode: mode,
                    structuredAnswer: structuredAnswer
                )
                clearMultiSelectDraft(for: step)
            } else {
                await appModel.sendOnboardingAnswer(content, inputMode: mode)
            }
        }
    }

    private var canContinueMultiSelect: Bool {
        !(multiSelectDraft[appModel.onboardingStep]?.isEmpty ?? true)
    }

    private func isMultiSelectStep(_ step: String) -> Bool {
        step == "equipment" || step == "injuriesOrLimitations" || step == "dietaryConstraints"
    }

    private func choiceBackground(for choice: OnboardingChoice) -> Color {
        guard isMultiSelectStep(appModel.onboardingStep),
              let values = choice.structuredAnswer[appModel.onboardingStep] as? [String],
              let first = values.first
        else {
            return MyoTheme.Colors.cream
        }

        return multiSelectDraft[appModel.onboardingStep]?.contains(first) == true
            ? MyoTheme.Colors.ochreLight
            : MyoTheme.Colors.cream
    }

    private func toggleMultiSelect(_ values: [String]) {
        var current = multiSelectDraft[appModel.onboardingStep] ?? []
        for value in values {
            if current.contains(value) {
                current.remove(value)
            } else {
                current.insert(value)
            }
        }
        multiSelectDraft[appModel.onboardingStep] = current
    }

    private func sendMultiSelectDraft() {
        let step = appModel.onboardingStep
        let values = mergedMultiSelectValues(with: draft)
        let label = values.joined(separator: ", ")
        draft = ""
        voiceInput.stop()
        clearMultiSelectDraft(for: step)

        Task {
            await appModel.sendOnboardingAnswer(
                label,
                inputMode: .tap,
                structuredAnswer: [step: values]
            )
        }
    }

    private func mergedMultiSelectValues(with content: String) -> [String] {
        var values = Array(multiSelectDraft[appModel.onboardingStep] ?? [])
        values.append(contentsOf: Self.parseListAnswer(content))
        return Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }
            .sorted()
    }

    private func clearMultiSelectDraft(for step: String) {
        multiSelectDraft[step] = []
    }

    private static func parseListAnswer(_ content: String) -> [String] {
        content
            .replacingOccurrences(of: #"(?i)\bi also have\b|\bi have\b|\baccess to\b"#, with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .flatMap { item in
                item.components(separatedBy: " and ")
            }
            .map { item in
                item.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"(?i)^(a|an|the)\s+"#, with: "", options: .regularExpression)
            }
            .filter { !$0.isEmpty }
    }
}

private struct CoachPromptCard: View {
    let step: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(MyoTheme.Colors.ochre)

            Text("Build your MYO plan")
                .font(.title2.bold())

            Text(prompt)
                .font(.body)
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var prompt: String {
        switch step {
        case "goals":
            return "Tell Coach your goal. You can talk, type, or tap a quick answer."
        default:
            return "Answer the next question however you want. You can switch between talk, typing, and taps at any time."
        }
    }
}

private struct ProposalReviewCard: View {
    let proposal: ProgramProposalSummary
    let accept: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MYO Plan Review")
                        .font(.title3.bold())
                    Text("Review what Coach understood before this becomes your active plan.")
                        .font(.caption)
                        .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                }

                Spacer()

                Button(action: accept) {
                    Text("Accept")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MyoColor.Text.primary.color)
                }
                    .buttonStyle(.borderedProminent)
                    .tint(MyoColor.Action.primary.color)
            }

            ReviewSection(title: "What Coach understood") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ProfileFactTile(title: "Goal", value: formattedList(proposal.profile.goals))
                    ProfileFactTile(title: "Experience", value: formattedToken(proposal.profile.trainingExperience))
                    ProfileFactTile(title: "Age", value: proposal.profile.ageYears.map(String.init) ?? "Unknown")
                    ProfileFactTile(title: "Sex/Gender", value: formattedToken(proposal.profile.sexOrGender))
                    ProfileFactTile(title: "Height", value: formattedHeight(proposal.profile.heightCm))
                    ProfileFactTile(title: "Weight", value: formattedWeight(proposal.profile.weightKg))
                    ProfileFactTile(title: "Training", value: formattedSchedule)
                    ProfileFactTile(title: "Focus", value: formattedToken(proposal.profile.trainingFocus))
                    ProfileFactTile(title: "Equipment", value: formattedList(proposal.profile.equipment))
                }

                VStack(alignment: .leading, spacing: 8) {
                    ProfileFactRow(title: "Limitations", value: formattedList(proposal.profile.injuriesOrLimitations))
                    ProfileFactRow(title: "Nutrition", value: formattedList(proposal.profile.dietaryConstraints))
                }
            }

            ReviewSection(title: "Starter weekly plan") {
                Text("This is the first deterministic starter plan. Coach will tailor it as you train and log feedback.")
                    .font(.caption)
                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(proposal.workoutDays) { day in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(day.dayKey)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                            Text(day.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            Text(day.exerciseNames.prefix(3).joined(separator: "\n"))
                                .font(.caption)
                                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                                .lineLimit(4)
                        }
                        .frame(width: 150, alignment: .leading)
                        .padding(10)
                        .background(MyoTheme.Colors.cream)
                        .overlay {
                            RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous)
                                .stroke(MyoTheme.Colors.hairline, lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))
                    }
                }
            }
            }

            ReviewSection(title: "Nutrition starting point") {
                HStack(spacing: 12) {
                    MetricPill(title: "Calories", range: proposal.calories)
                    MetricPill(title: "Protein", range: proposal.proteinGrams, suffix: "g")
                }

                if !proposal.assumptions.isEmpty {
                    BulletList(title: "Assumptions", items: proposal.assumptions)
                }

                if !proposal.safetyNotes.isEmpty {
                    BulletList(title: "Safety notes", items: proposal.safetyNotes)
                }
            }

            Button {
                // Edit/regenerate needs the hardened backend endpoint with App Check/idempotency.
            } label: {
                Label("Edit Details", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(true)
            .help("Edit/regenerate is the next backend-hardened step.")
        }
        }
        .frame(maxHeight: 430)
        .padding()
        .background(MyoTheme.Colors.cream)
        .overlay {
            RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous)
                .stroke(MyoTheme.Colors.hairline, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))
    }

    private var formattedSchedule: String {
        let days = proposal.profile.daysPerWeek.map { "\($0)d/wk" } ?? "Unknown"
        let length = proposal.profile.sessionLengthMin.map { "\($0)m" } ?? "Unknown"
        return "\(days) · \(length)"
    }

    private func formattedList(_ values: [String]) -> String {
        let cleaned = values.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "None" }
        return cleaned.map(formattedToken).joined(separator: ", ")
    }

    private func formattedToken(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Unknown" }
        return value
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private func formattedHeight(_ heightCm: Double?) -> String {
        guard let heightCm else { return "Unknown" }
        let totalInches = Int((heightCm / 2.54).rounded())
        return "\(totalInches / 12)'\(totalInches % 12)\""
    }

    private func formattedWeight(_ weightKg: Double?) -> String {
        guard let weightKg else { return "Unknown" }
        return "\(Int((weightKg * 2.20462).rounded())) lb"
    }
}

private struct ReviewSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(MyoTheme.Typography.monoLabel)
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                .textCase(.uppercase)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(MyoTheme.Colors.cream)
        .overlay {
            RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous)
                .stroke(MyoTheme.Colors.hairline, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))
    }
}

private struct ProfileFactTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(10)
        .background(MyoTheme.Colors.cream)
        .overlay {
            RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous)
                .stroke(MyoTheme.Colors.hairline, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))
    }
}

private struct ProfileFactRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct BulletList: View {
    let title: String
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                    Text(item)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
            }
        }
    }
}

private struct MetricPill: View {
    let title: String
    let range: RangeSummary?
    var suffix = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
            Text(rangeText)
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(MyoTheme.Colors.cream)
        .overlay {
            RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous)
                .stroke(MyoTheme.Colors.hairline, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))
    }

    private var rangeText: String {
        guard let range else { return "Held" }
        return "\(range.min)-\(range.max)\(suffix)"
    }
}

#Preview {
    OnboardingView()
        .environmentObject(AppModel())
}
