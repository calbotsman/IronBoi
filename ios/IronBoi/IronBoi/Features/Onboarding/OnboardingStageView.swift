import SwiftUI

/// Onboarding on the coach's own stage: the same body, the same tap-to-talk
/// and type-to-talk as home. The coach asks six things out loud; each answer
/// is a card you tap (or say, or type), and drops into a small "your plan"
/// stack at the top, so it feels like building something rather than filling
/// in a form. The last answer turns the stack into your week.
///
/// The server is the source of truth for which answers it has
/// (onboardingMissingFields); taps advance straight away and are sent in
/// order behind the scenes, so the next question never waits on the network.
struct OnboardingStageView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var voiceInput = VoiceInputEngine()
    @StateObject private var voice = CoachVoice()
    @StateObject private var director = BodyDirector()
    @AppStorage("coachSpeaksReplies") private var speaksReplies = true

    /// The question on screen (index into `Step.all`; `Step.all.count` = your week).
    @State private var stepIndex = 0
    /// What each answer looks like in the plan stack, by field.
    @State private var chips: [String: String] = [:]
    /// Answers on their way to the server, in order.
    @State private var sendQueue: Task<Void, Never>?
    @State private var inFlight = 0
    /// A spoken or typed answer: wait for the server to read it before moving on.
    @State private var awaitingParse: String?
    /// Going back to change one answer from the stack.
    @State private var editing = false
    @State private var showKeyboard = false
    @State private var notice: String?
    @State private var lastSpokenStep: Int?
    @State private var showMenu = false
    @State private var stageSize: CGSize = .zero
    /// Where things are on screen, so the body can share the space: the
    /// bottom of the header (dots + plan stack), the top of the question,
    /// and each chip in the stack.
    @State private var frames: [String: CGRect] = [:]
    /// The chip that landed most recently — the body looks at it.
    @State private var lastChipField: String?
    // The schedule card's own state.
    @State private var days: Set<String> = ["Mon", "Wed", "Fri"]
    @State private var time = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()

    private var isWeek: Bool { stepIndex >= Step.all.count }
    private var step: Step? { isWeek ? nil : Step.all[stepIndex] }

    private var phase: OrbPhase {
        if voice.isSpeaking { return .speaking }
        if voiceInput.isListening { return .listening }
        if awaitingParse != nil || (isWeek && appModel.pendingProgramProposal == nil) || appModel.isOnboardingBusy && isWeek {
            return .thinking
        }
        return .rest
    }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                let origin = geo.frame(in: .named(Self.space)).origin
                let room = bodyRoom(in: geo.size)
                OrbView(
                    phase: phase,
                    you: voiceInput.meter,
                    agent: voice.meter,
                    focus: CGPoint(x: geo.size.width / 2, y: room.center - origin.y),
                    director: director,
                    scale: room.scale,
                    ambient: true,
                    youTalking: !voiceInput.transcript.isEmpty,
                    ceiling: frames["header"].map { $0.maxY - origin.y },
                    gaze: lastChipField.flatMap { frames["chip.\($0)"] }
                        .map { CGPoint(x: $0.midX - origin.x, y: $0.midY - origin.y) },
                    nudge: chips.count
                )
                .onAppear { stageSize = geo.size }
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .background { measure("header") }
                Spacer(minLength: 0)
                caption
                    .background { measure("caption") }
                    .padding(.horizontal, MyoTheme.Spacing.lg)
                    .padding(.bottom, MyoTheme.Spacing.md)
                card
                    .padding(.horizontal, MyoTheme.Spacing.md)
                    .id(stepIndex)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)))
                controls
                    .padding(.horizontal, MyoTheme.Spacing.lg)
                    .padding(.top, MyoTheme.Spacing.md)
                    .padding(.bottom, MyoTheme.Spacing.sm)
                    .opacity(showKeyboard ? 0 : 1)
                    .allowsHitTesting(!showKeyboard)
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(StageFramesKey.self) { frames = $0 }
        .background(PaperBackground())
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: stepIndex)
        .animation(MyoTheme.Motion.fade, value: chips)
        .safeAreaInset(edge: .bottom) {
            if showKeyboard {
                TypeBar(isPresented: $showKeyboard, onSend: { answerInWords($0, mode: .text) })
                    .padding(.horizontal, MyoTheme.Spacing.md)
                    .padding(.bottom, MyoTheme.Spacing.sm)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: showKeyboard)
        .confirmationDialog("Onboarding", isPresented: $showMenu, titleVisibility: .hidden) {
            Button("Start over", role: .destructive) {
                chips = [:]
                Task { await appModel.resetMyData() }
            }
            Button("Sign out") { appModel.signOut() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("MYO", isPresented: Binding(
            get: { appModel.errorMessage != nil || voiceInput.errorMessage != nil },
            set: { if !$0 { appModel.errorMessage = nil; voiceInput.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { appModel.errorMessage = nil; voiceInput.errorMessage = nil }
        } message: {
            Text(appModel.errorMessage ?? voiceInput.errorMessage ?? "")
        }
        .onAppear {
            voice.fetchAudio = { [appModel] text in try await appModel.synthesizeSpeech(text) }
            voiceInput.onPause = { text in
                voiceInput.release()
                answerInWords(text, mode: .dictation)
            }
            voiceInput.onFailure = { voiceInput.release() }
            restoreFromServer()
            askCurrentQuestion()
        }
        .onDisappear {
            voice.stop()
            voiceInput.release()
        }
        .onChange(of: appModel.onboardingMissingFields) { _, _ in serverMoved() }
        .onChange(of: appModel.onboardingStatus) { _, _ in serverMoved() }
        .onChange(of: appModel.pendingProgramProposal?.proposalId) { _, id in
            if id != nil, isWeek { askCurrentQuestion() }
        }
        // After an answer the body reacts first — ducks under the new chip,
        // looks up, points at it — then the coach asks the next one. (Talking
        // turns it back into the blob, which would hide all of that.)
        .onChange(of: stepIndex) { _, step in
            Task {
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                if stepIndex == step { askCurrentQuestion() }
            }
        }
    }

    // MARK: - Header: progress dots and the plan stack

    private var header: some View {
        VStack(spacing: MyoTheme.Spacing.sm) {
            HStack(spacing: 6) {
                ForEach(Step.all.indices, id: \.self) { index in
                    Capsule()
                        .fill(index < answeredCount ? MyoTheme.Colors.coachAmber : MyoColor.hairline)
                        .frame(width: index == stepIndex ? 22 : 8, height: 8)
                }
                Spacer()
                Button { showMenu = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(MyoColor.Text.secondary.color)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More")
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: stepIndex)

            if !chips.isEmpty {
                // Your plan, taking shape. Tap one to change it.
                FlowRow(spacing: 6) {
                    ForEach(Step.all.indices.filter { chips[Step.all[$0].field] != nil }, id: \.self) { index in
                        Button { change(index) } label: {
                            Text(chips[Step.all[index].field] ?? "")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(MyoColor.Text.primary.color)
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .myoGlass(tint: index == stepIndex ? MyoTheme.Colors.coachAmber.opacity(0.35) : nil)
                        }
                        .buttonStyle(.plain)
                        .background { measure("chip.\(Step.all[index].field)") }
                        .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, MyoTheme.Spacing.md)
        .padding(.top, MyoTheme.Spacing.sm)
    }

    private var answeredCount: Int {
        Step.all.filter { chips[$0.field] != nil }.count
    }

    // MARK: - Caption: the question, or what you said

    @ViewBuilder
    private var caption: some View {
        VStack(spacing: MyoTheme.Spacing.sm) {
            Text(statusLabel)
                .myoStyle(.label)
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(phase == .listening ? MyoColor.redPen : MyoColor.Text.tertiary.color)
            Text(captionText)
                .myoStyle(.title)
                .foregroundStyle(MyoColor.Text.primary.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity)
    }

    private var statusLabel: String {
        switch phase {
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Coach"
        case .rest: return isWeek ? "Your first week" : "\(stepIndex + 1) of \(Step.all.count)"
        }
    }

    private var captionText: String {
        if voiceInput.isListening { return voiceInput.transcript.isEmpty ? " " : voiceInput.transcript }
        if let notice { return notice }
        if isWeek {
            return appModel.pendingProgramProposal == nil ? "Putting your week together…" : "Here's your week."
        }
        return step?.question ?? ""
    }

    // MARK: - The card under the coach

    @ViewBuilder
    private var card: some View {
        if isWeek {
            if let proposal = appModel.pendingProgramProposal {
                WeekCard(proposal: proposal, busy: appModel.isOnboardingBusy || inFlight > 0) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    Task { await appModel.acceptPendingProgramProposal() }
                }
            } else {
                Color.clear.frame(height: 120)
            }
        } else if let step {
            switch step.kind {
            case .choices(let options):
                ChoicesCard(options: options, selected: chips[step.field]) { option in
                    answer(option.answer, chip: option.chip, content: option.label)
                } onTalk: { prompt in
                    notice = prompt
                    showKeyboard = true
                }
            case .schedule:
                ScheduleCard(days: $days, time: $time) {
                    let ordered = ScheduleCard.week.filter { days.contains($0) }
                    TrainingReminders.shared.setPreferredTime(time)
                    let clock = time.formatted(date: .omitted, time: .shortened)
                    answer(
                        ["preferredDays": ordered, "preferredTime": Self.clock(time)],
                        chip: "\(ordered.joined(separator: " ")) · \(clock)",
                        content: "\(ordered.joined(separator: ", ")) at \(clock)"
                    )
                }
            }
        }
    }

    // MARK: - Controls: the same two buttons as home

    private var controls: some View {
        HStack(spacing: MyoTheme.Spacing.sm) {
            roundButton(systemImage: "keyboard", label: "Type instead", active: false) {
                voiceInput.release()
                showKeyboard = true
            }
            roundButton(systemImage: voiceInput.isListening ? "mic.fill" : "mic.slash",
                        label: voiceInput.isListening ? "Stop listening" : "Talk",
                        active: voiceInput.isListening) {
                talkTapped()
            }
            Spacer()
        }
    }

    private func roundButton(systemImage: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(active ? MyoTheme.Colors.ink : MyoColor.Text.secondary.color)
                .symbolEffect(.pulse, isActive: active)
                .frame(width: 52, height: 52)
                .contentShape(Circle())
                .myoGlass(tint: active ? MyoTheme.Colors.coachAmber.opacity(0.45) : nil, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Answering

    /// A tap: in the stack and on to the next question at once; sent behind.
    private func answer(_ structured: [String: Any], chip: String, content: String) {
        guard let step else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        voice.stop()
        notice = nil
        chips[step.field] = chip
        lastChipField = step.field
        enqueue(content, structured: structured, mode: .tap)
        advance()
    }

    /// Said or typed: the server reads it, and the question moves on only if
    /// it understood.
    private func answerInWords(_ text: String, mode: CoachInputMode) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let step else { return }
        voice.stop()
        notice = nil
        awaitingParse = step.field
        let field = step.field
        enqueue(trimmed, structured: nil, mode: mode) {
            awaitingParse = nil
            if appModel.onboardingMissingFields.contains(field) && appModel.onboardingStatus != .proposalReady {
                notice = "Sorry, I didn't catch that. Tap a card, or say it another way."
                lastSpokenStep = nil
                speak(notice ?? "")
            } else {
                chips[field] = Self.shortChip(trimmed)
                lastChipField = field
                advance()
            }
        }
    }

    private func enqueue(_ content: String, structured: [String: Any]?, mode: CoachInputMode, then: (@MainActor () -> Void)? = nil) {
        inFlight += 1
        let previous = sendQueue
        sendQueue = Task { @MainActor in
            await previous?.value
            await appModel.sendOnboardingAnswer(content, inputMode: mode, structuredAnswer: structured)
            inFlight -= 1
            then?()
        }
    }

    /// The next question you haven't answered, or your week.
    private func advance() {
        editing = false
        let next = Step.all.indices.first { $0 > stepIndex && chips[Step.all[$0].field] == nil }
            ?? Step.all.indices.first { chips[Step.all[$0].field] == nil }
        stepIndex = next ?? Step.all.count
    }

    /// Tap a chip in the stack: back to that question.
    private func change(_ index: Int) {
        guard index != stepIndex else { return }
        voice.stop()
        notice = nil
        editing = true
        stepIndex = index
    }

    private func talkTapped() {
        if voiceInput.isListening {
            voiceInput.release()
            return
        }
        voice.stop()
        showKeyboard = false
        voiceInput.toggle()
    }

    // MARK: - Keeping in step with the server

    /// Fill the stack from what the server already has (an onboarding
    /// started earlier, or on another device) and pick up where it left off.
    private func restoreFromServer() {
        let draft = appModel.onboardingDraft
        for step in Step.all where chips[step.field] == nil {
            if let label = step.chip(for: draft[step.field], draft: draft) { chips[step.field] = label }
        }
        if let days = draft["preferredDays"] as? [String], !days.isEmpty { self.days = Set(days) }
        syncStep()
    }

    private func serverMoved() {
        guard inFlight == 0, awaitingParse == nil, !editing else { return }
        restoreFromServer()
    }

    private func syncStep() {
        if appModel.onboardingStatus == .proposalReady && Step.all.allSatisfy({ chips[$0.field] != nil }) {
            stepIndex = Step.all.count
            return
        }
        let missing = appModel.onboardingMissingFields.first ?? appModel.onboardingStep
        if let index = Step.all.firstIndex(where: { $0.field == missing }) { stepIndex = index }
    }

    // MARK: - The coach's voice

    private func askCurrentQuestion() {
        guard lastSpokenStep != stepIndex else { return }
        if isWeek {
            guard let proposal = appModel.pendingProgramProposal else { return }
            lastSpokenStep = stepIndex
            let days = proposal.workoutDays.filter { !$0.exerciseNames.isEmpty }.map { Self.dayName($0.dayKey) }
            speak("Here's your week: \(Self.list(days)). Tap Start with this, or tap any answer up top to change it.")
            return
        }
        guard let step else { return }
        lastSpokenStep = stepIndex
        let intro = stepIndex == 0 && chips.isEmpty
            ? "Hi, I'm your coach. Six quick questions and I'll build your first week. "
            : ""
        speak(intro + step.question)
    }

    private func speak(_ text: String) {
        guard speaksReplies, !text.isEmpty, !voiceInput.isListening else { return }
        voice.speak(text, messageId: "onboarding-\(UUID().uuidString)")
    }

    // MARK: - Sharing the screen

    private static let space = "onboardingStage"

    private func measure(_ key: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: StageFramesKey.self, value: [key: proxy.frame(in: .named(Self.space))])
        }
    }

    /// The free space between the plan stack and the question: the body
    /// stands in it, feet just above the question, and shrinks as the stack
    /// grows so it always fits underneath.
    private func bodyRoom(in size: CGSize) -> (center: CGFloat, scale: CGFloat) {
        let top = frames["header"]?.maxY ?? size.height * 0.12
        let bottom = frames["caption"]?.minY ?? size.height * 0.5
        let room = max(bottom - top, 120)
        // A standing figure is about 300 pt tall at scale 1 on this screen.
        let scale = min(isWeek ? 0.6 : 0.85, max(0.38, (room - 24) / 300))
        // Feet sit ~124 pt below the body's centre at scale 1.
        let center = bottom - 12 - 124 * scale
        return (center, scale)
    }

    // MARK: - Helpers

    private static func clock(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 18, parts.minute ?? 0)
    }

    private static func shortChip(_ text: String) -> String {
        text.count <= 28 ? text : String(text.prefix(26)) + "…"
    }

    private static func dayName(_ key: String) -> String {
        ["Mon": "Monday", "Tue": "Tuesday", "Wed": "Wednesday", "Thu": "Thursday",
         "Fri": "Friday", "Sat": "Saturday", "Sun": "Sunday"][key] ?? key
    }

    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}

// MARK: - The six questions

private struct Step {
    struct Option: Identifiable {
        var id: String { label }
        let label: String
        /// What it looks like in the plan stack.
        let chip: String
        let answer: [String: Any]
        /// Tapping it asks for words instead (e.g. "Something hurts").
        var asksForWords: String? = nil
    }

    enum Kind {
        case choices([Option])
        case schedule
    }

    let field: String
    let question: String
    let kind: Kind

    /// The stack label for an answer the server already has.
    func chip(for value: Any?, draft: [String: Any]) -> String? {
        guard let value else { return nil }
        switch kind {
        case .schedule:
            guard let days = value as? [String], !days.isEmpty else { return nil }
            let time = (draft["preferredTime"] as? String).map { " · \($0)" } ?? ""
            return days.joined(separator: " ") + time
        case .choices(let options):
            if let match = options.first(where: { option in
                option.answer[field].map(Self.normalized) == Self.normalized(value)
            }) { return match.chip }
            // The server keeps a number for age: show the band it falls in.
            if field == "ageYears", let age = value as? Int {
                return age < 18 ? "Under 18" : age < 40 ? "18–39" : age < 60 ? "40–59" : "60+"
            }
            if let list = value as? [Any] {
                return list.isEmpty ? nil : list.map { "\($0)" }.joined(separator: ", ")
            }
            return "\(value)"
        }
    }

    /// Arrays and scalars compared as plain text (Firestore hands back NSArrays).
    private static func normalized(_ value: Any) -> String {
        if let list = value as? [Any] { return list.map { "\($0)" }.joined(separator: ",") }
        return "\(value)"
    }

    static let all: [Step] = [
        Step(field: "goals", question: "What do you want from training right now?", kind: .choices([
            Option(label: "Build muscle", chip: "Build muscle", answer: ["goals": ["muscle_gain"]]),
            Option(label: "Lose fat", chip: "Lose fat", answer: ["goals": ["fat_loss"]]),
            Option(label: "Get stronger", chip: "Get stronger", answer: ["goals": ["strength"]]),
            Option(label: "Feel fitter", chip: "Feel fitter", answer: ["goals": ["general_fitness"]]),
            Option(label: "Get back into it", chip: "Getting back into it", answer: ["goals": ["return_to_training"]]),
        ])),
        Step(field: "trainingExperience", question: "How much have you trained before?", kind: .choices([
            Option(label: "Never really", chip: "New to this", answer: ["trainingExperience": "new"]),
            Option(label: "A little", chip: "A little training", answer: ["trainingExperience": "beginner"]),
            Option(label: "On and off for years", chip: "Trained before", answer: ["trainingExperience": "intermediate"]),
            Option(label: "Seriously, for years", chip: "Experienced", answer: ["trainingExperience": "advanced"]),
        ])),
        Step(field: "equipment", question: "Where will you train?", kind: .choices([
            Option(label: "A full gym", chip: "Full gym", answer: ["equipment": ["full gym"]]),
            Option(label: "Home, with dumbbells", chip: "Home · dumbbells", answer: ["equipment": ["dumbbells", "bench"]]),
            Option(label: "A home gym with a barbell", chip: "Home gym", answer: ["equipment": ["home gym"]]),
            Option(label: "Bodyweight only", chip: "Bodyweight", answer: ["equipment": ["bodyweight"]]),
        ])),
        Step(field: "ageYears", question: "Roughly how old are you?", kind: .choices([
            Option(label: "Under 18", chip: "Under 18", answer: ["ageYears": 16]),
            Option(label: "18–39", chip: "18–39", answer: ["ageYears": "18–39"]),
            Option(label: "40–59", chip: "40–59", answer: ["ageYears": "40–59"]),
            Option(label: "60+", chip: "60+", answer: ["ageYears": "60+"]),
        ])),
        Step(field: "preferredDays", question: "Which days work, and what time?", kind: .schedule),
        Step(field: "injuriesOrLimitations",
             question: "Last one. Does anything hurt, or has a doctor told you to limit exercise?",
             kind: .choices([
                Option(label: "All good", chip: "No limits", answer: ["injuriesOrLimitations": ["none"]]),
                Option(label: "Something hurts", chip: "Something hurts", answer: [:],
                       asksForWords: "Tell me where, and what makes it worse."),
                Option(label: "A doctor's limit, or chest pain, dizziness or fainting when active",
                       chip: "Doctor's limit", answer: ["injuriesOrLimitations": ["doctor advised limit"]]),
             ])),
    ]
}

// MARK: - Cards

/// One question's answers: big tap targets, one per line.
private struct ChoicesCard: View {
    let options: [Step.Option]
    let selected: String?
    let onPick: (Step.Option) -> Void
    let onTalk: (String) -> Void

    var body: some View {
        VStack(spacing: MyoTheme.Spacing.sm) {
            ForEach(options) { option in
                Button {
                    if let prompt = option.asksForWords { onTalk(prompt) } else { onPick(option) }
                } label: {
                    HStack {
                        Text(option.label)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(MyoColor.Text.primary.color)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if selected == option.chip {
                            Image(systemName: "checkmark")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(MyoTheme.Colors.coachAmber)
                        }
                    }
                    .padding(.horizontal, MyoTheme.Spacing.lg)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: 26))
                    .myoGlass(tint: selected == option.chip ? MyoTheme.Colors.coachAmber.opacity(0.3) : nil,
                              in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Which days, and what time: the cue a habit hangs on.
private struct ScheduleCard: View {
    static let week = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    @Binding var days: Set<String>
    @Binding var time: Date
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
            HStack(spacing: 6) {
                ForEach(Self.week, id: \.self) { day in
                    let on = days.contains(day)
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if on { days.remove(day) } else { days.insert(day) }
                    } label: {
                        Text(String(day.prefix(1)))
                            .font(.body.weight(.bold))
                            .foregroundStyle(on ? MyoTheme.Colors.ink : MyoColor.Text.secondary.color)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Circle())
                            .myoGlass(tint: on ? MyoTheme.Colors.coachAmber.opacity(0.5) : nil, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(day)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            HStack {
                Text(days.count == 1 ? "1 day a week, at" : "\(days.count) days a week, at")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MyoColor.Text.secondary.color)
                Spacer()
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            Button(action: onDone) {
                Text("That works")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MyoTheme.Colors.ink)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Capsule())
                    .myoGlass(tint: MyoTheme.Colors.coachAmber.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(days.isEmpty)
            .opacity(days.isEmpty ? 0.5 : 1)
        }
        .padding(MyoTheme.Spacing.lg)
        .myoCard()
    }
}

/// Your week, built from the answers. One button.
private struct WeekCard: View {
    let proposal: ProgramProposalSummary
    let busy: Bool
    let onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 0) {
                let training = proposal.workoutDays.filter { !$0.exerciseNames.isEmpty }
                ForEach(Array(training.enumerated()), id: \.element.id) { index, day in
                    if index > 0 { MyoHairline() }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(day.dayKey.uppercased())
                                .myoStyle(.label)
                                .foregroundStyle(MyoColor.redPen)
                                .frame(width: 44, alignment: .leading)
                            Text(day.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(MyoColor.Text.primary.color)
                        }
                        Text(day.exerciseNames.prefix(3).joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(MyoColor.Text.secondary.color)
                            .lineLimit(1)
                            .padding(.leading, 44)
                    }
                    .padding(.vertical, 10)
                }
            }
            Button(action: onAccept) {
                HStack(spacing: MyoTheme.Spacing.sm) {
                    if busy { ProgressView().tint(MyoTheme.Colors.ink) }
                    Text("Start with this").font(.body.weight(.semibold))
                }
                .foregroundStyle(MyoTheme.Colors.ink)
                .frame(maxWidth: .infinity, minHeight: 54)
                .contentShape(Capsule())
                .myoGlass(tint: MyoTheme.Colors.coachAmber.opacity(0.45))
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
        .padding(MyoTheme.Spacing.lg)
        .myoCard()
    }
}

/// Chips that wrap onto new lines.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Frames of the onboarding stage's parts, by name.
private struct StageFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
