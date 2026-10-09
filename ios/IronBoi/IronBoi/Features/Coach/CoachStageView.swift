import AVFoundation
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
    /// The latest typed message — handled exactly like the same words said
    /// out loud (set logging, workout changes, rest day, style…).
    var typed: TypedLine? = nil
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
    /// The "noisy? turn on Voice Isolation" tip, shown the first couple of
    /// workouts unless it's already on.
    @State private var showIsolationTip = false
    /// "Skip your rest day?" — asked on screen, and out loud when it was
    /// asked for out loud.
    @State private var askingSkipRestDay = false
    /// Start is swapping out a stale session; that's not the workout ending.
    @State private var restartingWorkout = false
    /// A short on-screen note under the coach ("Your workout's ready…"),
    /// for when it isn't spoken, or as well as.
    @State private var notice: String?
    /// The message being handled was typed, not said.
    @State private var typedTurn = false
    /// Message ids that existed when a typed message went out; the first new
    /// finished coach message after that is the reply to show as text.
    @State private var typedReplyAfter: Set<String>?
    /// A typed-to reply, written out under the coach until you move on.
    @State private var textReply: CoachMessage?
    /// When it started writing out, so it doesn't re-type when redrawn.
    @State private var textReplyShownAt = Date()
    /// When the open question (swap offer, rest day) was put to you; spoken
    /// answers only count for a little while after. Taps always do.
    @State private var questionAskedAt: Date?
    /// "Swap the bench": alternatives on offer for one lift.
    @State private var swapChoice: SwapChoice?

    struct SwapChoice {
        let index: Int
        let from: String
        let options: [ExerciseSwapOption]
    }
    @AppStorage("voiceIsolationTipsShown") private var isolationTipsShown = 0
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
    @State private var restartMarks = 0
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
        swapChoice != nil || !appModel.pendingSessionChanges.isEmpty || !appModel.pendingBaselineSuggestions.isEmpty || (showTodayCard && appModel.activeWorkout == nil) || (appModel.activeWorkout != nil && workoutExpanded)
    }
    /// The newest coach reply already checked for a move, so history
    /// loading on launch never sets the body off.
    @State private var lastCueCheckedReplyId: String?

    private var phase: OrbPhase {
        if voice.isSpeaking { return .speaking }
        if voiceInput.isListening { return .listening }
        if appModel.isSending || awaitingReplyAfter != nil || typedReplyAfter != nil
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
        stage
        #if DEBUG
        .overlay(alignment: .topTrailing) {
            if ProcessInfo.processInfo.environment["MYO_TUNER"] == "1" { OrbPhysicsTuner() }
        }
        #endif
        .coordinateSpace(name: Self.space)
        .animation(MyoTheme.Motion.fade, value: showTodayCard)
        .animation(.easeInOut(duration: 0.35), value: workoutExpanded)
        .animation(MyoTheme.Motion.fade, value: appModel.pendingBaselineSuggestions.isEmpty)
        .animation(.easeInOut(duration: 0.35), value: appModel.activeWorkout?.sessionId)
        .onChange(of: askedForWorkout) { _, _ in askedForWorkoutCard() }
        .onPreferenceChange(OrbSlotKey.self) { orbSlot = $0 }
        .animation(MyoTheme.Motion.fade, value: askingSkipRestDay)
        .animation(MyoTheme.Motion.fade, value: appModel.pendingPlanAdjustmentProposal?.id)
        .onAppear {
            voiceInput.onPause = { text in
                if voice.isSpeaking {
                    if conversationActive { voiceInput.listen() }
                    return
                }
                handleUtterance(text)
            }
            voice.fetchAudio = { [appModel] text in try await appModel.synthesizeSpeech(text) }
            voiceInput.onFailure = { endConversation() }
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
        .onDisappear { endConversation() }
        // Audio was rebuilt (AirPods in/out, a call ended): listen again so
        // the mic matches the new route.
        .onReceive(NotificationCenter.default.publisher(for: AudioHub.resetNotification)) { _ in
            guard conversationActive, voiceInput.isListening else { return }
            markRestartHandled()
            voiceInput.stop()
            resumeListening()
        }
        .onChange(of: appModel.messages) { _, messages in
            showTypedReplyIfReady(messages)
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
        // Same for a typed message: never think forever.
        .task(id: typedReplyAfter) {
            guard typedReplyAfter != nil else { return }
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            if !Task.isCancelled { typedReplyAfter = nil }
        }
        .onChange(of: appModel.isSending) { _, sending in
            if !sending, appModel.errorMessage != nil { typedReplyAfter = nil }
            // The send itself failed — nothing is coming back to read.
            // A failed send ends the conversation — looping on an error helps no one.
            if !sending, appModel.errorMessage != nil {
                awaitingReplyAfter = nil
                endConversation()
            }
        }
        // Coach finished speaking: your turn again.
        .onChange(of: typed) { _, line in if let line { handleTyped(line.text) } }
        // The body acts out each line of a lesson as it's spoken.
        .onChange(of: voice.lineIndex) { _, line in actOutLesson(line: line) }
        // Finished an exercise: introduce the next one.
        .onChange(of: currentExerciseIndex) { previous, next in exerciseChanged(from: previous, to: next) }
        // A plan change went through: say what to do next.
        .onChange(of: appModel.planChangesAccepted) { _, _ in planChangeAccepted() }
        // The workout ended: the mic goes off with it.
        .onChange(of: appModel.activeWorkout == nil) { _, ended in if ended, !restartingWorkout { workoutEnded() } }
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
                markRestartHandled()
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
            if voice.isSpeaking, conversationActive, AudioHub.shared.canTalkOver,
               !voice.speakingOnDevice, !Self.echoes(transcript, of: voice.caption),
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

    /// The body, the cards and the controls; `body` adds the behaviour.
    private var stage: some View {
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
                    // Only a tap on the coach itself — the empty space around
                    // it (where Start and cards sit) never turns the mic on.
                    .onTapGesture(coordinateSpace: .named(Self.space)) { location in
                        // While typing, a tap on the stage just puts the keyboard away.
                        if showKeyboard { showKeyboard = false } else if tapIsOnCoach(location) { talkTapped() }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Coach")
                    .accessibilityValue(statusLine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(hint)
                    .accessibilityAction { talkTapped() }

                if let choice = swapChoice {
                    swapCard(choice)
                        .padding(.horizontal, MyoTheme.Spacing.md)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if !appModel.pendingSessionChanges.isEmpty {
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
                        onBegin: { beginWorkout() }
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

                // While typing, the type bar takes this spot.
                controls
                    .padding(.leading, MyoTheme.Spacing.lg)
                    .padding(.top, MyoTheme.Spacing.md)
                    .padding(.bottom, MyoTheme.Spacing.sm)
                    .opacity(showKeyboard ? 0 : 1)
                    .allowsHitTesting(!showKeyboard)
            }
        }
        .overlay {
            if centered {
                // Pinned just under the body (radius ≈ 0.45 of half the short side).
                VStack(spacing: 0) {
                    Color.clear.frame(height: restFocus.y + stageSize.width * 0.225 + 36)
                    // The rest-day question replaces the caption, so the card
                    // never pushes down over the controls.
                    if !askingSkipRestDay {
                        caption.padding(.horizontal, MyoTheme.Spacing.lg)
                    }
                    // A leftover from an earlier day doesn't block today's start.
                    if askingSkipRestDay {
                        skipRestDayCard
                            .padding(.top, MyoTheme.Spacing.lg)
                            .padding(.horizontal, MyoTheme.Spacing.lg)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else if showsStartButton {
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
        case .rest where notice != nil, .listening where notice != nil && voiceInput.transcript.isEmpty:
            Text(notice ?? "")
                .myoStyle(.title)
                .foregroundStyle(MyoColor.Text.primary.color)
                .multilineTextAlignment(.center)
                .frame(minHeight: 88, alignment: .top)
                .transition(.opacity)
        case .listening:
            Text(voiceInput.transcript.isEmpty ? " " : voiceInput.transcript)
                .myoStyle(.title)
                .foregroundStyle(MyoColor.Text.primary.color)
                .multilineTextAlignment(.center)
                .lineLimit(5)
                .frame(minHeight: 88, alignment: .top)
        case .thinking:
            // What you said, so you know it was heard, and a pulse so you
            // know it's working on it.
            VStack(spacing: MyoTheme.Spacing.sm) {
                Text(lastSpokenText.isEmpty ? " " : "\u{201C}\(lastSpokenText)\u{201D}")
                    .myoStyle(.body)
                    .foregroundStyle(MyoColor.Text.secondary.color)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                ThinkingDots()
            }
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
        case .rest where textReply != nil:
            TypedReplyText(message: textReply!, shownAt: textReplyShownAt)
                .onTapGesture { withAnimation(MyoTheme.Motion.fade) { textReply = nil } }
                .accessibilityAction(named: "Dismiss") { textReply = nil }
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
                if let index = currentExerciseIndex {
                    // Mid-workout: the things you reach for between sets.
                    quickTap("Explain again", systemImage: "arrow.counterclockwise") {
                        introduce(exercise: index, first: false, replay: true)
                    }
                    quickTap("Set done", systemImage: "checkmark") { handleTyped("set done") }
                } else {
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

    /// The mic is hearing Coach's own sentence (a Bluetooth speaker, a car)
    /// rather than you: most of what it heard is in what Coach is saying.
    private static func echoes(_ heard: String, of spoken: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 2 }
        }
        let said = Set(words(spoken))
        let got = words(heard)
        guard !said.isEmpty, !got.isEmpty else { return false }
        return Double(got.filter(said.contains).count) / Double(got.count) >= 0.5
    }

    /// Within the coach's body (with a little slack), wherever it rests.
    private func tapIsOnCoach(_ location: CGPoint) -> Bool {
        let center = centered ? restFocus : orbSlot.map { CGPoint(x: $0.midX, y: $0.midY) } ?? restFocus
        let reach = max(80, min(stageSize.width, stageSize.height) * 0.32)
        return hypot(location.x - center.x, location.y - center.y) <= reach
    }

    /// Start shows while nothing's in progress — no workout, an old one,
    /// or an empty one — at rest or while listening.
    private var showsStartButton: Bool {
        guard phase == .rest || phase == .listening else { return false }
        if appModel.activeWorkout == nil || appModel.activeWorkoutIsLeftover { return true }
        return !appModel.activeWorkoutHasProgress && appModel.currentExerciseIndex == nil
    }

    /// Real alternatives for a lift (same muscles, the server's ranking),
    /// offered as a card and out loud; the body shows the first.
    private func offerSwaps(for index: Int) {
        guard let workout = appModel.activeWorkout, workout.exercises.indices.contains(index) else { return }
        let name = workout.exercises[index].name
        Task {
            let outcome = await appModel.fetchSwapOptions(
                exerciseName: name, dayKey: workout.dayKey, sessionId: workout.sessionId, availableEquipment: nil)
            guard case .loaded(let options) = outcome, !options.isEmpty else {
                confirm("I couldn't pull up swaps right now. Tell me what you'd like instead.")
                return
            }
            let top = Array(options.prefix(3))
            swapChoice = SwapChoice(index: index, from: name, options: top)
            questionAskedAt = Date()
            askedAt = Date()
            demo(top[0].name)
            let names = top.map(\.name)
            let list = names.count > 1
                ? names.dropLast().joined(separator: ", ") + ", or " + names.last!
                : names[0]
            confirm("Instead of \(Self.short(name)), how about \(list)?")
        }
    }

    private func chooseSwap(_ option: ExerciseSwapOption?) {
        guard let choice = swapChoice else { return }
        swapChoice = nil
        guard let option else {
            confirm("Keeping \(Self.short(choice.from)).")
            return
        }
        let wasCurrent = choice.index == currentExerciseIndex
        let swapped = appModel.swapWorkoutExercise(choice.index, to: option.name, weight: option.suggestedWeightLb)
        if wasCurrent, swapped == choice.index {
            introduce(exercise: choice.index, first: false)
        } else if !wasCurrent {
            confirm("Swapped \(Self.short(choice.from)) for \(option.name).")
        }
        // (Sets already done on the old lift: the new one is added and
        // becomes current, which introduces it.)
    }

    /// Which offered swap you meant: "the first one", "two", a name, "yes".
    private static func pickSwap(_ text: String, from options: [ExerciseSwapOption]) -> ExerciseSwapOption?? {
        let t = text.lowercased()
        func says(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }
        if says(#"\b(keep it|keep (the )?(original|same)|never ?mind|no thanks|nope|nah|cancel)\b"#) { return .some(nil) }
        // Ordinals, most specific first — "the second one" isn't "one".
        let bare = t.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let ordinals = [(2, #"\b(third|3rd|number three)\b"#, "three"), (1, #"\b(second|2nd|number two)\b"#, "two"),
                        (0, #"\b(first|1st|number one)\b"#, "one")]
        for (i, pattern, word) in ordinals where i < options.count && (says(pattern) || bare == word) { return options[i] }
        let words = Set(t.components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 3 })
        if let named = options.first(where: { option in
            !Set(option.name.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 3 })
                .isDisjoint(with: words)
        }) { return named }
        if says(#"\b(yes|yeah|yep|sure|ok|okay|sounds good|do it|let's do it)\b"#) { return options.first }
        return nil
    }

    /// The body shows a lift for a few reps — something just suggested.
    private func demo(_ name: String) {
        guard let motion = ExerciseMotion.match(name) else { return }
        let cue = LessonCue(motion: motion, body: .reps, from: 0, startedAt: CACurrentMediaTime())
        lessonCue = cue
        Task {
            try? await Task.sleep(nanoseconds: UInt64(motion.repDuration * 2.5 * 1_000_000_000))
            if lessonCue == cue, lessonPlan == nil { lessonCue = nil }
        }
    }

    /// Alternatives for a lift, tap one or say it.
    private func swapCard(_ choice: SwapChoice) -> some View {
        VStack(spacing: MyoTheme.Spacing.sm) {
            Text("Swap \(Self.short(choice.from)) for…")
                .font(.title3.weight(.bold))
                .foregroundStyle(MyoColor.Text.primary.color)
            ForEach(choice.options) { option in
                Button { chooseSwap(option) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.name).font(.body.weight(.semibold)).foregroundStyle(MyoColor.Text.primary.color)
                        Text(option.reason).font(.caption).foregroundStyle(MyoColor.Text.secondary.color).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MyoTheme.Spacing.md)
                    .padding(.vertical, 10)
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                    .myoGlass(in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { demo(option.name) })
            }
            Button("Keep \(Self.short(choice.from))") { chooseSwap(nil) }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MyoColor.Text.tertiary.color)
                .frame(minHeight: 40)
        }
        .padding(MyoTheme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .myoCard()
    }

    /// "Skip your rest day?" — right where Start was, two clear answers.
    private var skipRestDayCard: some View {
        VStack(spacing: MyoTheme.Spacing.md) {
            VStack(spacing: 4) {
                Text("Skip your rest day?")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(MyoColor.Text.primary.color)
                Text(appModel.nextPlannedDay.map { "You'd do \($0.name) today instead." }
                     ?? "Coach will put together a workout for today.")
                    .font(.subheadline)
                    .foregroundStyle(MyoColor.Text.secondary.color)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: MyoTheme.Spacing.sm) {
                Button { answerSkipRestDay(false) } label: {
                    Text("Not today")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(MyoColor.Text.secondary.color)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .contentShape(Capsule())
                        .myoGlass()
                }
                .buttonStyle(.plain)
                Button { answerSkipRestDay(true) } label: {
                    Text(appModel.nextPlannedDay.map { "Yes, do \($0.name)" } ?? "Yes, build one")
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(MyoTheme.Colors.ink)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .contentShape(Capsule())
                        .myoGlass(tint: MyoTheme.Colors.coachAmber.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(MyoTheme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .myoCard()
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
                    Image(systemName: appModel.isRestDay ? "moon.zzz.fill" : "play.fill").font(.footnote.weight(.bold))
                }
                Text(appModel.isRestDay ? "Rest day · train anyway?" : "Start my workout").font(.body.weight(.semibold))
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
            .frame(height: 44)
            .contentShape(Capsule())
            .myoGlass()
        }
        .buttonStyle(.plain)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
        if showIsolationTip {
            isolationTip.transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        HStack(alignment: .center, spacing: MyoTheme.Spacing.sm) {
            sideButton(systemImage: "keyboard", label: "Type instead") {
                endConversation()
                showKeyboard = true
            }
            // Scrolled pills slide under the keyboard's glass, not over it.
            .zIndex(1)
            micButton.zIndex(1)
            // Mid-workout the mic is usually open, so the pills stay up then too.
            if phase == .rest || (phase == .listening && currentExerciseIndex != nil) {
                quickTaps.transition(.opacity)
            } else {
                Spacer()
            }
        }
        }
        .animation(MyoTheme.Motion.fade, value: showIsolationTip)
    }

    /// iOS's Voice Isolation mic mode filters out everyone but you — kids,
    /// the gym, the music. Apps can't switch it on; this opens the system
    /// picker in one tap.
    private var isolationTip: some View {
        Button {
            showIsolationTip = false
            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.wave.2").font(.footnote.weight(.semibold))
                Text("Noisy around you? Turn on Voice Isolation")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(MyoTheme.Colors.ink)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .myoGlass(tint: MyoTheme.Colors.coachAmber.opacity(0.25))
        }
        .buttonStyle(.plain)
    }

    private func offerVoiceIsolation() {
        guard isolationTipsShown < 2, AVCaptureDevice.preferredMicrophoneMode != .voiceIsolation else { return }
        isolationTipsShown += 1
        showIsolationTip = true
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            showIsolationTip = false
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
        .contextMenu {
            Button("Voice Isolation…", systemImage: "person.wave.2") {
                AVCaptureDevice.showSystemUserInterface(.microphoneModes)
            }
            Divider()
            // Where audio is going right now — for telling us what happened.
            ForEach(AudioHub.shared.routeLines, id: \.self) { Text($0) }
        }
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
        textReply = nil
        AudioHub.log("talk tapped (mic button: \(fromMic))")
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
    /// Typed: same handling as spoken. It's plainly meant for MYO, so it
    /// never needs "MYO" in front, and replies show on screen.
    private func handleTyped(_ line: String) {
        typedTurn = true
        handleUtterance(line)
        typedTurn = false
    }

    private func handleUtterance(_ heard: String) {
        // "MYO, add curls" → "add curls". Mid-workout, saying MYO's name is
        // what sends a free-form question to the coach. Typing always is.
        let addressed = typedTurn || Self.addressesCoach(heard)
        let text = Self.addressesCoach(heard) ? Self.strippingAddress(heard) : heard
        if applyStyleChange(in: text) { return }
        if let choice = swapChoice, questionIsFresh, let pick = Self.pickSwap(text, from: choice.options) {
            chooseSwap(pick)
            return
        }
        if askingSkipRestDay, questionIsFresh, let yes = Self.skipRestDayAnswer(text) {
            answerSkipRestDay(yes)
            return
        }
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
        // "Start my workout" / "let's go" — unless it's an answer to
        // something Coach just asked.
        let justAskedSomething = askedAt.map { Date().timeIntervalSince($0) < 12 } ?? false
        if !justAskedSomething, !appModel.activeWorkoutHasProgress, currentExerciseIndex == nil || appModel.activeWorkout == nil,
           Self.asksToStart(text) || appModel.isRestDay && Self.asksForWorkoutToday(text) {
            if appModel.isRestDay { askSkipRestDay(spoken: !typedTurn) } else { beginWorkout() }
            return
        }
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
        if repCount == 0, Self.asksForRepeat(text), let index = currentExerciseIndex {
            introduce(exercise: index, first: false, replay: true)
            return
        }
        if appModel.activeWorkout != nil {
            if repCount > 0 {
                // Mid-count: "set done" (tapped, typed or said) closes the
                // set at the count so far; anything else is just a pause.
                if WorkoutVoice.saysSetDone(text) || WorkoutVoice.setsLogged(in: text) != nil {
                    finishCount()
                    return
                }
                markRestartHandled()
                resumeListening()
                return
            } else if short, let logged = WorkoutVoice.setsLogged(in: text), let index = currentExerciseIndex,
                      let exercise = currentExercise {
                // You didn't count — "set done", "two sets done".
                // Sets still open (not targetSets − done: those can disagree
                // after sets are ticked out of order and the count changed).
                let left = exercise.completedSets.filter { !$0.completed }.count
                let count = max(0, min(logged.sets ?? left, left))
                guard count > 0 else {
                    confirm("\(Self.short(exercise.name)) is already done.")
                    return
                }
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
            // the coach; everything else is ignored, with a hint if it
            // sounded like it was meant for MYO.
            let justAsked = askedAt.map { Date().timeIntervalSince($0) < 12 } ?? false
            // Only long run-ons (music, people nearby) are dropped now;
            // anything you say to it gets through, "MYO" or not.
            // No hint for these: they're music or other people, not you.
            if currentExerciseIndex != nil, !(addressed || justAsked), !short {
                markRestartHandled()
                resumeListening()
                return
            }
        }
        askedAt = nil
        send(text, spoken: !typedTurn)
    }

    private static let addressPattern = #"^\W*(hey |hi |ok |okay |yo )?(myo|my o|my oh|mayo|mio|meo|miyo|maya|mya|mia|myah|meya|maia|coach)\b[\s,.!?]*"#

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
        // A stray "one, two" that never became a set: drop what was heard so
        // it isn't sent to Coach as a message when the pause check fires.
        func discardHeard() {
            guard voiceInput.isListening else { return }
            markRestartHandled()
            voiceInput.stop()
            resumeListening()
        }
        guard finalCount > 0 else { discardHeard(); return }

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
            discardHeard()
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
        markRestartHandled()
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
        case .swapForSomething(let index):
            offerSwaps(for: index)
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
        case .finish where !appModel.activeWorkoutHasProgress:
            // Nothing logged: ending would record an empty workout.
            confirm("You haven't logged a set yet. Tap the workout card to end it, or say set done as you go.")
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
        // Always on screen too, so a typed "set 2 done" visibly lands.
        show(notice: line)
        if typedTurn, !conversationActive {
            // Typed with the mic off: answer on screen, don't talk.
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return
        }
        markRestartHandled()
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
    /// `dayKey`: a different day's session to do today (skipping a rest
    /// day); nil for today's own.
    private func beginWorkout(dayKey: String? = nil) {
        // A rest day asks first.
        if dayKey == nil, appModel.isRestDay, !appModel.activeWorkoutHasProgress {
            askSkipRestDay(spoken: false)
            return
        }
        textReply = nil
        Task {
            restartingWorkout = true
            defer { restartingWorkout = false }
            if appModel.activeWorkout != nil {
                if appModel.activeWorkoutHasProgress {
                    // An old session with sets in it is logged, not lost.
                    if appModel.activeWorkoutIsLeftover { await appModel.finishActiveWorkout() }
                } else {
                    // Nothing logged yet: start fresh, so it's always the
                    // latest plan (a session started before a plan change
                    // would be stale).
                    await appModel.discardActiveWorkout()
                }
                // Couldn't clear it (offline, busy): don't pretend we started.
                if appModel.activeWorkout != nil, appModel.activeWorkoutIsLeftover || !appModel.activeWorkoutHasProgress {
                    return
                }
            }
            if appModel.activeWorkout == nil {
                if let dayKey { await appModel.startWorkout(dayKey: dayKey) } else { await appModel.startTodaysWorkout() }
            }
            guard appModel.activeWorkout != nil else { return }
            askingSkipRestDay = false
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
            offerVoiceIsolation()
        }
    }

    /// A plan change went through: say what to do next.
    private func planChangeAccepted() {
        guard appModel.activeWorkout == nil || !appModel.activeWorkoutHasProgress else { return }
        // A session started before this change is stale: clear it so Start
        // (and "let's go") loads the new plan.
        if appModel.activeWorkout != nil {
            Task {
                restartingWorkout = true
                await appModel.discardActiveWorkout()
                restartingWorkout = false
            }
        }
        let line = appModel.isRestDay
            ? "Done. Today's still a rest day."
            : "Done. Your workout's ready. Tap Start, or say let's go."
        if conversationActive, speaksReplies {
            markRestartHandled()
            voice.speak(line, messageId: "local-\(UUID().uuidString)")
        }
        show(notice: appModel.isRestDay ? "Today's still a rest day." : "Your workout's ready. Tap Start.")
    }

    /// Puts a note under the coach for a few seconds.
    private func show(notice text: String) {
        notice = text
        Task {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if notice == text { notice = nil }
        }
    }

    private func exerciseChanged(from previous: Int?, to next: Int?) {
        // An offer was for the old lift.
        if let choice = swapChoice, choice.index != next { swapChoice = nil }
        guard previous != nil, let next, appModel.activeWorkout != nil else { return }
        // Let "set three done" finish first.
        Task {
            for _ in 0..<40 where voice.isSpeaking { try? await Task.sleep(nanoseconds: 200_000_000) }
            guard currentExerciseIndex == next else { return }
            introduce(exercise: next, first: false)
        }
    }

    /// The workout ended: ask about keeping changes, else the mic goes off.
    private func workoutEnded() {
        endLesson()
        swapChoice = nil
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

    /// "Today's a rest day. Want to skip it?" — yes starts your next
    /// planned session today.
    private func askSkipRestDay(spoken: Bool) {
        askingSkipRestDay = true
        askedAt = Date()
        questionAskedAt = Date()
        if spoken, speaksReplies {
            let offer = appModel.nextPlannedDay.map { "do \($0.name) instead" } ?? "have me build you a workout"
            markRestartHandled()
            voice.speak("Today's a rest day. Want to skip it and \(offer)?", messageId: "local-\(UUID().uuidString)")
        }
    }

    private func answerSkipRestDay(_ yes: Bool) {
        guard askingSkipRestDay else { return }
        askingSkipRestDay = false
        if yes, let next = appModel.nextPlannedDay {
            beginWorkout(dayKey: next.dayKey)
        } else if yes {
            // Nothing in the plan to pull forward: have Coach build one —
            // answered the way you asked (typed stays typed).
            let spoken = !typedTurn
            if spoken { conversationActive = true }
            send("It's a rest day but I want to train today. Give me a sensible workout for today.", spoken: spoken)
        } else {
            confirm(tone == .hype ? "Rest up. Back at it tomorrow!" : "Rest up.")
        }
    }

    /// The answer to "skip your rest day?" — "skip it" means yes here.
    private static func skipRestDayAnswer(_ text: String) -> Bool? {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        guard t.split(separator: " ").count <= 10 else { return nil }
        if t.range(of: #"\b(skip it|skip|yes|yeah|yep|sure|let'?s (go|do it|train)|do it|train|i'?m (good|fresh|ready))\b"#,
                   options: .regularExpression) != nil,
           t.range(of: #"\b(don't|do not|no skip)\b"#, options: .regularExpression) == nil {
            return true
        }
        if t.range(of: #"\b(no|nope|nah|rest|not today|i'?ll rest)\b"#, options: .regularExpression) != nil {
            return false
        }
        return nil
    }

    /// "Say that again", "repeat that", "explain again", "one more time".
    private static func asksForRepeat(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        guard t.split(separator: " ").count <= 8 else { return false }
        return t.range(of: #"\b(say (that|it) again|repeat( that| it)?|explain (that |it )?again|one more time|come again|what did you say|again please)\b"#,
                       options: .regularExpression) != nil
    }

    /// "Start my workout", "let's go", "I want to work out".
    private static func asksToStart(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        guard t.split(separator: " ").count <= 10 else { return false }
        if t.range(of: #"\b(start|begin)( my| a| the| today's)? (workout|session|training)\b|\blet'?s (go|work ?out|train|do (it|this))\b|\bi (want|wanna|need) to (work ?out|train|lift)\b|\bstart (it|now)\b"#,
                   options: .regularExpression) != nil { return true }
        return false
    }

    /// "Give me a workout for today", "I need a workout today", "work me out
    /// today", "build me a workout" — on a rest day, that's the rest-day
    /// question (on other days the coach shows today's card).
    private static func asksForWorkoutToday(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        guard t.split(separator: " ").count <= 12 else { return false }
        return t.range(of: #"\b(give|get|build|make|work|find|need|want|do)( me| us)? (a |an |some )?(workout|session|training|work ?out)\b.*\b(today|now|right now)\b|\b(build|make|give) me a (workout|session)\b|\bwork me out\b|\b(workout|train) (for )?today\b"#,
                       options: .regularExpression) != nil
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
    /// `replay`: you asked to hear it again — the whole thing, sets and form,
    /// whatever your tips setting.
    private func introduce(exercise index: Int, first: Bool, teach: Bool = false, replay: Bool = false) {
        guard let workout = appModel.activeWorkout, workout.exercises.indices.contains(index) else { return }
        let exercise = workout.exercises[index]
        let motion = ExerciseMotion.match(exercise.name)
        let style = teach || replay ? CoachingStyle.Tips.full : tips
        guard style != .quiet else {
            resumeListening()
            return
        }
        var lines: [String] = []
        var cues: [ExerciseLesson.BodyCue] = []
        if !teach {
            let weight = appModel.workingWeight(for: exercise)
            let load = weight > 0 ? " at \(LiveWorkoutCard.pounds(weight))" : ""
            let lead = replay ? "Here it is again" : first ? (tone == .hype ? "Let's go! First up" : "First up") : "Next up"
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
            markRestartHandled()
            voiceInput.stop()
        }
        if speaksReplies {
            voice.speak(lines: lines, messageId: plan.id)
            try? AudioHub.shared.start()
            // Only in talk mode — typing means the mic stays off.
            if AudioHub.shared.canTalkOver, conversationActive { voiceInput.listen() }
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
            markRestartHandled()
            voice.speak(ack, messageId: "local-\(UUID().uuidString)")
        } else {
            resumeListening()
        }
        return true
    }

    /// A spoken answer to the open question still counts (20 s).
    private var questionIsFresh: Bool {
        questionAskedAt.map { Date().timeIntervalSince($0) < 20 } ?? false
    }

    /// The next mic stop is ours (we're about to restart it), so the
    /// silence handler should leave it alone. Expires on its own, so a stop
    /// that never comes can't swallow a real one later.
    private func markRestartHandled() {
        restartHandledLocally = true
        restartMarks += 1
        let mark = restartMarks
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if restartMarks == mark { restartHandledLocally = false }
        }
    }

    private func endConversation() {
        swapChoice = nil
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
        // A new turn: the old typed reply has had its moment.
        textReply = nil
        lastSpokenText = trimmed
        // Asked for today's workout: show it as a card, not a recited list.
        if WorkoutAsk.matches(trimmed) { askedForWorkoutCard() }
        // You named a move: the body steps into it while Coach answers.
        if let move = MoveCue.move(in: trimmed) { director.perform(move) }
        if spoken, conversationActive {
            awaitingReplyAfter = Set(appModel.messages.map(\.id))
        } else if !spoken {
            // Typed: the answer comes back as text, not voice.
            typedReplyAfter = Set(appModel.messages.map(\.id))
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
        if let move = MoveCue.move(in: reply.content) {
            director.perform(move)
        } else if lessonPlan == nil {
            // Coach suggested a lift: show it.
            demo(reply.content)
        }
    }

    private func showTypedReplyIfReady(_ messages: [CoachMessage]) {
        guard let known = typedReplyAfter else { return }
        let finished: Set<CoachMessage.Status> = [.complete, .blocked, .error]
        guard let reply = messages.last(where: {
            $0.role == .coach && !known.contains($0.id) && finished.contains($0.status) && !$0.content.isEmpty
        }) else { return }
        typedReplyAfter = nil
        textReplyShownAt = Date()
        withAnimation(MyoTheme.Motion.fade) { textReply = reply }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
            if AudioHub.shared.canTalkOver { voiceInput.listen() }
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


/// Three dots breathing in turn — Coach is working on a reply.
private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(MyoTheme.Colors.coachAmber)
                        .frame(width: 8, height: 8)
                        .opacity(0.3 + 0.7 * max(0, sin(t * 4 - Double(i) * 0.7)))
                }
            }
        }
        .accessibilityLabel("Thinking")
    }
}




/// A typed message, with an id so sending the same words twice still counts.
struct TypedLine: Equatable {
    let id = UUID()
    let text: String
}


/// A reply to something you typed, written out a few words at a time —
/// MYO typing back. Scrolls if it's long; tap to put it away.
private struct TypedReplyText: View {
    let message: CoachMessage
    let shownAt: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let words = message.content.split(separator: " ", omittingEmptySubsequences: false)
            let count = min(words.count, Int(context.date.timeIntervalSince(shownAt) * 28) + 1)
            ScrollView {
                Text(words.prefix(count).joined(separator: " "))
                    .myoStyle(.body)
                    .foregroundStyle(MyoColor.Text.primary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
        }
        .id(message.id)
        .accessibilityLabel(message.content)
    }
}
