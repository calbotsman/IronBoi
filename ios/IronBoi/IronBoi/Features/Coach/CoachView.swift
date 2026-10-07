import SwiftUI

struct CoachView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var voiceInput = VoiceInputEngine()
    @StateObject private var coachVoice = CoachVoice()
    @StateObject private var bodyDirector = BodyDirector()
    @AppStorage("coachSpeaksReplies") private var speaksReplies = true
    @State private var showKeyboard = false
    /// The last typed message, handed to the coach screen.
    @State private var typed: TypedLine?
    /// Bumped when a typed message asks for today's workout; the stage shows the card.
    @State private var askedForWorkout = 0
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !appModel.hasSession {
                    signedOutView
                } else {
                    CoachStageView(
                        voiceInput: voiceInput,
                        voice: coachVoice,
                        director: bodyDirector,
                        askedForWorkout: askedForWorkout,
                        typed: typed,
                        showKeyboard: $showKeyboard
                    )
                    .overlay(alignment: .topTrailing) {
                        ProfileButton()
                            .padding(.trailing, MyoTheme.Spacing.sm)
                    }
                }
            }
            .background(PaperBackground())
            // No title or toolbar: the coach's body is the screen. Account
            // actions live on the You tab; the voice toggle in Conversation.
            .toolbar(.hidden, for: .navigationBar)
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
            // Typing is still here, one tap away — just not the default: a
            // slim bar that rises out of the keyboard button, above the keys.
            .safeAreaInset(edge: .bottom) {
                if showKeyboard {
                    TypeBar(isPresented: $showKeyboard, onSend: sendTyped)
                        .padding(.horizontal, MyoTheme.Spacing.md)
                        .padding(.bottom, MyoTheme.Spacing.sm)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.9, anchor: .bottomLeading).combined(with: .opacity),
                            removal: .opacity.combined(with: .move(edge: .bottom))))
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.82), value: showKeyboard)
        }
    }

    /// Static meter for the intro orb's coach side — it never speaks there.
    private static let quietCoach = VoiceMeter()
    @StateObject private var introBody = BodyDirector()
    @StateObject private var intro = IntroChoreography()

    private var signedOutView: some View {
        ZStack {
            GeometryReader { geo in
                OrbView(
                    phase: .rest,
                    you: intro.you,
                    agent: Self.quietCoach,
                    focus: CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.36),
                    director: introBody,
                    scale: 0.9,
                    demo: intro.demo,
                    // Rise from just above the wordmark, not through the text.
                    bloopStart: geo.size.height * 0.56
                )
            }
            .ignoresSafeArea()
            .onAppear { intro.start() }
            .onDisappear { intro.stop() }

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: MyoTheme.Spacing.sm) {
                    Image("MYOWordmark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 46)
                        .accessibilityLabel("MYO")
                    Text("Your new personal trainer.")
                        .myoStyle(.title)
                        .foregroundStyle(MyoColor.Text.secondary.color)
                        .multilineTextAlignment(.center)
                    Text("It writes your plan, explains the why,\nand remembers what you tell it.")
                        .myoStyle(.body)
                        .foregroundStyle(MyoColor.Text.tertiary.color)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
                .padding(.horizontal, MyoTheme.Spacing.lg)

                Button {
                    appModel.signInWithApple()
                } label: {
                    Label("Sign in with Apple", systemImage: "apple.logo")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(MyoTheme.Colors.cream)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(MyoTheme.Colors.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, MyoTheme.Spacing.lg)
                .padding(.top, MyoTheme.Spacing.xl)

                Text("Private by default. Your training stays yours.")
                    .font(.caption)
                    .foregroundStyle(MyoColor.Text.tertiary.color)
                    .padding(.top, MyoTheme.Spacing.md)

                #if DEBUG
                HStack(spacing: MyoTheme.Spacing.lg) {
                    Button("Preview (no backend)") { appModel.startPreviewSession() }
                    Button("Dev sign-in") { Task { await appModel.signInAsDeveloper() } }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(MyoColor.Text.secondary.color)
                .padding(.top, MyoTheme.Spacing.lg)
                #endif
            }
            .padding(.bottom, MyoTheme.Spacing.lg)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if appModel.messages.isEmpty {
                        ContentUnavailableView(
                            "Ask Coach",
                            systemImage: "message",
                            description: Text("Ask about today's workout, a swap, recovery, or what to do after a missed session.")
                        )
                        .padding(.top, 80)
                    } else {
                        ForEach(appModel.messages) { message in
                            CoachMessageBubble(message: message)
                                .id(message.id)
                        }
                    }

                    if let proposal = appModel.pendingPlanAdjustmentProposal {
                        PlanAdjustmentProposalCard(
                            proposal: proposal,
                            isApplying: appModel.isSending
                        ) { scope in
                            Task {
                                await appModel.acceptPendingPlanAdjustmentProposal(scope: scope)
                            }
                        }
                            .id("plan-adjustment-\(proposal.id)")
                    }
                }
                .padding()
            }
            // Keyboard dismissal: drag the conversation down (iMessage-style)
            // or tap anywhere in the message list. Without these the keyboard
            // has NO way to close — the TextField never resigns focus.
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            .onChange(of: appModel.messages) { _, messages in
                guard let last = messages.last else { return }
                withAnimation(MyoTheme.Motion.fade) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            // Opening the keyboard shrinks the viewport — keep the newest
            // message visible instead of letting it hide behind the keyboard.
            .onChange(of: composerFocused) { _, focused in
                guard focused, let last = appModel.messages.last else { return }
                withAnimation(MyoTheme.Motion.fade) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            // Open on the newest message.
            .onAppear {
                if let last = appModel.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            // Deliberately NOT .disabled(isSending): disabling a focused field
            // resigns first responder, dropping the keyboard after every send.
            // Double-send is already prevented by the send button's guard.
            TextField("Ask Coach...", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($composerFocused)

            Button {
                sendDraft()
            } label: {
                Image(systemName: appModel.isSending ? "hourglass" : "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(MyoTheme.Colors.brick)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appModel.isSending)
            .accessibilityLabel("Send message")
        }
        .padding()
        .background(MyoTheme.Colors.cream)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MyoTheme.Colors.hairline)
                .frame(height: 1)
        }
    }

    /// Typed messages go through the coach screen, which handles them just
    /// like spoken ones — "set 2 done" logs the set either way.
    private func sendDraft() {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        showKeyboard = false
        guard !content.isEmpty else { return }
        sendTyped(content)
    }

    /// What you typed goes to the coach — and, like talking, arrives as a
    /// little run of your-colour bloops the body takes in, a word or two each.
    private func sendTyped(_ text: String) {
        typed = TypedLine(text: text)
        let meter = voiceInput.meter
        let bloops = min(8, max(2, text.split(separator: " ").count / 2 + 1))
        Task { @MainActor in
            var reading = VoiceReading()
            reading.active = true
            reading.level = 0.5
            for _ in 0..<bloops {
                reading.onsets += 1
                reading.peak = Float.random(in: 0.4...0.85)
                meter.set(reading)
                try? await Task.sleep(nanoseconds: UInt64.random(in: 70_000_000...140_000_000))
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            // Hand the meter back, unless the mic has taken it meanwhile.
            if !voiceInput.isListening { meter.reset() }
        }
    }
}

struct CoachMessageBubble: View {
    let message: CoachMessage

    var body: some View {
        HStack {
            if message.isUser {
                Spacer(minLength: 44)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(message.isPendingCoachReply ? "Thinking..." : message.content)
                    .font(.body)
                    .foregroundStyle(MyoTheme.Colors.ink)
                    .textSelection(.enabled)

                if message.status == .blocked {
                    Text("Safety boundary")
                        .font(MyoTheme.Typography.monoLabel)
                        .foregroundStyle(MyoTheme.Colors.brick)
                        .textCase(.uppercase)
                }

                if !message.isUser, !message.sources.isEmpty {
                    CoachSourcesLine(sources: message.sources)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(message.isUser ? MyoTheme.Colors.ochreLight : MyoTheme.Colors.cream)
            .overlay {
                RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous)
                    .stroke(message.isUser ? Color.clear : MyoTheme.Colors.hairline, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))

            if !message.isUser {
                Spacer(minLength: 44)
            }
        }
    }
}

/// The grounding made visible: a red-pen "Informed by" line under a coach
/// reply, naming the reviewed sources that were in context for the turn.
struct CoachSourcesLine: View {
    let sources: [CoachSource]

    private var firstURL: URL? { sources.first(where: { $0.url != nil })?.url }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text("INFORMED BY")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .kerning(0.5)
                    .foregroundStyle(MyoColor.redPen)
                Text(sources.map(\.label).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(MyoColor.Text.secondary.color)
                    .lineLimit(2)
            }
            // The coach's red pen — a hand-drawn underline under the citation.
            RedPenUnderline()
                .stroke(MyoColor.redPen, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(height: 4)
                .opacity(0.85)
        }
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())

        // Only interactive when there's actually somewhere to go; otherwise it's
        // a static, non-misleading label.
        if let url = firstURL {
            Button { UIApplication.shared.open(url) } label: { content }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isLink)
                .accessibilityLabel("Informed by \(sources.map(\.label).joined(separator: ", ")). Open source.")
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Informed by \(sources.map(\.label).joined(separator: ", "))")
        }
    }
}

/// A slightly wavy underline — pen on paper, not a ruler line.
private struct RedPenUnderline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        path.move(to: CGPoint(x: rect.minX, y: midY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: midY),
            control1: CGPoint(x: rect.width * 0.33, y: midY - 1.6),
            control2: CGPoint(x: rect.width * 0.66, y: midY + 1.6)
        )
        return path
    }
}

