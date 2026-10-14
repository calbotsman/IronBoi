import SwiftUI

/// Onboarding on the coach's own stage: the same body, the same tap-to-talk
/// and type-to-talk as home. The coach asks a few things out loud; each answer
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
    @State private var safety = SafetyAnswers()
    @State private var activities: Set<String> = []
    /// Said before the next question: an honest word about what MYO coaches.
    @State private var aside: String?
    /// How they chose to do onboarding: "voice" (the coach asks, they talk,
    /// almost no UI) or "tap" (the cards). Empty until they pick.
    @AppStorage("onboarding.mode") private var mode = ""
    /// Picked talk or tap in this run (the stored mode alone could be from
    /// an earlier account on this phone).
    @State private var choseMode = false
    /// Answers the coach couldn't make out, per step: two and the step's
    /// cards appear, so talking never becomes a dead end.
    @State private var misses: [Int: Int] = [:]
    /// Voice mode, the gear question: everything named so far, sent
    /// together, until "that's it".
    @State private var gearHeard: [String] = []
    @AppStorage(CoachColor.storageKey) private var coachHex = CoachColor.defaultHex
    @AppStorage(CoachingStyle.toneKey) private var toneSetting = CoachingStyle.Tone.hype.rawValue
    @AppStorage(CoachingStyle.tipsKey) private var tipsSetting = CoachingStyle.Tips.full.rawValue
    @AppStorage("onboarding.customized") private var customized = false
    @AppStorage("onboarding.voiced") private var voiced = false
    @AppStorage(CoachVoiceOption.storageKey) private var voiceName = CoachVoiceOption.defaultName
    @State private var time = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()

    private var isWeek: Bool { stepIndex >= Step.all.count }
    /// The first screen: talk or tap?
    private var choosingMode: Bool { !choseMode && chips.isEmpty }
    private var voiceMode: Bool { mode == "voice" && !choosingMode }
    /// Talking doesn't take the cards away: they're always there for when
    /// you can't talk right now. Voice mode only means the coach asks out
    /// loud and the mic opens on its own. These steps are tap-only (a health
    /// answer must never be misheard; a color is picked by eye), so the mic
    /// stays closed on them.
    private var listensForAnswer: Bool {
        guard let step else { return isWeek }
        switch step.kind {
        case .safety, .customize, .voice: return false
        default: return true
        }
    }
    /// The health screen says a doctor first: no plan until they're cleared.
    private var showsClearance: Bool {
        appModel.onboardingMissingFields.first == "medicalClearance" && inFlight == 0
            && chips["injuriesOrLimitations"] != nil
    }
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
                    .opacity(choosingMode ? 0 : 1)
                    .background { measure("header") }
                Spacer(minLength: 0)
                caption
                    .background { measure("caption") }
                    // Voice mode: when the coach finishes asking, the mic opens.
                    .onChange(of: voice.isSpeaking) { _, speaking in
                        if !speaking { listenIfVoiceMode() }
                    }
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
            // A brand-new onboarding starts on "talk or tap?", and asks every
            // question again (an earlier run's "customized" mustn't skip the
            // color and voice steps for a new account).
            if chips.isEmpty {
                resetToNewUser()
                customized = false
                voiced = false
                gearHeard = []
                misses = [:]
            }
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
        case .rest:
            if choosingMode { return "MYO" }
            return isWeek ? "Your first week" : "\(stepIndex + 1) of \(Step.all.count)"
        }
    }

    private var captionText: String {
        if voiceInput.isListening {
            // Voice mode keeps the question up until your words replace it.
            if voiceInput.transcript.isEmpty { return voiceMode ? (step?.spokenQuestion ?? " ") : " " }
            return voiceInput.transcript
        }
        if let notice { return notice }
        if choosingMode { return "Want to do this by talking, or by tapping?" }
        if showsClearance { return "Before we start, please check with a doctor." }
        if isWeek {
            return appModel.pendingProgramProposal == nil ? "Putting your week together…" : "Here's your week."
        }
        return (voiceMode ? step?.spokenQuestion : step?.question) ?? ""
    }

    // MARK: - The card under the coach

    @ViewBuilder
    private var card: some View {
        if choosingMode {
            ModeCard {
                chooseVoice()
            } onTap: {
                choseMode = true
                mode = "tap"
                lastSpokenStep = nil
                askCurrentQuestion()
            }
        } else if showsClearance {
            ClearanceCard(reasons: appModel.onboardingDraft["screenReasons"] as? [String] ?? []) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                notice = nil
                enqueue("My doctor cleared me", structured: ["medicalClearance": "cleared"], mode: .tap)
            } onChange: {
                if let index = Step.all.firstIndex(where: { $0.field == "injuriesOrLimitations" }) { change(index) }
            }
            .onAppear {
                lastSpokenStep = nil
                speak("Before we start, please check with a doctor. When they've cleared you, tap My doctor cleared me.")
            }
        } else if isWeek {
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
            case .activities:
                ActivitiesCard(selected: $activities) {
                    let picked = ActivitiesCard.options.filter { activities.contains($0.key) }
                    if !activities.isDisjoint(with: ["run", "yoga", "sport"]) {
                        aside = "Good to know. For now I build strength plans, with mobility and easy cardio in them. Running and yoga plans are coming. "
                    }
                    answer(["activities": picked.map(\.key)], chip: picked.map(\.label).joined(separator: " · "),
                           content: picked.map(\.label).joined(separator: ", "))
                }
            case .safety:
                SafetyCard(answers: $safety) {
                    answer(safety.answer, chip: safety.chip, content: safety.chip)
                }
            case .aboutYou:
                AboutYouCard(about: $about) {
                    answer(about.answer, chip: about.chip, content: about.chip)
                }
            case .customize:
                ColorCard(coachHex: $coachHex) {
                    customized = true
                    finishLocal(step, chip: CoachColor.name(hue: CoachColor.position(of: coachHex).hue))
                }
            case .voice:
                VoiceCard(voiceName: $voiceName, tone: $toneSetting, tips: $tipsSetting) { sample in
                    lastSpokenStep = stepIndex
                    voice.speak(sample, messageId: "onboarding-voice-\(UUID().uuidString)")
                } onDone: {
                    voiced = true
                    finishLocal(step, chip: CoachVoiceOption.label(voiceName))
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

    @ViewBuilder
    private var controls: some View {
        if choosingMode {
            Color.clear.frame(height: 52)
        } else if voiceMode {
            HStack(spacing: MyoTheme.Spacing.sm) {
                roundButton(systemImage: voiceInput.isListening ? "mic.fill" : "mic",
                            label: voiceInput.isListening ? "Stop listening" : "Talk",
                            active: voiceInput.isListening) {
                    talkTapped()
                }
                Spacer()
                Button("Tap instead") {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    voiceInput.release()
                    mode = "tap"
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(MyoColor.Text.secondary.color)
                .frame(minHeight: 44)
            }
        } else {
            tapControls
        }
    }

    private var tapControls: some View {
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

    /// "Make it yours" answers live on this phone, not the server.
    private func finishLocal(_ step: Step, chip: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        voice.stop()
        notice = nil
        chips[step.field] = chip
        lastChipField = step.field
        advance()
    }

    /// Said or typed: the server reads it, and the question moves on only if
    /// it understood.
    private func answerInWords(_ text: String, mode: CoachInputMode) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The end of onboarding, by voice: "yes", "let's go" accepts the week.
        if isWeek, voiceMode, appModel.pendingProgramProposal != nil,
           trimmed.lowercased().range(of: #"\b(yes|yeah|yep|sure|ok|okay|sounds good|let's go|lets go|start|do it|perfect)\b"#,
                                      options: .regularExpression) != nil {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task { await appModel.acceptPendingProgramProposal() }
            return
        }
        guard !trimmed.isEmpty, let step else { return }
        if case .activities = step.kind {
            let picked = Self.activities(in: trimmed)
            if picked.isEmpty {
                missed("Sorry, I didn't catch that. Lifting, running, yoga, mobility, a sport?")
            } else {
                activities = picked
                // Gear named here isn't wasted: it's kept for the gear question.
                if Self.mentionsGear(trimmed) {
                    enqueue(trimmed, structured: nil, mode: mode, field: "equipment")
                    aside = (aside ?? "") + "I've got your gear too. "
                }
                let items = ActivitiesCard.options.filter { picked.contains($0.key) }
                if !picked.isDisjoint(with: ["run", "yoga", "sport"]) {
                    aside = "Good to know. For now I build strength plans, with mobility and easy cardio in them. Running and yoga plans are coming. "
                }
                answer(["activities": items.map(\.key)], chip: items.map(\.label).joined(separator: " · "),
                       content: trimmed)
            }
            return
        }
        if voiceMode, case .gear = step.kind {
            gearConversation(trimmed, mode: mode, step: step)
            return
        }
        if step.fields.isEmpty {
            notice = "Tap your pick below."
            return
        }
        if case .safety = step.kind {
            notice = "Tap your answers below, so nothing gets misheard."
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
                misses[stepIndex] = 2
                notice = "Got some of that. Fill in the rest below."
                speak(notice ?? "")
            } else if stillMissing && appModel.onboardingStatus != .proposalReady {
                missed(voiceMode ? "Sorry, I didn't catch that. Say it another way." : "Sorry, I didn't catch that. Tap a card, or say it another way.")
            } else {
                // What the server made of it ("Dumbbells · Bench"), not the raw words.
                let draft = appModel.onboardingDraft
                chips[field] = step.chip(for: draft[field], draft: draft) ?? Self.shortChip(trimmed)
                lastChipField = field
                advance()
            }
        }
    }

    /// Voice mode, the gear question: "Got kettlebells. Anything else?" until
    /// they say that's it, so a pause to think doesn't end the list.
    private func gearConversation(_ text: String, mode: CoachInputMode, step: Step) {
        let done = text.lowercased().range(
            of: #"^(no|nope|nah|that's it|that is it|that's all|that's everything|nothing else|done|i'm done|thats it|that's about it)\b"#,
            options: .regularExpression) != nil
        if done, !gearHeard.isEmpty {
            gearHeard = []
            let draft = appModel.onboardingDraft
            chips[step.field] = step.chip(for: draft[step.field], draft: draft) ?? "Your gear"
            lastChipField = step.field
            advance()
            return
        }
        gearHeard.append(text)
        voice.stop()
        awaitingParse = step.field
        enqueue(gearHeard.joined(separator: ", "), structured: nil, mode: mode, field: step.field) {
            awaitingParse = nil
            let draft = appModel.onboardingDraft
            guard let label = step.chip(for: draft[step.field], draft: draft) else {
                gearHeard.removeLast()
                missed("Sorry, I didn't catch that. What do you have, like dumbbells, bands, or just your body?")
                return
            }
            notice = "Got: \(label). Anything else?"
            speak("Got \(label.replacingOccurrences(of: " · ", with: ", ")). Anything else, or is that it?")
        }
    }

    /// An answer the coach couldn't use: say so, and after the second miss
    /// on a step in voice mode, put its cards up.
    private func missed(_ line: String) {
        misses[stepIndex, default: 0] += 1
        let text = voiceMode && misses[stepIndex, default: 0] >= 2 ? "You can tap it below, or say it another way." : line
        notice = text
        lastSpokenStep = nil
        speak(text)
    }

    /// Voice mode: the mic is wanted, so ask for it now (with a reason the
    /// coach just said). Without it, tapping it is.
    private func chooseVoice() {
        choseMode = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        voice.stop()
        Task {
            let granted = await voiceInput.requestPermissionsIfNeeded()
            mode = granted ? "voice" : "tap"
            if !granted { notice = "No microphone, so let's tap. You can turn it on in Settings later." }
            lastSpokenStep = nil
            askCurrentQuestion()
        }
    }

    /// Training kit in what was said: "kettlebells, dumbbells, a barbell".
    private static func mentionsGear(_ text: String) -> Bool {
        text.lowercased().range(of: #"\b(dumbbells?|kettle ?bells?|barbells?|bench|rack|bands?|clubs?|med(icine)? ball|weighted ball|sandbag|pull[- ]?up bar|cable|machines?|plates?)\b"#,
                                options: .regularExpression) != nil
    }

    /// "I lift, and I run a bit" → lift, run.
    private static func activities(in text: String) -> Set<String> {
        let t = text.lowercased()
        func says(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }
        var out: Set<String> = []
        if says(#"\b(lift|lifting|weights?|gym|strength|bodybuilding|powerlifting)\b"#) || mentionsGear(text) { out.insert("lift") }
        if says(#"\b(run|running|jog|jogging|runner|5k|10k|marathon)\b"#) { out.insert("run") }
        if says(#"\byoga\b"#) { out.insert("yoga") }
        if says(#"\b(mobility|stretch|stretching|flexibility|pilates)\b"#) { out.insert("mobility") }
        if says(#"\b(sport|sports|tennis|soccer|football|basketball|golf|climbing|cycling|swimming|hockey|pickleball|boxing|punching bag|martial arts|mma|kickboxing|jiu jitsu)\b"#) { out.insert("sport") }
        if out.isEmpty, says(#"\b(not sure|don't know|dont know|no idea|anything|whatever)\b"#) { out.insert("not_sure") }
        return out
    }

    private func enqueue(_ content: String, structured: [String: Any]?, mode: CoachInputMode, field: String? = nil,
                         then: (@MainActor () -> Void)? = nil) {
        inFlight += 1
        let previous = sendQueue
        sendQueue = Task { @MainActor in
            await previous?.value
            await appModel.sendOnboardingAnswer(content, inputMode: mode, structuredAnswer: structured, field: field)
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
        // The phone-only answers count once the server ones are all in.
        if Step.all.filter({ !$0.fields.isEmpty }).allSatisfy({ chips[$0.field] != nil }) {
            if customized, chips["customize"] == nil {
                chips["customize"] = CoachColor.name(hue: CoachColor.position(of: coachHex).hue)
            }
            if voiced, chips["voice"] == nil { chips["voice"] = CoachVoiceOption.label(voiceName) }
        }
        if let days = draft["preferredDays"] as? [String], !days.isEmpty { self.days = Set(days) }
        // The time you picked ("06:00"), not the 6 PM the picker starts on.
        if let saved = draft["preferredTime"] as? String {
            let parts = saved.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2, let picked = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date()) {
                time = picked
            }
        }
        if let saved = draft["equipment"] as? [String] { gear = Set(saved) }
        if let saved = draft["activities"] as? [String] { activities = Set(saved) }
        about.adopt(draft)
        safety.adopt(draft)
        syncStep()
    }

    /// A first run starts from MYO's defaults, not an earlier account's
    /// choices on this phone: amber, the warm voice, hype, full tips, cream.
    private func resetToNewUser() {
        coachHex = CoachColor.defaultHex
        voiceName = CoachVoiceOption.defaultName
        UserDefaults.standard.set(false, forKey: CoachVoiceOption.chosenKey)
        toneSetting = CoachingStyle.Tone.hype.rawValue
        tipsSetting = CoachingStyle.Tips.full.rawValue
        PaperStore.shared.paper = Paper.all[0]
    }

    /// The account was reset while this screen was open: start over here
    /// too, from "talk or tap?".
    private func startOverIfReset() {
        guard appModel.onboardingDraft.isEmpty, appModel.onboardingStatus == .notStarted, !chips.isEmpty else { return }
        chips = [:]
        stepIndex = 0
        choseMode = false
        resetToNewUser()
        customized = false
        voiced = false
        gearHeard = []
        misses = [:]
        safety = SafetyAnswers()
        activities = []
        lastSpokenStep = nil
        voiceInput.release()
        voice.stop()
        askCurrentQuestion()
    }

    private func serverMoved() {
        startOverIfReset()
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
        if choosingMode {
            speak("Hi, I'm your coach. Want to do this by talking, or by tapping?")
            return
        }
        guard lastSpokenStep != stepIndex else { return }
        if isWeek {
            guard let proposal = appModel.pendingProgramProposal else { return }
            lastSpokenStep = stepIndex
            let days = proposal.workoutDays.filter { !$0.exerciseNames.isEmpty }.map { Self.dayName($0.dayKey) }
            speak(voiceMode
                ? "Here's your week: \(Self.list(days)). Say yes to start with it, or tell me what to change."
                : "Here's your week: \(Self.list(days)). Tap Start with this, or tap your answers up top to change one.")
            return
        }
        guard let step else { return }
        lastSpokenStep = stepIndex
        let intro = stepIndex == 0 && chips.isEmpty
            ? "Great. A few quick questions and I'll build your first week. "
            : ""
        // Voice mode, a step that's taps anyway: say why.
        voiceInput.extraPause = voiceMode ? Self.voicePause(for: step) : 1_200_000_000
        var outro = ""
        if voiceMode, case .safety = step.kind { outro = " Just tap your answers, so nothing gets misheard." }
        speak((aside ?? "") + intro + (voiceMode ? step.spokenQuestion : step.question) + outro)
        aside = nil
    }

    private func speak(_ text: String) {
        guard speaksReplies, !text.isEmpty, !voiceInput.isListening else {
            // Voice mode with the coach's voice off: still listen for the answer.
            listenIfVoiceMode()
            return
        }
        voice.speak(text, messageId: "onboarding-\(UUID().uuidString)")
    }

    /// Voice mode, nothing to tap on this step: open the mic for the answer.
    private func listenIfVoiceMode() {
        guard voiceMode, listensForAnswer, !showsClearance, awaitingParse == nil, !voiceInput.isListening,
              !voice.isSpeaking, !showKeyboard else { return }
        if isWeek, appModel.pendingProgramProposal == nil { return }
        voiceInput.listen()
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

    /// Voice mode waits longer before your turn is over, longest on lists,
    /// where people stop to think ("kettlebells… dumbbells…").
    private static func voicePause(for step: Step) -> UInt64 {
        switch step.kind {
        case .gear, .activities, .schedule, .aboutYou: return 2_800_000_000
        default: return 1_800_000_000
        }
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
        case activities
        case safety
        case customize
        case voice
    }

    let field: String
    let question: String
    let kind: Kind

    /// How the coach asks it out loud in voice mode: no "pick" or "tap".
    var spokenQuestion: String {
        switch field {
        case "activities": return "What kind of training do you like, or want to try? Lifting, running, yoga, a sport, or not sure?"
        case "equipment": return "What do you have to train with? Name everything, even small stuff like bands."
        case "preferredDays": return "Which days can you train, and at what time?"
        case "ageYears": return "Tell me a bit about you: your age, and your height and weight if you're happy to."
        default: return question
        }
    }

    /// Its name in the answers list.
    var short: String {
        switch field {
        case "goals": return "Goal"
        case "trainingExperience": return "Experience"
        case "equipment": return "Gear"
        case "preferredDays": return "When"
        case "ageYears": return "You"
        case "injuriesOrLimitations": return "Health"
        case "voice": return "Voice"
        case "activities": return "Likes"
        default: return "Color"
        }
    }

    /// The server fields this card answers ("About you" is four).
    var fields: [String] {
        switch kind {
        case .aboutYou: return ["ageYears", "sexOrGender", "heightCm", "weightKg"]
        case .customize, .voice, .activities: return []
        default: return [field]
        }
    }

    /// The plan label for an answer the server already has.
    func chip(for value: Any?, draft: [String: Any]) -> String? {
        guard let value else { return nil }
        switch kind {
        case .customize, .voice:
            return nil
        case .activities:
            guard let picked = value as? [String], !picked.isEmpty else { return nil }
            return ActivitiesCard.options.filter { picked.contains($0.key) }.map(\.label).joined(separator: " · ")
        case .safety:
            guard draft["healthScreen"] != nil || value is [Any] else { return nil }
            let limits = (draft["injuriesOrLimitations"] as? [String]) ?? []
            return limits.filter { $0 != "none" }.isEmpty ? "All clear" : "Health notes"
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
        Step(field: "activities", question: "What do you like to do, or want to try? Pick any.", kind: .activities),
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
             question: "Four quick health questions, so I keep you safe.",
             kind: .safety),
        Step(field: "customize", question: "Now make me yours. Pick my color.", kind: .customize),
        Step(field: "voice", question: "Last thing: how should I sound, and how should I coach you?", kind: .voice),
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

/// The first screen: do onboarding by talking or by tapping.
private struct ModeCard: View {
    let onVoice: () -> Void
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: MyoTheme.Spacing.sm) {
            choice("Let's talk", detail: "I ask out loud, you answer. Tapping still works", icon: "mic.fill", action: onVoice)
            choice("I'll tap", detail: "Quick taps, and you can talk any time", icon: "hand.tap.fill", action: onTap)
        }
    }

    private func choice(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: MyoTheme.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MyoTheme.Colors.ink)
                    .frame(width: 44, height: 44)
                    .myoGlass(tint: MyoTheme.Colors.coachAmber.opacity(0.35), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(MyoColor.Text.primary.color)
                    Text(detail).font(.footnote).foregroundStyle(MyoColor.Text.secondary.color)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MyoTheme.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: 68)
            .contentShape(RoundedRectangle(cornerRadius: 24))
            .myoGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// What they like to do: demand data for what MYO coaches next, and an
/// honest answer if it's something MYO doesn't plan yet.
private struct ActivitiesCard: View {
    struct Item: Identifiable { let key: String; let label: String; var id: String { key } }
    static let options: [Item] = [
        Item(key: "lift", label: "Lift weights"), Item(key: "run", label: "Run"), Item(key: "yoga", label: "Yoga"),
        Item(key: "mobility", label: "Mobility"), Item(key: "sport", label: "A sport"), Item(key: "not_sure", label: "Not sure yet"),
    ]

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
                        } else if item.key == "not_sure" {
                            selected = ["not_sure"]
                        } else {
                            selected.remove("not_sure")
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
            DoneButton(title: "That's me", enabled: !selected.isEmpty, action: onDone)
        }
        .padding(MyoTheme.Spacing.lg)
        .myoCard()
    }
}

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
                        // MYO is for adults for now.
                        ForEach(18...90, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
                pickerPill("Height", value: about.heightLabel) {
                    // One row per inch in feet and inches, not per centimetre
                    // (which showed 5′11″ twice).
                    if about.metric {
                        Picker("Height", selection: $about.heightCm) {
                            ForEach(140...215, id: \.self) { Text("\($0) cm").tag($0) }
                        }
                    } else {
                        Picker("Height", selection: Binding(
                            get: { Int((Double(about.heightCm) / 2.54).rounded()) },
                            set: { about.heightCm = Int((Double($0) * 2.54).rounded()) }
                        )) {
                            ForEach(55...85, id: \.self) { inches in
                                Text("\(inches / 12)′\(inches % 12)″").tag(inches)
                            }
                        }
                    }
                }
                pickerPill("Weight", value: about.weightLabel) {
                    if about.metric {
                        Picker("Weight", selection: Binding(
                            get: { Int(about.weightKg.rounded()) },
                            set: { about.weightKg = Double($0) }
                        )) {
                            ForEach(35...200, id: \.self) { Text("\($0) kg").tag($0) }
                        }
                    } else {
                        Picker("Weight", selection: Binding(
                            get: { Int((about.weightKg / 0.453592).rounded()) },
                            set: { about.weightKg = Double($0) * 0.453592 }
                        )) {
                            ForEach(77...440, id: \.self) { Text("\($0) lb").tag($0) }
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
                Text("MYO is for adults, 18 and up")
                    .font(.caption)
                    .foregroundStyle(MyoColor.Text.tertiary.color)
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
}

/// The coach's color: its body is the preview, changing as you drag.
private struct ColorCard: View {
    @Binding var coachHex: String
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
            CoachColorPicker(hex: $coachHex)
            DoneButton(title: "Love it", enabled: true, action: onDone)
        }
        .padding(MyoTheme.Spacing.lg)
        .myoCard()
    }
}

/// How the coach sounds (each tap plays it) and how it coaches you. Picking
/// a style suggests a feel until you pick a voice yourself.
private struct VoiceCard: View {
    @Binding var voiceName: String
    @Binding var tone: String
    @Binding var tips: String
    let onTry: (String) -> Void
    let onDone: () -> Void
    @AppStorage(CoachVoiceOption.chosenKey) private var voiceChosen = false

    private static let styles: [(label: String, tone: CoachingStyle.Tone, tips: CoachingStyle.Tips)] = [
        ("Hype me up", .hype, .full),
        ("Calm and clear", .calm, .full),
        ("Just the essentials", .calm, .brief),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
            CoachVoicePicker(name: $voiceName, onTry: onTry)
            MyoHairline()
            FlowRow(spacing: 8) {
                ForEach(Self.styles, id: \.label) { style in
                    let on = tone == style.tone.rawValue && tips == style.tips.rawValue
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        tone = style.tone.rawValue
                        tips = style.tips.rawValue
                        if !voiceChosen {
                            let current = CoachVoiceOption.voice(named: voiceName)
                            voiceName = CoachVoiceOption.name(
                                female: current.female, feel: CoachVoiceOption.feel(tone: style.tone, tips: style.tips))
                        }
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
            DoneButton(title: "Sounds good", enabled: true, action: onDone)
        }
        .padding(MyoTheme.Spacing.lg)
        .myoCard()
    }
}

/// The health screen's answers (functions/src/onboarding/healthScreen.ts
/// decides what they mean).
private struct SafetyAnswers {
    var activeNow: String?
    var conditions: Set<String> = []
    var noneOfThese = false
    var symptoms: Bool?
    var pregnancyContraindication: Bool?
    var hurts: Bool?
    var pain = ""

    static let activity: [(key: String, label: String)] = [
        ("regular", "Most weeks"), ("some", "Sometimes"), ("none", "Not really"),
    ]
    static let conditionOptions: [(key: String, label: String)] = [
        ("heart", "Heart condition"), ("high_blood_pressure", "High blood pressure"), ("diabetes", "Diabetes"),
        ("kidney", "Kidney disease"), ("lung", "Asthma or lung"), ("pregnant", "Pregnant"),
        ("postpartum", "New baby"), ("surgery", "Recent surgery"), ("osteoporosis", "Osteoporosis"),
        ("glaucoma", "Glaucoma"), ("falls", "Falls or unsteady"),
    ]

    var complete: Bool {
        activeNow != nil && (noneOfThese || !conditions.isEmpty) && symptoms != nil && hurts != nil
            && (!conditions.contains("pregnant") || pregnancyContraindication != nil)
            && (hurts == false || !pain.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var answer: [String: Any] {
        var screen: [String: Any] = [
            "activeNow": activeNow ?? "none",
            "conditions": Array(conditions).sorted(),
            "symptoms": symptoms ?? false,
        ]
        if conditions.contains("pregnant") { screen["pregnancyContraindication"] = pregnancyContraindication ?? false }
        let pain = pain.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["healthScreen": screen, "injuriesOrLimitations": hurts == true && !pain.isEmpty ? [pain] : ["none"]]
    }

    var chip: String {
        conditions.isEmpty && symptoms != true && hurts != true ? "All clear" : "Health notes"
    }

    /// What the server already has (going back to change an answer).
    mutating func adopt(_ draft: [String: Any]) {
        guard let screen = draft["healthScreen"] as? [String: Any] else { return }
        activeNow = screen["activeNow"] as? String
        conditions = Set(screen["conditions"] as? [String] ?? [])
        noneOfThese = conditions.isEmpty
        symptoms = screen["symptoms"] as? Bool
        pregnancyContraindication = screen["pregnancyContraindication"] as? Bool
        let limits = (draft["injuriesOrLimitations"] as? [String]) ?? []
        let own = limits.first { !$0.contains(":") && $0 != "none" && !$0.hasPrefix("Keep effort") }
        hurts = own != nil
        pain = own ?? ""
    }
}

/// How active you are, conditions, symptoms, pain: one short question at a
/// time, all taps, nothing misheard. Single answers move straight on.
private struct SafetyCard: View {
    @Binding var answers: SafetyAnswers
    let onDone: () -> Void
    @State private var page = 0

    private enum Page { case activity, conditions, pregnancy, symptoms, pain }

    private var pages: [Page] {
        [.activity, .conditions] + (answers.conditions.contains("pregnant") ? [.pregnancy] : []) + [.symptoms, .pain]
    }
    private var current: Page { pages[min(page, pages.count - 1)] }

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
            HStack {
                Text("\(min(page, pages.count - 1) + 1) of \(pages.count)")
                    .myoStyle(.label)
                    .foregroundStyle(MyoColor.Text.tertiary.color)
                Spacer()
                if page > 0 {
                    Button("Back") { withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { page -= 1 } }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(MyoColor.Text.secondary.color)
                }
            }
            Group {
                switch current {
                case .activity: activity
                case .conditions: conditions
                case .pregnancy: pregnancy
                case .symptoms: symptoms
                case .pain: pain
                }
            }
            .id(current)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
        }
        .padding(MyoTheme.Spacing.lg)
        .myoCard()
        .clipped()
    }

    // MARK: Pages

    private var activity: some View {
        question("Do you exercise now, about 30 minutes, 3 or more days a week?") {
            ForEach(SafetyAnswers.activity, id: \.key) { option in
                row(option.label, on: answers.activeNow == option.key) { answers.activeNow = option.key; next() }
            }
        }
    }

    private var conditions: some View {
        question("Do any of these apply to you?") {
            row("None of these", on: answers.noneOfThese) {
                answers.noneOfThese = true
                answers.conditions = []
                next()
            }
            FlowRow(spacing: 8) {
                ForEach(SafetyAnswers.conditionOptions, id: \.key) { option in
                    chip(option.label, on: answers.conditions.contains(option.key)) {
                        if answers.conditions.contains(option.key) {
                            answers.conditions.remove(option.key)
                        } else {
                            answers.conditions.insert(option.key)
                            answers.noneOfThese = false
                        }
                    }
                }
            }
            if !answers.conditions.isEmpty {
                DoneButton(title: "Next", enabled: true, action: next)
            }
        }
    }

    private var pregnancy: some View {
        question("Has a doctor told you not to exercise in this pregnancy, or do you have placenta previa, preeclampsia, a cerclage, or a risk of early labor?") {
            yesNo(answers.pregnancyContraindication) { answers.pregnancyContraindication = $0; next() }
        }
    }

    private var symptoms: some View {
        question("When you're active, do you ever get chest pain, unusual breathlessness, dizziness or fainting, or a racing heartbeat?") {
            yesNo(answers.symptoms) { answers.symptoms = $0; next() }
        }
    }

    private var pain: some View {
        question("Does anything hurt right now?") {
            yesNo(answers.hurts) { hurts in
                answers.hurts = hurts
                if !hurts { finish() }
            }
            if answers.hurts == true {
                TextField("Where, and what makes it worse?", text: $answers.pain, axis: .vertical)
                    .font(.body)
                    .padding(MyoTheme.Spacing.sm)
                    .myoGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                DoneButton(title: "That's everything", enabled: answers.complete, action: finish)
            }
        }
    }

    // MARK: Pieces

    private func next() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { page = min(page + 1, pages.count - 1) }
    }

    private func finish() {
        guard answers.complete else { return }
        onDone()
    }

    private func question<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(MyoColor.Text.primary.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
            content()
        }
    }

    private func yesNo(_ value: Bool?, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 8) {
            row("No", on: value == false) { set(false) }
            row("Yes", on: value == true) { set(true) }
        }
    }

    /// A big answer, one per line (or side by side for yes and no).
    private func row(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack {
                Text(title).font(.body.weight(.semibold))
                Spacer(minLength: 4)
                if on { Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(MyoTheme.Colors.coachAmber) }
            }
            .foregroundStyle(MyoColor.Text.primary.color)
            .padding(.horizontal, MyoTheme.Spacing.lg)
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(RoundedRectangle(cornerRadius: 25))
            .myoGlass(tint: on ? MyoTheme.Colors.coachAmber.opacity(0.3) : nil,
                      in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(on ? MyoTheme.Colors.ink : MyoColor.Text.primary.color)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .contentShape(Capsule())
                .myoGlass(tint: on ? MyoTheme.Colors.coachAmber.opacity(0.45) : nil)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A doctor first: why, and the way on once they're cleared.
private struct ClearanceCard: View {
    let reasons: [String]
    let onCleared: () -> Void
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
            Text(reasons.isEmpty
                 ? "Based on your answers, a doctor should say it's OK before you start. That's what a good coach would tell you too."
                 : "Because of \(reasons.joined(separator: ", and ")), a doctor should say it's OK before you start. That's what a good coach would tell you too.")
                .font(.body)
                .foregroundStyle(MyoColor.Text.primary.color)
                .fixedSize(horizontal: false, vertical: true)
            Text("When they've cleared you, I'll start you gently and build up.")
                .font(.footnote)
                .foregroundStyle(MyoColor.Text.secondary.color)
            DoneButton(title: "My doctor cleared me", enabled: true, action: onCleared)
            Button("Change my answers", action: onChange)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(MyoColor.Text.secondary.color)
                .frame(maxWidth: .infinity)
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
