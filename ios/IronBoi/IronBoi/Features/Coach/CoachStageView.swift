import SwiftUI
import UIKit

/// The Coach tab, voice first: the coach's body in the middle, what was just
/// said underneath, one big button to talk. Typing and the full conversation
/// are one tap away but no longer the default.
///
/// A voice turn: tap → listen → pause (or tap) → send to the real coach (plan
/// tools, memory, safety) → the reply is captioned and read aloud. Tapping
/// while Coach speaks cuts it off and listens — the orb yields.
struct CoachStageView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var voiceInput: VoiceInputEngine
    @ObservedObject var voice: CoachVoice
    @ObservedObject var director: BodyDirector
    var askedForWorkout = 0
    @Binding var showKeyboard: Bool

    @AppStorage("coachSpeaksReplies") private var speaksReplies = true
    /// How much Coach says, and how — set by what you tell it.
    @AppStorage(CoachingStyle.tipsKey) private var tipsSetting = CoachingStyle.Tips.full.rawValue
    @AppStorage(CoachingStyle.toneKey) private var toneSetting = CoachingStyle.Tone.hype.rawValue
    private var tips: CoachingStyle.Tips { CoachingStyle.Tips(rawValue: tipsSetting) ?? .full }
    private var tone: CoachingStyle.Tone { CoachingStyle.Tone(rawValue: toneSetting) ?? .hype }
    /// The lift being taught out loud: what the body does on each spoken line.
    @State private var lessonPlan: LessonPlan?
    /// The beat the body is acting out right now.
    @State private var lessonCue: LessonCue?
    /// When Coach last stopped talking — a bare "stop" right after means
    /// "stop talking"; long after, it's a lyric.
    @State private var voiceStoppedAt: Date?
    /// When Coach last asked you something — mid-workout, an answer
    /// doesn't need "MYO" in front of it.
    @State private var askedAt: Date?
    /// Message ids that existed when a voice turn was sent; the first new
    /// finished coach message after that is the reply to read aloud.
    @State private var awaitingReplyAfter: Set<String>?
    /// A hands-free conversation is running: listen → you pause → Coach
    /// thinks → Coach speaks → listen again, until you tap.
    @State private var conversationActive = false
    /// You talked over Coach (or tapped) — keep the words already heard.
    @State private var cutIn = false
    /// When listening last restarted on its own; three restarts inside ten
    /// seconds with nothing heard means the recognizer is failing — stop.
    @State private var silentRestarts: [Date] = []
    /// Reps counted out loud in the current utterance.
    @State private var repCount = 0
    /// The set this count already closed (exercise index, 1-based set) —
    /// counting past the target updates it instead of starting another.
    @State private var countedSet: (exercise: Int, set: Int)?
    /// Listening was stopped by a local workout command, which restarts it
    /// itself — the timeout handler shouldn't also restart it.
    @State private var restartHandledLocally = false
    /// The count reached before the current transcript began; counting
    /// carries across the recognizer's restarts.
    @State private var countBase = 0
    /// Closes the count after a quiet stretch.
    @State private var closeCountTask: Task<Void, Never>?
    @State private var lastSpokenText = ""
    /// The body's resting place, measured from the layout.
    @State private var orbSlot: CGRect?
    /// Today's workout card, shown below the body (never over it) when you
    /// ask for your workout.
    @State private var showTodayCard = false
    /// The workout in progress: full card (body shrinks above it) or the
    /// minimized bar above the controls (body keeps its space).
    @State private var workoutExpanded = false

    /// The exercise you're on, as the coach's body demonstrates it.
    private var currentMotion: ExerciseMotion? {
        guard let index = appModel.currentExerciseIndex,
              let current = appModel.activeWorkout?.exercises[index] else { return nil }
        return ExerciseMotion.match(current.name)
    }

    /// The stage's size, for placing the body when nothing else is open.
    @State private var stageSize: CGSize = .zero

    /// Nothing below the body: it sits near the middle of the screen with
    /// the status line pinned just under it.
    private var centered: Bool { !cardOpen && appModel.pendingPlanAdjustmentProposal == nil }
    private var restFocus: CGPoint { CGPoint(x: stageSize.width / 2, y: stageSize.height * 0.42) }

    /// Any card that needs the space below the body.
    private var cardOpen: Bool {
        !appModel.pendingSessionChanges.isEmpty || !appModel.pendingBaselineSuggestions.isEmpty || (showTodayCard && appModel.activeWorkout == nil) || (appModel.activeWorkout != nil && workoutExpanded)
    }
    /// The newest coach reply already checked for a move, so history
    /// loading on launch never sets the body off.
    @State private var lastCueCheckedReplyId: String?

    private var phase: OrbPhase {
        if voice.isSpeaking { return .speaking }
        if voiceInput.isListening { return .listening }
        if appModel.isSending || awaitingReplyAfter != nil
            || appModel.messages.last?.isPendingCoachReply == true {
            return .thinking
        }
        return .rest
    }

    private var lastCoachMessage: CoachMessage? {
        appModel.messages.last { $0.role == .coach && !$0.isPendingCoachReply }
    }

    private static let space = "coachStage"
    @Namespace private var cardSpace

    #if DEBUG
    /// MYO_LIFT=squat (any exercise name): demonstrate it on a loop, to tune
    /// the movement without starting a workout.
    private var debugLift: ExerciseMotion? {
        ProcessInfo.processInfo.environment["MYO_LIFT"].flatMap(ExerciseMotion.match)
    }
    #else
    private var debugLift: ExerciseMotion? { nil }
    #endif

    var body: some View {
        ZStack {
            // The body's layer runs edge to edge, past the safe area, so your
            // droplets can enter from outside the screen. It draws nothing
            // but the body; the paper shows through everywhere else.
            GeometryReader { geo in
                let origin = geo.frame(in: .named(Self.space)).origin
                OrbView(
                    phase: phase,
                    you: voiceInput.meter,
                    agent: voice.meter,
                    focus: centered
                        ? CGPoint(x: restFocus.x - origin.x, y: restFocus.y - origin.y)
                        : orbSlot.map { CGPoint(x: $0.midX - origin.x, y: $0.midY - origin.y) },
                    director: director,
                    // Fit the body to its slot when a card squeezes it.
                    scale: centered ? 1 : orbSlot.map { min(1, max(0.4, $0.height / 460)) } ?? 1,
                    loop: currentMotion,
                    inWorkout: appModel.activeWorkout != nil,
                    demo: debugLift,
                    ambient: true,
                    lesson: lessonCue,
                    counting: repCount > 0,
                    youTalking: !voiceInput.transcript.isEmpty,
                    setsDone: appModel.activeWorkout?.exercises.reduce(0) { $0 + $1.completedSetCount } ?? 0
                )
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Where the body rests, and the thing you tap to talk.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 150, maxHeight: cardOpen ? 190 : appModel.pendingPlanAdjustmentProposal == nil ? .infinity : 220)
                    .background {
                        GeometryReader { slot in
                            Color.clear.preference(key: OrbSlotKey.self, value: slot.frame(in: .named(Self.space)))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { talkTapped() }
                    .accessibilityElement()
                    .accessibilityLabel("Coach")
                    .accessibilityValue(statusLine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(hint)
                    .accessibilityAction { talkTapped() }

                if !appModel.pendingSessionChanges.isEmpty {
                    SessionChangesCard(changes: appModel.pendingSessionChanges)
                        .padding(.horizontal, MyoTheme.Spacing.md)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if !appModel.pendingBaselineSuggestions.isEmpty {
                    WeightFollowUpCard(suggestions: appModel.pendingBaselineSuggestions)
                        .padding(.horizontal, MyoTheme.Spacing.md)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if let workout = appModel.activeWorkout, workoutExpanded {
                    LiveWorkoutCard(workout: workout, expanded: $workoutExpanded)
                        .matchedGeometryEffect(id: "workoutCard", in: cardSpace)
                        .padding(.horizontal, MyoTheme.Spacing.md)
                } else if showTodayCard, appModel.activeWorkout == nil {
                    TodayWorkoutCard(
                        onClose: { showTodayCard = false },
                        onBegin: beginWorkout
                    )
                    .matchedGeometryEffect(id: "workoutCard", in: cardSpace)
                    .padding(.horizontal, MyoTheme.Spacing.md)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    if !centered {
                        caption
                            .padding(.horizontal, MyoTheme.Spacing.lg)
                    }
                    Spacer(minLength: 0)
                    if let workout = appModel.activeWorkout {
                        // Begin workout drops the card down to this bar.
                        LiveWorkoutCard(workout: workout, expanded: $workoutExpanded)
                            .matchedGeometryEffect(id: "workoutCard", in: cardSpace)
                            .padding(.horizontal, MyoTheme.Spacing.md)
                            .padding(.top, MyoTheme.Spacing.md)
                    }
                }

                controls
                    .padding(.leading, MyoTheme.Spacing.lg)
                    .padding(.top, MyoTheme.Spacing.md)
                    .padding(.bottom, MyoTheme.Spacing.sm)
            }
        }
        .overlay {
            if centered {
                // Pinned just under the body (radius ≈ 0.45 of half the short side).
                VStack(spacing: 0) {
                    Color.clear.frame(height: restFocus.y + stageSize.width * 0.225 + 36)
                    caption.padding(.horizontal, MyoTheme.Spacing.lg)
                    // A leftover from an earlier day doesn't block today's start.
                    if phase == .rest, appModel.activeWorkout == nil || appModel.activeWorkoutIsLeftover {
                        startButton
                            .padding(.top, MyoTheme.Spacing.lg)
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { stageSize = geo.size }
                    .onChange(of: geo.size) { _, size in stageSize = size }
            }
        }
        .coordinateSpace(name: Self.space)
        .animation(MyoTheme.Motion.fade, value: showTodayCard)
        .animation(.easeInOut(duration: 0.35), value: workoutExpanded)
        .animation(MyoTheme.Motion.fade, value: appModel.pendingBaselineSuggestions.isEmpty)
        .animation(.easeInOut(duration: 0.35), value: appModel.activeWorkout?.sessionId)
        .onChange(of: askedForWorkout) { _, _ in askedForWorkoutCard() }
        .onPreferenceChange(OrbSlotKey.self) { orbSlot = $0 }
        .animation(MyoTheme.Motion.fade, value: appModel.pendingPlanAdjustmentProposal?.id)
        .onAppear {
            voiceInput.onPause = { text in
                if voice.isSpeaking {
                    voiceInput.listen()
                    return
                }
                handleUtterance(text)
            }
            voice.fetchAudio = { [appModel] text in try await appModel.synthesizeSpeech(text) }
            lastCueCheckedReplyId = lastCoachMessage?.id
            #if DEBUG
            // MYO_BODY_MOVE=pushups|plank: start a move on launch, to tune
            // the choreography without a conversation.
            if let raw = ProcessInfo.processInfo.environment["MYO_BODY_MOVE"],
               let move = BodyMove(rawValue: raw) {
                director.perform(move)
            }
            #endif
        }
        .onDisappear {
            voiceInput.stop()
            voice.stop()
        }
        .onChange(of: appModel.messages) { _, messages in
            speakReplyIfReady(messages)
            performMoveIfCoachNamedOne()
        }
        // A reply that never lands (backend down, app backgrounded) must not
        // leave the body thinking forever.
        .task(id: awaitingReplyAfter) {
            guard awaitingReplyAfter != nil else { return }
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            if !Task.isCancelled {
                awaitingReplyAfter = nil
                resumeListening()
            }
        }
        .onChange(of: appModel.isSending) { _, sending in
            // The send itself failed — nothing is coming back to read.
            // A failed send ends the conversation — looping on an error helps no one.
            if !sending, appModel.errorMessage != nil {
                awaitingReplyAfter = nil
                endConversation()
            }
        }
        // Coach finished speaking: your turn again.
        // The body acts out each line of a lesson as it's spoken.
        .onChange(of: voice.lineIndex) { _, line in actOutLesson(line: line) }
        // Finished an exercise: introduce the next one.
        .onChange(of: currentExerciseIndex) { previous, next in
            guard previous != nil, let next, appModel.activeWorkout != nil else { return }
            // Let "set three done" finish first.
            Task {
                for _ in 0..<40 where voice.isSpeaking { try? await Task.sleep(nanoseconds: 200_000_000) }
                guard currentExerciseIndex == next else { return }
                introduce(exercise: next, first: false)
            }
        }
        // The workout ended: the mic goes off with it.
        .onChange(of: appModel.activeWorkout == nil) { _, ended in
            guard ended else { return }
            endLesson()
            if !appModel.pendingSessionChanges.isEmpty, conversationActive {
                // Ask out loud too; "yes" / "just today" answers it.
                let line = (tone == .hype ? "Great work! " : "Nice work. ")
                    + "You changed a few things today. Want to keep them for next time?"
                askedAt = Date()
                if speaksReplies, tips != .quiet {
                    voice.speak(line, messageId: "local-\(UUID().uuidString)")
                } else {
                    resumeListening()
                }
            } else {
                endConversation()
            }
        }
        .onChange(of: voice.isSpeaking) { _, speaking in
            if !speaking { voiceStoppedAt = Date() }
            if !speaking, let plan = lessonPlan {
                // Let the last "like this" reps finish, then hand back.
                Task {
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    if lessonPlan?.id == plan.id, !voice.isSpeaking { endLesson() }
                }
            }
            guard !speaking else { return }
            // Coach finished on its own: whatever the open mic caught under
            // it was echo or noise — start your turn clean. If you cut in,
            // keep what you're saying.
            if !cutIn, voiceInput.isListening {
                restartHandledLocally = true
                voiceInput.stop()
            }
            cutIn = false
            resumeListening()
        }
        // Listening stopped without a send (the recognizer timed out on
        // silence): pick back up, unless it stopped on an error.
        // Counting reps out loud: the count updates as you say each number.
        .onChange(of: voiceInput.transcript) { _, transcript in
            // Only with echo cancellation on: without it the mic would hear
            // Coach and Coach would cut itself off.
            if voice.isSpeaking, conversationActive, AudioHub.shared.echoCancelling,
               transcript.split(separator: " ").count >= 2 {
                // You started talking: Coach stops and listens.
                cutIn = true
                voice.stop()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            trackReps(in: transcript)
        }
        .onChange(of: voiceInput.isListening) { _, listening in
            if !listening, restartHandledLocally { restartHandledLocally = false; return }
            guard !listening, conversationActive, awaitingReplyAfter == nil, !voice.isSpeaking else { return }
            let now = Date()
            silentRestarts = silentRestarts.filter { now.timeIntervalSince($0) < 10 } + [now]
            if voiceInput.errorMessage != nil {
                endConversation()
            } else if silentRestarts.count >= 3 {
                // Mid-workout the mic stays on — quiet is normal between
                // sets — just back off a moment before listening again.
                // Outside one, a run of silence ends the conversation.
                if appModel.activeWorkout != nil {
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        resumeListening()
                    }
                } else {
                    endConversation()
                }
            } else {
                resumeListening()
            }
        }
    }

    // MARK: - Caption

    @ViewBuilder
    private var caption: some View {
        VStack(spacing: MyoTheme.Spacing.sm) {
            // During a move the status line narrates it ("2 / 3 · Push away").
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                Text(director.label ?? statusLine)
                    .myoStyle(.label)
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(phase == .listening ? MyoColor.redPen : MyoColor.Text.tertiary.color)
                    .contentTransition(.opacity)
            }

            if let proposal = appModel.pendingPlanAdjustmentProposal {
                PlanReviewCard(proposal: proposal)
                    .padding(.horizontal, -MyoTheme.Spacing.sm)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                captionText
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var captionText: some View {
        switch phase {
        case .listening where repCount > 0 && countingExercise != nil:
            let exercise = countingExercise!
            VStack(spacing: 2) {
                Text("\(repCount)")
                    .font(.system(size: 64, weight: .semibold, design: .monospaced))
                    .foregroundStyle(repCount > exercise.targetReps ? MyoTheme.Colors.coachAmber : MyoColor.Text.primary.color)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.15), value: repCount)
                Text(repCount > exercise.targetReps
                     ? "\(repCount - exercise.targetReps) past \(exercise.targetReps)"
                     : "of \(exercise.targetReps) · \(exercise.name)")
                    .myoStyle(.label)
                    .textCase(.uppercase)
                    .foregroundStyle(MyoColor.Text.tertiary.color)
            }
            .frame(minHeight: 88, alignment: .top)
        case .listening:
            Text(voiceInput.transcript.isEmpty ? " " : voiceInput.transcript)
                .myoStyle(.title)
                .foregroundStyle(MyoColor.Text.primary.color)
                .multilineTextAlignment(.center)
                .lineLimit(5)
                .frame(minHeight: 88, alignment: .top)
        case .thinking:
            Text(lastSpokenText.isEmpty ? " " : "\u{201C}\(lastSpokenText)\u{201D}")
                .myoStyle(.body)
                .foregroundStyle(MyoColor.Text.tertiary.color)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(minHeight: 88, alignment: .top)
        case .speaking:
            // A subtitle: only the sentence being said, gone when it's done.
            // The whole reply lives in Conversation.
            Text(voice.caption.isEmpty ? " " : voice.caption)
                .myoStyle(.title)
                .foregroundStyle(MyoColor.Text.primary.color)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(minHeight: 88, alignment: .top)
                .id(voice.caption)
                .transition(.opacity)
        case .rest:
            if !speaksReplies, let message = lastCoachMessage {
                // Muted: text is the only way the reply reaches you.
                ScrollView {
                    Text(message.content)
                        .myoStyle(.body)
                        .foregroundStyle(MyoColor.Text.primary.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
            } else if lastCoachMessage == nil {
                Text("Tell Coach how training's going, ask about today's session, or say what hurts.")
                    .myoStyle(.body)
                    .foregroundStyle(MyoColor.Text.secondary.color)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 88, alignment: .top)
            } else {
                Color.clear.frame(height: 4)
            }
        }
    }

    // MARK: - Controls

    // MARK: - Quick taps

    /// Ways to talk to MYO, as one-tap actions. Tap and it starts.
    private var quickTaps: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                quickTap("I missed a few workouts", systemImage: "arrow.uturn.backward") {
                    talk("I missed a few workouts.")
                }
                if appModel.activeWorkout == nil {
                    quickTap("Today's workout", systemImage: "list.bullet") { showTodayCard = true }
                }
                quickTap("Adjust my workout", systemImage: "slider.horizontal.3") {
                    talk("I need to adjust my workout.")
                }
            }
            .padding(.trailing, MyoTheme.Spacing.lg)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    /// Says it for you, then keeps listening so you can answer out loud.
    private func talk(_ line: String) {
        conversationActive = true
        silentRestarts = []
        send(line, spoken: true)
    }

    /// The one big action, right under the coach: jump into today's session.
    private var startButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            beginWorkout()
        } label: {
            HStack(spacing: MyoTheme.Spacing.sm) {
                if appModel.isWorkoutBusy {
                    ProgressView().tint(MyoTheme.Colors.ink)
                } else {
                    Image(systemName: "play.fill").font(.footnote.weight(.bold))
                }
                Text("Start my workout").font(.body.weight(.semibold))
            }
            .foregroundStyle(MyoTheme.Colors.ink)
            .padding(.horizontal, 28)
            .frame(height: 54)
            .contentShape(Capsule())
            .myoGlass(tint: MyoTheme.Colors.coachAmber.opacity(0.3))
            // Warm colour behind the glass for it to bend and blur.
            .background {
                Capsule()
                    .fill(LinearGradient(colors: [MyoTheme.Colors.coachAmber, MyoTheme.Colors.ochreLight.opacity(0.6)],
                                         startPoint: .leading, endPoint: .trailing))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 6)
                    .blur(radius: 14)
                    .opacity(0.75)
            }
            .shadow(color: MyoTheme.Colors.coachAmber.opacity(0.4), radius: 22, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(appModel.isWorkoutBusy)
    }

    private func quickTap(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(MyoTheme.Colors.coachAmber)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(MyoColor.Text.primary.color)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .contentShape(Capsule())
            .myoGlass()
        }
        .buttonStyle(.plain)
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: MyoTheme.Spacing.sm) {
            sideButton(systemImage: "keyboard", label: "Type instead") {
                endConversation()
                showKeyboard = true
            }
            // Scrolled pills slide under the keyboard's glass, not over it.
            .zIndex(1)
            micButton.zIndex(1)
            if phase == .rest {
                quickTaps.transition(.opacity)
            } else {
                Spacer()
            }
        }
    }

    /// The mic, on or off at a glance. On means hands-free: MYO listens
    /// until you turn it off (it stays on through a workout).
    private var micButton: some View {
        let on = conversationActive
        return Button {
            talkTapped(fromMic: true)
        } label: {
            Image(systemName: on ? "mic.fill" : "mic.slash")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(on ? MyoTheme.Colors.ink : MyoColor.Text.secondary.color)
                .symbolEffect(.pulse, isActive: on && phase == .listening)
                .frame(width: 52, height: 52)
                .contentShape(Circle())
                .myoGlass(tint: on ? MyoTheme.Colors.coachAmber.opacity(0.45) : nil, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Mic on" : "Mic off")
        .accessibilityHint(on ? "Turns the mic off" : "Turns the mic on so you can talk to MYO")
    }

    private func sideButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(MyoColor.Text.secondary.color)
                .frame(width: 52, height: 52)
                .contentShape(Circle())
                .myoGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var statusLine: String {
        switch phase {
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Coach"
        case .rest: return conversationActive ? " " : "Tap to talk"
        }
    }

    private var hint: String {
        switch phase {
        case .rest where !conversationActive: return "Tap to start talking with Coach."
        default: return "Tap to end the conversation."
        }
    }

    // MARK: - Turn handling

    /// One tap starts a hands-free conversation; any tap ends it — while
    /// you're talking, while Coach thinks, or while Coach speaks.
    private func talkTapped(fromMic: Bool = false) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if conversationActive, phase == .speaking, !fromMic {
            cutIn = true
            voice.stop()
            voiceInput.listen()
        } else if conversationActive {
            endConversation()
        } else {
            conversationActive = true
            silentRestarts = []
            voice.stop()
            director.rest()
            voiceInput.toggle()
        }
    }

    // MARK: - Workout voice

    private var currentExerciseIndex: Int? {
        appModel.currentExerciseIndex
    }

    private var currentExercise: ActiveWorkoutExercise? {
        currentExerciseIndex.flatMap { appModel.activeWorkout?.exercises[$0] }
    }

    /// The exercise being counted: the one whose set this count closed, or
    /// the current one.
    private var countingExercise: ActiveWorkoutExercise? {
        (countedSet?.exercise ?? currentExerciseIndex).flatMap { appModel.activeWorkout?.exercises[$0] }
    }

    /// Every finished utterance comes here. Mid-workout, counting and weight
    /// changes are handled on the phone; everything else goes to Coach.
    private func handleUtterance(_ heard: String) {
        // "MYO, add curls" → "add curls". Mid-workout, saying MYO's name is
        // what sends a free-form question to the coach.
        let addressed = Self.addressesCoach(heard)
        let text = addressed ? Self.strippingAddress(heard) : heard
        if applyStyleChange(in: text) { return }
        if !appModel.pendingSessionChanges.isEmpty, let keep = Self.yesOrNo(text) {
            if keep {
                confirm("Done. I'll send it over to update your plan.")
                Task { await appModel.keepSessionChanges() }
            } else {
                appModel.dismissSessionChanges()
                confirm("Just today, then.")
            }
            return
        }
        // A long run of words with no pause is music or a conversation
        // nearby, not a command.
        let short = text.split(separator: " ").count <= 14
        if let workout = appModel.activeWorkout, repCount == 0, short,
           let edit = WorkoutEdit.parse(text, exercises: workout.exercises, current: currentExerciseIndex) {
            apply(edit)
            return
        }
        if appModel.activeWorkout != nil, repCount == 0, CoachingStyle.asksForDemo(text),
           let index = currentExerciseIndex {
            introduce(exercise: index, first: false, teach: true)
            return
        }
        if appModel.activeWorkout != nil {
            if repCount > 0 {
                // A pause mid-count isn't the end of the set — keep going.
                restartHandledLocally = true
                resumeListening()
                return
            } else if short, let logged = WorkoutVoice.setsLogged(in: text), let index = currentExerciseIndex,
                      let exercise = currentExercise {
                // You didn't count — "set done", "two sets done".
                let left = exercise.targetSets - exercise.completedSetCount
                let count = min(logged.sets ?? left, left)
                var last: Int?
                for _ in 0..<count {
                    last = appModel.completeNextSet(exerciseIndex: index, reps: logged.reps ?? exercise.targetReps)
                }
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                let head = count == 1 ? "Set \(last ?? 1) done." : "\(count) sets logged."
                confirm(setDoneLine(head, exerciseIndex: index))
                return
            } else if short, let change = WorkoutVoice.weightChange(in: text), let index = currentExerciseIndex,
                      let exercise = currentExercise {
                let now = appModel.workingWeight(for: exercise)
                let next: Double
                switch change {
                case .to(let pounds): next = pounds
                case .by(let delta): next = now + delta
                }
                appModel.setWorkoutExerciseWeight(exerciseIndex: index, weight: next)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                confirm("\(Self.short(exercise.name)) at \(LiveWorkoutCard.pounds(max(0, next))) pounds.")
                return
            }
            // Mid-workout the mic hears the whole gym — music, other people.
            // Only what's said to MYO (or an answer to its question) goes to
            // the coach; everything else is ignored.
            let justAsked = askedAt.map { Date().timeIntervalSince($0) < 12 } ?? false
            guard addressed || justAsked else {
                restartHandledLocally = true
                resumeListening()
                return
            }
        }
        askedAt = nil
        send(text, spoken: true)
    }

    private static let addressPattern = #"^\W*(hey |hi |ok |okay |yo )?(myo|my o|my oh|mayo|mio|meo|miyo|coach)\b[\s,.!?]*"#

    /// Starts with MYO's name (as the recognizer tends to hear it) or "coach".
    private static func addressesCoach(_ text: String) -> Bool {
        text.lowercased().range(of: addressPattern, options: .regularExpression) != nil
    }

    private static func strippingAddress(_ text: String) -> String {
        let lower = text.lowercased()
        guard let range = lower.range(of: addressPattern, options: .regularExpression) else { return text }
        let cut = lower.distance(from: lower.startIndex, to: range.upperBound)
        return String(text.dropFirst(cut)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Live: each number you say moves the count, carrying across pauses.
    /// Reaching the target logs the set; counting on raises its reps.
    private func trackReps(in transcript: String) {
        guard appModel.activeWorkout != nil else { return }
        // A fresh transcript (the recognizer restarted): continue from here.
        if transcript.isEmpty { countBase = repCount; return }
        guard voiceInput.isListening,
              let index = countedSet?.exercise ?? currentExerciseIndex,
              let exercise = appModel.activeWorkout?.exercises[index] else { return }

        if repCount > 0, WorkoutVoice.saysSetDone(transcript) {
            finishCount()
            return
        }
        // "Add curls, 3 by 12" isn't counting, even though "12" reads as 1, 2.
        guard WorkoutVoice.looksLikeCounting(transcript) else { return }
        let count = WorkoutVoice.repCount(in: transcript, from: countBase)
        guard count > repCount else { return }
        repCount = count
        voiceInput.holdOpen = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let done = countedSet {
            appModel.updateSetReps(exerciseIndex: done.exercise, setNumber: done.set, reps: count)
        } else if count >= exercise.targetReps,
                  let set = appModel.completeNextSet(exerciseIndex: index, reps: count) {
            countedSet = (index, set)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
        // Quiet for a while → the set's over. Short once you've hit the
        // target (you might push a couple more); long if you're short of
        // it (slow tempo, or catching your breath mid-set).
        closeCountTask?.cancel()
        let wait: UInt64 = countedSet != nil ? 4 : 12
        closeCountTask = Task {
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            if !Task.isCancelled { finishCount() }
        }
    }

    /// The count is over: the set is logged with the reps actually done —
    /// fewer, exact, or more than the target — and Coach says so briefly.
    /// A stray "one" or "two" that never became a set is dropped.
    private func finishCount() {
        closeCountTask?.cancel()
        closeCountTask = nil
        let finalCount = repCount
        let alreadyLogged = countedSet
        let countedIndex = alreadyLogged?.exercise ?? currentExerciseIndex
        repCount = 0
        countBase = 0
        countedSet = nil
        voiceInput.holdOpen = false
        guard finalCount > 0 else { return }

        let target: Int
        let setNumber: Int
        if let done = alreadyLogged {
            appModel.updateSetReps(exerciseIndex: done.exercise, setNumber: done.set, reps: finalCount)
            target = appModel.activeWorkout?.exercises[done.exercise].targetReps ?? finalCount
            setNumber = done.set
        } else if finalCount >= 3, let index = currentExerciseIndex,
                  let set = appModel.completeNextSet(exerciseIndex: index, reps: finalCount) {
            target = appModel.activeWorkout?.exercises[index].targetReps ?? finalCount
            setNumber = set
        } else {
            return
        }
        let head: String
        if finalCount > target {
            head = "Set \(setNumber) done. \(finalCount) reps, \(finalCount - target) over."
        } else if finalCount < target {
            head = "Set \(setNumber), \(finalCount) reps."
        } else {
            head = "Set \(setNumber) done."
        }
        let line = setDoneLine(head, exerciseIndex: countedIndex)
        // Clear the counted words before Coach speaks, so they don't carry
        // into the next utterance.
        restartHandledLocally = true
        voiceInput.stop()
        confirm(line)
    }

    /// A lift you called out: add, swap, skip, jump, new sets or reps, or
    /// finish. Says what changed in a few words.
    private func apply(_ edit: WorkoutEdit) {
        guard let workout = appModel.activeWorkout else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        switch edit {
        case .add(let name, let sets, let reps, let weight, let now):
            let s = sets ?? 3, r = reps ?? 10
            guard let index = appModel.addWorkoutExercise(name: name, sets: s, reps: r, weight: weight ?? 0) else { return }
            if now {
                appModel.focusExercise(index)
                confirm("Added \(name). Let's do it now.")
            } else {
                confirm("Added \(name), \(s) sets of \(r).")
            }
        case .swap(let index, let name):
            let old = workout.exercises[index].name
            let wasCurrent = index == currentExerciseIndex
            let swapped = appModel.swapWorkoutExercise(index, to: name, weight: 0)
            if swapped != index, wasCurrent {
                // Sets were done on the old lift; the new one is now current
                // and gets introduced (see onChange).
                resumeListening()
            } else if swapped == index, wasCurrent {
                introduce(exercise: index, first: false)
            } else {
                confirm("Swapped \(Self.short(old)) for \(name).")
            }
        case .skip(let index):
            let name = workout.exercises[index].name
            appModel.skipWorkoutExercise(index)
            confirm("Skipping \(Self.short(name)) today.")
        case .jump(let index):
            // Changing the current lift introduces it (see onChange).
            appModel.focusExercise(index)
            resumeListening()
        case .targets(let index, let sets, let reps):
            appModel.setWorkoutTargets(index, sets: sets, reps: reps)
            if let updated = appModel.activeWorkout?.exercises[index] {
                confirm("\(Self.short(updated.name)): \(updated.targetSets) sets of \(updated.targetReps).")
            }
        case .finish:
            confirm(tone == .hype ? "Let's wrap it up!" : "Wrapping up.")
            Task { await appModel.finishActiveWorkout() }
        }
    }

    /// "Yeah", "keep them" → true; "no", "just today" → false.
    private static func yesOrNo(_ text: String) -> Bool? {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        guard t.split(separator: " ").count <= 8 else { return nil }
        if t.range(of: #"\b(no|nope|nah|just today|don't|do not|not now|skip it|forget it)\b"#, options: .regularExpression) != nil {
            return false
        }
        if t.range(of: #"\b(yes|yeah|yep|sure|keep|save|definitely|of course|do it|sounds good)\b"#, options: .regularExpression) != nil {
            return true
        }
        return nil
    }

    /// After a set: the fact, a word in your tone, and — with tips on and
    /// sets left on this lift — one cue for the next.
    private func setDoneLine(_ head: String, exerciseIndex: Int?) -> String {
        var line = head
        if tips != .quiet { line += " " + CoachingStyle.praise(tone) }
        if tips == .full, let index = exerciseIndex, let exercise = appModel.activeWorkout?.exercises[index],
           exercise.completedSetCount < exercise.targetSets,
           let lift = ExerciseMotion.match(exercise.name)?.lift {
            line += " Next one: " + ExerciseLesson.cue(for: lift).lowercased()
        }
        return line
    }

    /// A short spoken acknowledgement, then straight back to listening.
    private func confirm(_ line: String) {
        restartHandledLocally = true
        if tips == .quiet {
            // Quiet: a buzz says it was heard.
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            resumeListening()
        } else if speaksReplies {
            voice.speak(line, messageId: "local-\(UUID().uuidString)")
        } else {
            resumeListening()
        }
    }

    private static func short(_ name: String) -> String {
        name.replacingOccurrences(of: "Barbell ", with: "").replacingOccurrences(of: "Dumbbell ", with: "")
    }

    /// Mid-workout, asking for it opens the live card; otherwise today's plan.
    private func askedForWorkoutCard() {
        if appModel.activeWorkout != nil {
            workoutExpanded = true
        } else {
            showTodayCard = true
        }
    }

    /// The plan card drops down into the minimized live bar; the coach keeps
    /// its place and can keep talking.
    private func beginWorkout() {
        Task {
            if appModel.activeWorkoutIsLeftover { await appModel.discardActiveWorkout() }
            if appModel.activeWorkout == nil { await appModel.startTodaysWorkout() }
            guard appModel.activeWorkout != nil else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            workoutExpanded = false
            showTodayCard = false
            // Hands-free from here: the mic stays on so you can count out
            // loud, and Coach walks you into the first lift.
            if !conversationActive {
                conversationActive = true
                silentRestarts = []
                director.rest()
            }
            if let first = currentExerciseIndex { introduce(exercise: first, first: true) }
        }
    }

    // MARK: - Teaching

    struct LessonPlan {
        let id: String
        let motion: ExerciseMotion?
        /// What the body does on each spoken line.
        let cues: [ExerciseLesson.BodyCue]
    }

    /// Names the lift and — with tips on — teaches it, the body stepping
    /// into each position as it's described. `teach` forces the walk-through
    /// (you asked to be shown).
    private func introduce(exercise index: Int, first: Bool, teach: Bool = false) {
        guard let workout = appModel.activeWorkout, workout.exercises.indices.contains(index) else { return }
        let exercise = workout.exercises[index]
        let motion = ExerciseMotion.match(exercise.name)
        let style = teach ? CoachingStyle.Tips.full : tips
        guard style != .quiet else {
            resumeListening()
            return
        }
        var lines: [String] = []
        var cues: [ExerciseLesson.BodyCue] = []
        if !teach {
            let weight = appModel.workingWeight(for: exercise)
            let load = weight > 0 ? " at \(LiveWorkoutCard.pounds(weight))" : ""
            let lead = first ? (tone == .hype ? "Let's go! First up" : "First up") : "Next up"
            lines.append("\(lead), \(exercise.name). \(exercise.targetSets) sets of \(exercise.targetReps)\(load).")
            cues.append(.hold(0))
        }
        if style == .full, let motion {
            for beat in ExerciseLesson.beats(for: motion.lift) {
                lines.append(beat.line)
                cues.append(beat.body)
            }
        }
        if first {
            lines.append("Count your reps out loud. I'll keep track.")
            cues.append(.reps)
        }
        let plan = LessonPlan(id: "lesson-\(UUID().uuidString)", motion: motion, cues: cues)
        lessonPlan = plan
        actOutLesson(line: 0)
        if voiceInput.isListening {
            restartHandledLocally = true
            voiceInput.stop()
        }
        if speaksReplies {
            voice.speak(lines: lines, messageId: plan.id)
            try? AudioHub.shared.start()
            if AudioHub.shared.echoCancelling { voiceInput.listen() }
        } else {
            // Muted: the body still walks through it, a beat every few seconds.
            Task {
                for line in cues.indices.dropFirst() {
                    try? await Task.sleep(nanoseconds: 2_800_000_000)
                    guard lessonPlan?.id == plan.id else { return }
                    actOutLesson(line: line, force: true)
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if lessonPlan?.id == plan.id { endLesson() }
            }
            resumeListening()
        }
    }

    /// Moves the body to the beat for this spoken line.
    private func actOutLesson(line: Int, force: Bool = false) {
        guard let plan = lessonPlan, let motion = plan.motion, plan.cues.indices.contains(line) else { return }
        guard force || line == 0 || voice.speakingMessageId == plan.id else { return }
        let from: Float
        if let current = lessonCue, case .hold(let depth) = current.body { from = depth } else { from = 0 }
        lessonCue = LessonCue(motion: motion, body: plan.cues[line], from: from, startedAt: CACurrentMediaTime())
    }

    private func endLesson() {
        lessonPlan = nil
        lessonCue = nil
    }

    /// "Stop talking", "no tips", "coach me", "calm down", "hype me up":
    /// Coach changes how it talks, says so in a word (or not at all), and
    /// keeps listening. True when that's all you said.
    private func applyStyleChange(in text: String) -> Bool {
        let justSpoke = voice.isSpeaking || cutIn
            || (voiceStoppedAt.map { Date().timeIntervalSince($0) < 5 } ?? false)
        guard let change = CoachingStyle.change(in: text, coachJustSpoke: justSpoke) else { return false }
        switch change {
        case .hush:
            endLesson()
        case .tips(let level):
            tipsSetting = level.rawValue
            if level != .full { endLesson() }
        case .tone(let mood):
            toneSetting = mood.rawValue
        }
        voice.stop()
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        if let ack = CoachingStyle.acknowledgement(change), speaksReplies {
            restartHandledLocally = true
            voice.speak(ack, messageId: "local-\(UUID().uuidString)")
        } else {
            resumeListening()
        }
        return true
    }

    private func endConversation() {
        closeCountTask?.cancel()
        closeCountTask = nil
        repCount = 0
        countBase = 0
        countedSet = nil
        voiceInput.holdOpen = false
        conversationActive = false
        awaitingReplyAfter = nil
        voiceInput.stop()
        voice.stop()
        AudioHub.shared.stop()
    }

    /// Back to listening for the next thing you say, after a short breath so
    /// the end of Coach's voice isn't caught by the mic.
    private func resumeListening() {
        guard conversationActive else { return }
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard conversationActive, !voiceInput.isListening, !voice.isSpeaking,
                  awaitingReplyAfter == nil else { return }
            voiceInput.toggle()
        }
    }

    private func send(_ text: String, spoken: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !spoken, applyStyleChange(in: trimmed) { return }
        lastSpokenText = trimmed
        // Asked for today's workout: show it as a card, not a recited list.
        if WorkoutAsk.matches(trimmed) { askedForWorkoutCard() }
        // You named a move: the body steps into it while Coach answers.
        if let move = MoveCue.move(in: trimmed) { director.perform(move) }
        if spoken, conversationActive {
            awaitingReplyAfter = Set(appModel.messages.map(\.id))
        }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        Task { await appModel.sendCoachMessage(trimmed, spoken: spoken) }
    }

    /// Coach named a move in a new reply: step into it. Once per reply, and
    /// never for a move already playing (yours from this turn, say).
    private func performMoveIfCoachNamedOne() {
        guard let reply = lastCoachMessage, reply.id != lastCueCheckedReplyId,
              [.complete, .blocked].contains(reply.status) else { return }
        lastCueCheckedReplyId = reply.id
        if let move = MoveCue.move(in: reply.content) { director.perform(move) }
    }

    private func speakReplyIfReady(_ messages: [CoachMessage]) {
        guard let known = awaitingReplyAfter else { return }
        let finished: Set<CoachMessage.Status> = [.complete, .blocked, .error]
        guard let reply = messages.last(where: {
            $0.role == .coach && !known.contains($0.id) && finished.contains($0.status) && !$0.content.isEmpty
        }) else { return }
        awaitingReplyAfter = nil
        guard conversationActive, !voiceInput.isListening else { return }
        if reply.content.contains("?") { askedAt = Date() }
        if speaksReplies {
            voice.speak(reply.content, messageId: reply.id)
            // Keep the mic open under Coach only where its voice is cancelled
            // from the mic; elsewhere listening resumes when Coach finishes.
            try? AudioHub.shared.start()
            if AudioHub.shared.echoCancelling { voiceInput.listen() }
        } else {
            // Muted: the reply is on screen; go straight back to listening.
            resumeListening()
        }
    }
}

private struct OrbSlotKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}