struct PlanAdjustmentProposalCard: View {
    let proposal: PlanAdjustmentProposalSummary
    let isApplying: Bool
    // The scope string passed here is nil ONLY when the proposal already
    // carries its own scope (LLM-preset) — the backend then falls back to
    // proposal.appliesTo.scope. Every proposal without a preset scope goes
    // through the two-button picker below and sends an explicit value.
    let apply: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Plan review", systemImage: "slider.horizontal.3")
                    .font(.headline)

                Spacer()

                Text(proposal.riskLevel.replacingOccurrences(of: "_", with: " "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(riskColor)
                    .textCase(.uppercase)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(proposal.summary)
                    .font(.subheadline.weight(.semibold))

                Text(proposal.rationale)
                    .font(.subheadline)
                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(proposal.patchTitle)
                    .font(.subheadline.weight(.semibold))

                // A ramp needs BOTH: the week-by-week shape (which weeks, what
                // percentage, when it returns to normal) and the concrete
                // sessions underneath it. Every other patch type shows one or
                // the other.
                if proposal.dayPatchDetails.isEmpty || proposal.patchType == "reentry_ramp" {
                    ForEach(proposal.changes, id: \.self) { change in
                        Label(change, systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                    }
                }

                if !proposal.dayPatchDetails.isEmpty {
                    // The user is approving THIS content — show every
                    // exercise, never just a day name and a count.
                    ForEach(proposal.dayPatchDetails) { day in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(day.dayKey) — \(day.name)")
                                .font(.caption.weight(.semibold))
                            ForEach(day.exerciseLines, id: \.self) { line in
                                Text(line)
                                    .font(.caption)
                                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                                    .padding(.leading, 10)
                            }
                        }
                    }
                }
            }

            if !proposal.safetyNotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(proposal.safetyNotes.prefix(3), id: \.self) { note in
                        Label(note, systemImage: "exclamationmark.shield")
                            .font(.caption2)
                            .foregroundStyle(MyoColor.redPen)
                    }
                }
            }

            if proposal.requiresFollowUp {
                Label("Coach needs one more detail before applying this safely.", systemImage: "questionmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MyoTheme.Colors.ochre)
            }

            if !proposal.sourceCorpusEntryIds.isEmpty {
                Text("Evidence: \(proposal.sourceCorpusEntryIds.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.45))
                    .lineLimit(2)
            }

            if canApply {
                if proposal.patchType == "clear_overrides" {
                    // Scope is meaningless for a restore — one honest button.
                    Button {
                        apply(nil)
                    } label: {
                        Label(isApplying ? "Applying..." : "Restore my regular plan", systemImage: "arrow.uturn.backward.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MyoColor.Action.primary.color)
                    .foregroundStyle(MyoColor.Text.primary.color)
                    .disabled(isApplying)
                } else if proposal.scope != nil {
                    Button {
                        apply(nil)
                    } label: {
                        Label(isApplying ? "Applying..." : applyButtonTitle, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MyoColor.Action.primary.color)
                    .foregroundStyle(MyoColor.Text.primary.color)
                    .disabled(isApplying)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(scopeQuestion)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))

                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                Button {
                                    apply("today")
                                } label: {
                                    Text(isApplying ? "Applying..." : justOnceButtonTitle)
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .disabled(isApplying)

                                // Only offered for multi-day patches: for a
                                // single target day "this week" and "just
                                // today" produce the identical write.
                                if proposal.dayPatchDetails.count > 1 {
                                    Button {
                                        apply("rest_of_week")
                                    } label: {
                                        // "only" is load-bearing: rest_of_week
                                        // writes date-keyed overrides through
                                        // Sunday that then expire — without it
                                        // this reads like the start of a
                                        // permanent change.
                                        Text(isApplying ? "Applying..." : "This week only")
                                            .font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isApplying)
                                }
                            }

                            Button {
                                apply("going_forward")
                            } label: {
                                Text(isApplying ? "Applying..." : "Rest of plan (permanent)")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(MyoColor.Action.primary.color)
                            .foregroundStyle(MyoColor.Text.primary.color)
                            .disabled(isApplying)
                        }
                    }
                }
            } else {
                Label("Reply with one more detail before Coach changes your plan.", systemImage: "lock.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
            }
        }
        .padding(14)
        .background(MyoTheme.Colors.cream)
        .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous)
                .stroke(MyoTheme.Colors.ochre.opacity(0.55), lineWidth: 1)
        )
    }

    private var riskColor: Color {
        switch proposal.riskLevel {
        case "high", "blocked":
            return MyoColor.State.danger.color
        case "medium":
            return MyoColor.State.warning.color
        default:
            return MyoColor.Text.secondary.color
        }
    }

    private var canApply: Bool {
        proposal.riskLevel == "low" && !proposal.requiresFollowUp
    }

    // Only used when the proposal came in with a preset scope (LLM tool
    // path). The reach MUST be visible on the one-tap button — the human
    // approving is the only gate, and "Apply to plan" alone would hide
    // whether this is a one-day tweak or a permanent cascade.
    private var applyButtonTitle: String {
        let target = proposal.dayKey ?? "plan"
        switch proposal.scope {
        case "today":
            return "Apply to \(target) — that day only"
        case "rest_of_week":
            return "Apply — this week only"
        case "going_forward":
            return "Apply to \(target) — going forward"
        case "reentry_ramp":
            // The reach that matters for a ramp is that it ENDS. The card
            // lists each week's dates above, so the button names the shape
            // and the fact that it undoes itself.
            return "Start easing back in — reverts on its own"
        default:
            return proposal.dayKey.map { "Apply to \($0)" } ?? "Apply to plan"
        }
    }

    // The "one time" button names the actual target day when the proposal
    // isn't about today — "Just today" on a Friday-targeting proposal would
    // misdescribe what happens (the backend keys the override to Friday).
    private var justOnceButtonTitle: String {
        guard let dayKey = proposal.dayKey, dayKey != Self.currentDayKey() else {
            return "Just today"
        }
        return "Just this \(dayKey)"
    }

    private var scopeQuestion: String {
        guard let dayKey = proposal.dayKey, dayKey != Self.currentDayKey() else {
            return "Just today, this week only, or permanently?"
        }
        // "this week only" (not bare "this week") — matches the button and the
        // today-variant above; the week option is temporary and expires Sunday.
        return "Apply this to just this \(dayKey), this week only, or permanently?"
    }

    private static func currentDayKey() -> String {
        let weekday = Calendar.current.component(.weekday, from: Date())
        return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][weekday - 1]
    }
}

#Preview {
    CoachView()
        .environmentObject(AppModel())
}
