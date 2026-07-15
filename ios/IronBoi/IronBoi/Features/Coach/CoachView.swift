import SwiftUI

struct CoachView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var voiceInput = VoiceInputEngine()
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @State private var showDeleteAccountConfirm = false
    @State private var showDeleteAccountFinalConfirm = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !appModel.hasSession {
                    signedOutView
                } else {
                    if appModel.profile.preferences.coachingLens != .none {
                        protocolBar
                    }
                    messageList
                    composer
                }
            }
            .background(PaperBackground())
            .navigationTitle("Coach")
            .toolbar {
                if appModel.hasSession {
                    Menu {
                        Button {
                            appModel.signOut()
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }

                        Divider()

                        Button(role: .destructive) {
                            showDeleteAccountConfirm = true
                        } label: {
                            Label("Delete Account…", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                            .accessibilityLabel("Account")
                    }
                }
            }
            // Phase 3 Task 3.1 — two-step confirmation for account deletion.
            // Apple's guideline 5.1.1(v) requires deletion to be
            // discoverable; we keep the two-step pattern so accidental
            // taps don't wipe data.
            .alert("Delete account?", isPresented: $showDeleteAccountConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Continue", role: .destructive) {
                    showDeleteAccountFinalConfirm = true
                }
            } message: {
                Text("This will permanently delete your MYO account, all your workouts, daily checks, coach history, and memory facts the coach has saved about you. This cannot be undone.")
            }
            .alert("Are you sure?", isPresented: $showDeleteAccountFinalConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete forever", role: .destructive) {
                    Task { await appModel.deleteAccount() }
                }
            } message: {
                Text("Last chance. Tapping \"Delete forever\" signs you out and wipes everything within the next few minutes.")
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

    /// The active coaching protocol, surfaced as a hook. Tapping jumps to You
    /// to change it. Hidden when the protocol is the default.
    private var protocolBar: some View {
        let lens = appModel.profile.preferences.coachingLens
        return Button {
            composerFocused = false
            appModel.selectedTab = .you
        } label: {
            HStack(spacing: MyoTheme.Spacing.sm) {
                Text("PROTOCOL")
                    .myoStyle(.label)
                    .foregroundStyle(MyoColor.redPen)
                Text(lens.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MyoColor.Text.primary.color)
                if !lens.attribution.isEmpty {
                    Text(lens.attribution)
                        .myoStyle(.label)
                        .foregroundStyle(MyoColor.Text.tertiary.color)
                }
                Spacer()
                Image(systemName: "slider.horizontal.3")
                    .font(.footnote)
                    .foregroundStyle(MyoColor.Text.tertiary.color)
            }
            .padding(.horizontal, MyoTheme.Spacing.md)
            .padding(.vertical, MyoTheme.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MyoColor.Surface.selected.color.opacity(0.35))
        .overlay(alignment: .bottom) {
            Rectangle().fill(MyoColor.hairline).frame(height: 1)
        }
        .accessibilityHint("Change your coaching protocol in You")
    }

    private var signedOutView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(MyoTheme.Colors.ochre)

            VStack(spacing: 8) {
                Text("MYO Coach")
                    .font(.largeTitle.bold())

                Text("Sign in to start your private training thread.")
                    .font(.body)
                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                    .multilineTextAlignment(.center)
            }

            Button {
                appModel.signInWithApple()
            } label: {
                Label("Sign in with Apple", systemImage: "apple.logo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(MyoTheme.Colors.ink)
            .padding(.horizontal, 28)

            #if DEBUG
            VStack(spacing: 10) {
                Button {
                    appModel.startPreviewSession()
                } label: {
                    Label("Preview the app (no backend)", systemImage: "eye")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(MyoColor.Action.primary.color)
                .foregroundStyle(MyoColor.Text.primary.color)

                Button("Dev sign-in (anonymous)") {
                    Task { await appModel.signInAsDeveloper() }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(MyoColor.Text.secondary.color)
            }
            .padding(.top, 4)
            #endif

            Spacer()
        }
        .padding()
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
            .background(MyoTheme.Colors.cream)
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
                voiceInput.toggle()
            } label: {
                Image(systemName: voiceInput.isListening ? "mic.circle.fill" : "mic.circle")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(voiceInput.isListening ? MyoTheme.Colors.brick : MyoTheme.Colors.ink)
            }
            .disabled(appModel.isSending)
            .accessibilityLabel(voiceInput.isListening ? "Stop voice input" : "Start voice input")

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

    private func sendDraft() {
        let content = draft
        voiceInput.stop()
        draft = ""
        Task {
            await appModel.sendCoachMessage(content)
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
private struct CoachSourcesLine: View {
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

                ForEach(proposal.changes, id: \.self) { change in
                    Label(change, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
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
                if proposal.scope != nil {
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

                            Button {
                                apply("going_forward")
                            } label: {
                                Text(isApplying ? "Applying..." : "Rest of plan")
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
        case "going_forward":
            return "Apply to \(target) — going forward"
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
            return "Apply this to just today, or carry it forward?"
        }
        return "Apply this to just this \(dayKey), or carry it forward?"
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
