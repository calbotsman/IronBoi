import SwiftUI

/// Onboarding on the coach's own stage: the same body, the same tap-to-talk
/// and type-to-talk as home. The coach asks six things out loud; each answer
/// is a card you tap (or say, or type), and lights a dot in the one-line
/// "your plan" header (tap it to see and change answers), so it feels like
/// building something rather than filling in a form. The last answer turns
/// it into your week.
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
    /// What each answer looks like in your plan, by field.
    @State private var chips: [String: String] = [:]
    /// Answers on their way to the server, in order.
    @State private var sendQueue: Task<Void, Never>?
    @State private var inFlight = 0
    /// A spoken or typed answer: wait for the server to read it before moving on.
    @State private var awaitingParse: String?
    /// Going back to change one answer from your plan.
    @State private var editing = false
    @State private var showKeyboard = false
    @State private var notice: String?
    @State private var lastSpokenStep: Int?
    @State private var showMenu = false
    /// The answers list, opened from the header line.
    @State private var planOpen = false
    @State private var stageSize: CGSize = .zero
    /// Where things are on screen, so the body can share the space: the
    /// bottom of the header, the top of the question, and the plan line.
    @State private var frames: [String: CGRect] = [:]
    /// The answer that landed most recently — shown in the header line, and
    /// the body looks up at it.
    @State private var lastChipField: String?
    // The schedule card's own state.
    @State private var days: Set<String> = ["Mon", "Wed", "Fri"]
    @State private var gear: Set<String> = []
    @State private var about = AboutYou()
    @AppStorage(CoachColor.storageKey) private var coachHex = CoachColor.defaultHex
    @AppStorage(CoachingStyle.toneKey) private var toneSetting = CoachingStyle.Tone.hype.rawValue
    @AppStorage(CoachingStyle.tipsKey) private var tipsSetting = CoachingStyle.Tips.full.rawValue
    @AppStorage("onboarding.customized") private var customized = false
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
                    gaze: lastChipField.flatMap { _ in frames["plan"] }
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

            if planOpen {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { planOpen = false }
                VStack(spacing: 0) {
                    planPanel
                        .padding(.top, (frames["plan"]?.maxY ?? 52) + 6)
                    Spacer(minLength: 0)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(StageFramesKey.self) { frames = $0 }
        .background(PaperBackground())
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: stepIndex)
        .animation(MyoTheme.Motion.fade, value: chips)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: planOpen)
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
            // Answers here are lists and descriptions: don't cut them off.
            voiceInput.extraPause = 1_200_000_000
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

    // MARK: - Header: one line of progress; tap it to see and change answers

    private var header: some View {
        HStack(spacing: MyoTheme.Spacing.sm) {
            Button {
                guard !chips.isEmpty else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                planOpen.toggle()
            } label: {
                HStack(spacing: 10) {
                    HStack(spacing: 5) {
                        ForEach(Step.all.indices, id: \.self) { index in
                            Capsule()
                                .fill(chips[Step.all[index].field] != nil ? MyoTheme.Colors.coachAmber : MyoColor.hairline)
                                .frame(width: index == stepIndex ? 18 : 7, height: 7)
                        }
                    }
                    if let latest = latestChip {
                        Text(latest)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(MyoColor.Text.secondary.color)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(MyoColor.Text.tertiary.color)
                            .rotationEffect(.degrees(planOpen ? 180 : 0))
                    }
                }
                .padding(.horizontal, chips.isEmpty ? 0 : 14)
                .frame(height: 36)
                .contentShape(Capsule())
                .modifier(PlanPill(on: !chips.isEmpty))
            }
            .buttonStyle(.plain)
            .background { measure("plan") }
            .accessibilityLabel("Your answers, \(answeredCount) of \(Step.all.count)")
            .accessibilityHint(chips.isEmpty ? "" : "Shows your answers. Tap one to change it.")
            Spacer(minLength: 0)
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
        .padding(.horizontal, MyoTheme.Spacing.md)
        .padding(.top, MyoTheme.Spacing.sm)
    }

    /// Your answers, opened from the header line. Tap one to go back to it.
    private var planPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tap an answer to change it")
                .myoStyle(.label)
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(MyoColor.Text.tertiary.color)
                .padding(.horizontal, MyoTheme.Spacing.md)
                .padding(.top, 14)
                .padding(.bottom, 6)
            ForEach(Step.all.indices.filter { chips[Step.all[$0].field] != nil }, id: \.self) { index in
                Button {
                    planOpen = false
                    change(index)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: MyoTheme.Spacing.sm) {
                        Text(Step.all[index].short.uppercased())
                            .font(.system(.caption2, design: .monospaced).weight(.medium))
                            .foregroundStyle(MyoColor.redPen)
                            .frame(width: 78, alignment: .leading)
                        Text(chips[Step.all[index].field] ?? "")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MyoColor.Text.primary.color)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: index == stepIndex ? "pencil" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(MyoColor.Text.tertiary.color)
                    }
                    .padding(.horizontal, MyoTheme.Spacing.md)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 6)
        .myoCard()
        .padding(.horizontal, MyoTheme.Spacing.md)
    }

    /// The answer that landed most recently, for the header line.
    private var latestChip: String? {
        if let field = lastChipField, let chip = chips[field] { return chip }
        return Step.all.last { chips[$0.field] != nil }.flatMap { chips[$0.field] }
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
            case .gear:
                GearCard(selected: $gear) {
                    let list = GearCard.options.filter { gear.contains($0.key) }
                    answer(["equipment": list.map(\.key)], chip: list.map(\.label).joined(separator: " · "),
                           content: list.map(\.label).joined(separator: ", "))
                }
            case .aboutYou:
                AboutYouCard(about: $about) {
                    answer(about.answer, chip: about.chip, content: about.chip)
                }
            case .customize:
                CustomizeCard(coachHex: $coachHex, tone: $toneSetting, tips: $tipsSetting) {
                    customized = true
                    chips[step.field] = "Your coach"
                    lastChipField = step.field
                    advance()
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

    /// A tap: into your plan and on to the next question at once; sent behind.
    private func answer(_ structured: [String: Any], chip: String, content: String) {
        guard let step else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        voice.stop()
        notice = nil
        chips[step.field] = chip
        lastChipField = step.field
        if !structured.isEmpty { enqueue(content, structured: structured, mode: .tap) }
        advance()
    }

    /// Said or typed: the server reads it, and the question moves on only if
    /// it understood.
    private func answerInWords(_ text: String, mode: CoachInputMode) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let step else { return }
        if case .customize = step.kind {
            notice = "Tap a color and a style below."
            return
        }
        voice.stop()
        notice = nil
        awaitingParse = step.field
        let field = step.field
        enqueue(trimmed, structured: nil, mode: mode) {
            awaitingParse = nil
            let stillMissing = step.fields.contains { appModel.onboardingMissingFields.contains($0) }
            if case .aboutYou = step.kind, stillMissing, !appModel.onboardingMissingFields.contains("ageYears") {
                // Some of it landed: fill the card with what was heard.
                about.adopt(appModel.onboardingDraft)
                notice = "Got some of that. Fill in the rest below."
            } else if stillMissing && appModel.onboardingStatus != .proposalReady {
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

    /// Tap an answer in your plan: back to that question.
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

    /// Fill your plan from what the server already has (an onboarding
    /// started earlier, or on another device) and pick up where it left off.
    private func restoreFromServer() {
        let draft = appModel.onboardingDraft
        for step in Step.all where chips[step.field] == nil {
            if let label = step.chip(for: draft[step.field], draft: draft) { chips[step.field] = label }
        }
        if customized, chips["customize"] == nil, Step.all.dropLast().allSatisfy({ chips[$0.field] != nil }) {
            chips["customize"] = "Your coach"
        }
        if let days = draft["preferredDays"] as? [String], !days.isEmpty { self.days = Set(days) }
        if let saved = draft["equipment"] as? [String] { gear = Set(saved) }
        about.adopt(draft)
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
        if let index = Step.all.firstIndex(where: { $0.fields.contains(missing) }) {
            stepIndex = index
        } else if appModel.onboardingStatus == .proposalReady,
                  let index = Step.all.firstIndex(where: { chips[$0.field] == nil }) {
            // Server has everything; only "make it yours" is left.
            stepIndex = index
        }
    }

    // MARK: - The coach's voice

    private func askCurrentQuestion() {
        guard lastSpokenStep != stepIndex else { return }
        if isWeek {
            guard let proposal = appModel.pendingProgramProposal else { return }
            lastSpokenStep = stepIndex
            let days = proposal.workoutDays.filter { !$0.exerciseNames.isEmpty }.map { Self.dayName($0.dayKey) }
            speak("Here's your week: \(Self.list(days)). Tap Start with this, or tap your answers up top to change one.")
            return
        }
        guard let step else { return }
        lastSpokenStep = stepIndex
        let intro = stepIndex == 0 && chips.isEmpty
            ? "Hi, I'm your coach. A few quick questions and I'll build your first week. "
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

    /// The free space between the header and the question: the body
    /// stands in it, feet just above the question, and shrinks to fit.
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
        /// What it looks like in your plan.
        let chip: String
        let answer: [String: Any]
        /// Tapping it asks for words instead (e.g. "Something hurts").
        var asksForWords: String? = nil
    }

    enum Kind {
        case choices([Option])
        case schedule
        case gear
        case aboutYou
        case customize
    }

    let field: String
    let question: String
    let kind: Kind

    /// Its name in the answers list.
    var short: String {
        switch field {
        case "goals": return "Goal"
        case "trainingExperience": return "Experience"
        case "equipment": return "Gear"
        case "preferredDays": return "When"
        case "ageYears": return "You"
        case "injuriesOrLimitations": return "Limits"
        default: return "Coach"
        }
    }

    /// The server fields this card answers ("About you" is four).
    var fields: [String] {
        switch kind {
        case .aboutYou: return ["ageYears", "sexOrGender", "heightCm", "weightKg"]
        case .customize: return []
        default: return [field]
        }
    }

    /// The plan label for an answer the server already has.
    func chip(for value: Any?, draft: [String: Any]) -> String? {
        guard let value else { return nil }
        switch kind {
        case .customize:
            return nil
        case .gear:
            guard let list = value as? [String], !list.isEmpty else { return nil }
            return list.map { item in GearCard.options.first { $0.key == item }?.label ?? item.capitalized }
                .joined(separator: " · ")
        case .aboutYou:
            var about = AboutYou()
            guard about.adopt(draft) else { return nil }
            return about.chip
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
        Step(field: "equipment", question: "What do you have to train with? Pick everything.", kind: .gear),
        Step(field: "preferredDays", question: "Which days work, and what time?", kind: .schedule),
        Step(field: "ageYears", question: "A bit about you.", kind: .aboutYou),
        Step(field: "injuriesOrLimitations",
             question: "Does anything hurt, or has a doctor told you to limit exercise?",
             kind: .choices([
                Option(label: "All good", chip: "No limits", answer: ["injuriesOrLimitations": ["none"]]),
                Option(label: "Something hurts", chip: "Something hurts", answer: [:],
                       asksForWords: "Tell me where, and what makes it worse."),
                Option(label: "A doctor's limit, or chest pain, dizziness or fainting when active",
                       chip: "Doctor's limit", answer: ["injuriesOrLimitations": ["doctor advised limit"]]),
             ])),
        Step(field: "customize", question: "Last thing. Make me yours: my color, and how I coach you.", kind: .customize),
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

/// Glass round the header line once there's an answer in it; bare dots before.
private struct PlanPill: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.myoGlass() } else { content }
    }
}

/// Frames of the onboarding stage's parts, by name.
private struct StageFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Gear, about you, make it yours

/// Everything they have, all that apply. A gym covers the rest.
private struct GearCard: View {
    struct Item: Identifiable { let key: String; let label: String; var id: String { key } }
    static let options: [Item] = [
        Item(key: "full gym", label: "Full gym"),
        Item(key: "dumbbells", label: "Dumbbells"),
        Item(key: "kettlebells", label: "Kettlebells"),
        Item(key: "barbell", label: "Barbell"),
        Item(key: "bench", label: "Bench"),
        Item(key: "pull-up bar", label: "Pull-up bar"),
        Item(key: "bands", label: "Bands"),
        Item(key: "bodyweight", label: "Just my body"),
    ]
    private static let exclusive: Set<String> = ["full gym", "bodyweight"]

    @Binding var selected: Set<String>
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
            FlowRow(spacing: 8) {
                ForEach(Self.options) { item in
                    let on = selected.contains(item.key)
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if on {
                            selected.remove(item.key)
                        } else if Self.exclusive.contains(item.key) {
                            selected = [item.key]
                        } else {
                            selected.subtract(Self.exclusive)
                            selected.insert(item.key)
                        }
                    } label: {
                        Text(item.label)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(on ? MyoTheme.Colors.ink : MyoColor.Text.primary.color)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 46)
                            .contentShape(Capsule())
                            .myoGlass(tint: on ? MyoTheme.Colors.coachAmber.opacity(0.45) : nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            DoneButton(title: "That's everything", enabled: !selected.isEmpty, action: onDone)
        }
        .padding(MyoTheme.Spacing.lg)
        .myoCard()
    }
}

/// Age, sex or gender, height and weight — exact, because loads and
/// estimates depend on them.
private struct AboutYou {
    var age = 30
    var sex: String?
    var metric = Locale.current.measurementSystem != .us
    var heightCm = 175
    var weightKg = 75.0

    static let sexes: [(key: String, label: String)] = [
        ("male", "Male"), ("female", "Female"), ("non_binary", "Non-binary"), ("prefer_not_to_say", "Prefer not to say"),
    ]

    var heightLabel: String {
        if metric { return "\(heightCm) cm" }
        let inches = Int((Double(heightCm) / 2.54).rounded())
        return "\(inches / 12)′\(inches % 12)″"
    }
    var weightLabel: String {
        metric ? "\(Int(weightKg.rounded())) kg" : "\(Int((weightKg / 0.453592).rounded())) lb"
    }
    var chip: String {
        let sexLabel = Self.sexes.first { $0.key == sex }?.label
        return ([String(age)] + (sexLabel.map { [$0] } ?? []) + [heightLabel, weightLabel]).joined(separator: " · ")
    }
    var answer: [String: Any] {
        ["ageYears": age, "sexOrGender": sex ?? "prefer_not_to_say", "heightCm": heightCm,
         "weightKg": (weightKg * 10).rounded() / 10]
    }

    /// Take what the server already has. True if it has all four.
    @discardableResult
    mutating func adopt(_ draft: [String: Any]) -> Bool {
        func number(_ key: String) -> Double? { (draft[key] as? NSNumber)?.doubleValue }
        if let value = number("ageYears") { age = Int(value) }
        if let value = draft["sexOrGender"] as? String { sex = value }
        if let value = number("heightCm") { heightCm = Int(value.rounded()) }
        if let value = number("weightKg") { weightKg = value }
        return ["ageYears", "sexOrGender", "heightCm", "weightKg"].allSatisfy { draft[$0] != nil }
    }
}

private struct AboutYouCard: View {
    @Binding var about: AboutYou
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
            HStack(spacing: MyoTheme.Spacing.sm) {
                pickerPill("Age", value: "\(about.age)") {
                    Picker("Age", selection: $about.age) {
                        ForEach(13...90, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
                pickerPill("Height", value: about.heightLabel) {
                    Picker("Height", selection: $about.heightCm) {
                        ForEach(Array(stride(from: 140, through: 215, by: 1)), id: \.self) { cm in
                            Text(about.metric ? "\(cm) cm" : Self.feet(cm)).tag(cm)
                        }
                    }
                }
                pickerPill("Weight", value: about.weightLabel) {
                    Picker("Weight", selection: Binding(
                        get: { Int(about.weightKg.rounded()) },
                        set: { about.weightKg = Double($0) }
                    )) {
                        ForEach(35...200, id: \.self) { kg in
                            Text(about.metric ? "\(kg) kg" : "\(Int((Double(kg) / 0.453592).rounded())) lb").tag(kg)
                        }
                    }
                }
            }
            FlowRow(spacing: 8) {
                ForEach(AboutYou.sexes, id: \.key) { option in
                    let on = about.sex == option.key
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        about.sex = option.key
                    } label: {
                        Text(option.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(on ? MyoTheme.Colors.ink : MyoColor.Text.primary.color)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 40)
                            .contentShape(Capsule())
                            .myoGlass(tint: on ? MyoTheme.Colors.coachAmber.opacity(0.45) : nil)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button(about.metric ? "Use lb and ft" : "Use kg and cm") { about.metric.toggle() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MyoColor.Text.secondary.color)
                Spacer()
            }
            DoneButton(title: "That's me", enabled: about.sex != nil, action: onDone)
        }
        .padding(MyoTheme.Spacing.lg)
        .myoCard()
    }

    private func pickerPill<P: View>(_ title: String, value: String, @ViewBuilder picker: () -> P) -> some View {
        Menu {
            picker()
        } label: {
            VStack(spacing: 2) {
                Text(title.uppercased())
                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                    .foregroundStyle(MyoColor.Text.tertiary.color)
                Text(value)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MyoColor.Text.primary.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .myoGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private static func feet(_ cm: Int) -> String {
        let inches = Int((Double(cm) / 2.54).rounded())
        return "\(inches / 12)′\(inches % 12)″"
    }
}

/// The coach's color (its body changes as you tap) and how it talks to you.
private struct CustomizeCard: View {
    @Binding var coachHex: String
    @Binding var tone: String
    @Binding var tips: String
    let onDone: () -> Void

    private static let styles: [(label: String, tone: CoachingStyle.Tone, tips: CoachingStyle.Tips)] = [
        ("Hype me up", .hype, .full),
        ("Calm and clear", .calm, .full),
        ("Just the essentials", .calm, .brief),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
            CoachColorPicker(hex: $coachHex)
            MyoHairline()
            FlowRow(spacing: 8) {
                ForEach(Self.styles, id: \.label) { style in
                    let on = tone == style.tone.rawValue && tips == style.tips.rawValue
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        tone = style.tone.rawValue
                        tips = style.tips.rawValue
                    } label: {
                        Text(style.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(on ? MyoTheme.Colors.ink : MyoColor.Text.primary.color)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 42)
                            .contentShape(Capsule())
                            .myoGlass(tint: on ? MyoTheme.Colors.coachAmber.opacity(0.45) : nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            DoneButton(title: "Looks good", enabled: true, action: onDone)
        }
        .padding(MyoTheme.Spacing.lg)
        .myoCard()
    }
}

private struct DoneButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(MyoTheme.Colors.ink)
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Capsule())
                .myoGlass(tint: MyoTheme.Colors.coachAmber.opacity(0.4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
