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
    @Binding var showTranscript: Bool
    @Binding var showKeyboard: Bool

    @AppStorage("coachSpeaksReplies") private var speaksReplies = true
    /// Message ids that existed when a voice turn was sent; the first new
    /// finished coach message after that is the reply to read aloud.
    @State private var awaitingReplyAfter: Set<String>?
    /// A hands-free conversation is running: listen → you pause → Coach
    /// thinks → Coach speaks → listen again, until you tap.
    @State private var conversationActive = false
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
        guard let workout = appModel.activeWorkout,
              let current = workout.exercises.first(where: { !$0.exerciseDone }) else { return nil }
        return ExerciseMotion.match(current.name)
    }

    /// Any card that needs the space below the body.
    private var cardOpen: Bool {
        !appModel.pendingBaselineSuggestions.isEmpty || (showTodayCard && appModel.activeWorkout == nil) || (appModel.activeWorkout != nil && workoutExpanded)
    }
    /// The newest coach reply already checked for a move, so history
    /// loading on launch never sets the body off.
    @State private var lastCueCheckedReplyId: String?

    private var phase: OrbPhase {
        if voiceInput.isListening { return .listening }
        if voice.isSpeaking { return .speaking }
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
                    focus: orbSlot.map { CGPoint(x: $0.midX - origin.x, y: $0.midY - origin.y) },
                    director: director,
                    // Fit the body to its slot when a card squeezes it.
                    scale: orbSlot.map { min(1, max(0.4, $0.height / 460)) } ?? 1,
                    loop: currentMotion,
                    inWorkout: appModel.activeWorkout != nil,
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

                if !appModel.pendingBaselineSuggestions.isEmpty {
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
                    caption
                        .padding(.horizontal, MyoTheme.Spacing.lg)
                    if let workout = appModel.activeWorkout {
                        // Begin workout drops the card down to this bar.
                        LiveWorkoutCard(workout: workout, expanded: $workoutExpanded)
                            .matchedGeometryEffect(id: "workoutCard", in: cardSpace)
                            .padding(.horizontal, MyoTheme.Spacing.md)
                            .padding(.top, MyoTheme.Spacing.md)
                    }
                }

                controls
                    .padding(.horizontal, MyoTheme.Spacing.lg)
                    .padding(.top, MyoTheme.Spacing.md)
                    .padding(.bottom, MyoTheme.Spacing.sm)
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
            voiceInput.onPause = { text in handleUtterance(text) }
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
        .onChange(of: voice.isSpeaking) { _, speaking in
            if !speaking { resumeListening() }
        }
        // Listening stopped without a send (the recognizer timed out on
        // silence): pick back up, unless it stopped on an error.
        // Counting reps out loud: the count updates as you say each number.
        .onChange(of: voiceInput.transcript) { _, transcript in
            trackReps(in: transcript)
        }
        .onChange(of: voiceInput.isListening) { _, listening in
            if !listening, restartHandledLocally { restartHandledLocally = false; return }
            guard !listening, conversationActive, awaitingReplyAfter == nil, !voice.isSpeaking else { return }
            let now = Date()
            silentRestarts = silentRestarts.filter { now.timeIntervalSince($0) < 10 } + [now]
            if voiceInput.errorMessage != nil || silentRestarts.count >= 3 {
                endConversation()
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
                ScrollView {
                    PlanAdjustmentProposalCard(proposal: proposal, isApplying: appModel.isSending) { scope in
                        Task { await appModel.acceptPendingPlanAdjustmentProposal(scope: scope) }
                    }
                }
                .scrollIndicators(.hidden)
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
                Color.clear.frame(height: 88)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(alignment: .center) {
            sideButton(systemImage: "keyboard", label: "Type instead") {
                endConversation()
                showKeyboard = true
            }

            Spacer()

            sideButton(systemImage: "text.bubble", label: "Conversation") {
                showTranscript = true
            }
        }
    }

    private func sideButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(MyoColor.Text.secondary.color)
                .frame(width: 52, height: 52)
                .background(MyoColor.Surface.elevated.color, in: Circle())
                .overlay(Circle().stroke(MyoColor.hairline, lineWidth: 1))
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
    private func talkTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if conversationActive {
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
        appModel.activeWorkout?.exercises.firstIndex { !$0.exerciseDone }
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
    private func handleUtterance(_ text: String) {
        if appModel.activeWorkout != nil {
            if repCount > 0 {
                // A pause mid-count isn't the end of the set — keep going.
                restartHandledLocally = true
                resumeListening()
                return
            } else if let change = WorkoutVoice.weightChange(in: text), let index = currentExerciseIndex,
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
        }
        send(text, spoken: true)
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
        let line: String
        if finalCount > target {
            line = "Set \(setNumber) done. \(finalCount) reps, \(finalCount - target) over."
        } else if finalCount < target {
            line = "Set \(setNumber), \(finalCount) reps."
        } else {
            line = "Set \(setNumber) done."
        }
        // Clear the counted words before Coach speaks, so they don't carry
        // into the next utterance.
        restartHandledLocally = true
        voiceInput.stop()
        confirm(line)
    }

    /// A short spoken acknowledgement, then straight back to listening.
    private func confirm(_ line: String) {
        restartHandledLocally = true
        if speaksReplies {
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
            if appModel.activeWorkout == nil { await appModel.startTodaysWorkout() }
            guard appModel.activeWorkout != nil else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            workoutExpanded = false
            showTodayCard = false
        }
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
        lastSpokenText = trimmed
        // Asked for today's workout: show it as a card, not a recited list.
        if WorkoutAsk.matches(trimmed) { askedForWorkoutCard() }
        // You named a move: the body steps into it while Coach answers.
        if let move = MoveCue.move(in: trimmed) { director.perform(move) }
        if spoken, conversationActive {
            awaitingReplyAfter = Set(appModel.messages.map(\.id))
        }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        Task { await appModel.sendCoachMessage(trimmed) }
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
        if speaksReplies {
            voice.speak(reply.content, messageId: reply.id)
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
