import SwiftUI

struct CoachView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var voiceInput = VoiceInputEngine()
    @State private var draft = ""
    @State private var showDeleteAccountConfirm = false
    @State private var showDeleteAccountFinalConfirm = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if appModel.user == nil {
                    signedOutView
                } else {
                    messageList
                    composer
                }
            }
            .background(Color.myoIllustrationPaper.ignoresSafeArea())
            .navigationTitle("Coach")
            .toolbar {
                if appModel.user != nil {
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

    private var signedOutView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.yellow)

            VStack(spacing: 8) {
                Text("MYO Coach")
                    .font(.largeTitle.bold())

                Text("Sign in to start your private training thread.")
                    .font(.body)
                    .foregroundStyle(.secondary)
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
            .tint(.black)
            .padding(.horizontal, 28)

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
                        ) {
                            Task {
                                await appModel.acceptPendingPlanAdjustmentProposal()
                            }
                        }
                            .id("plan-adjustment-\(proposal.id)")
                    }
                }
                .padding()
            }
            .onChange(of: appModel.messages) { _, messages in
                guard let last = messages.last else { return }
                withAnimation(.snappy) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .background(Color.myoIllustrationPaper)
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Ask Coach...", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(appModel.isSending)

            Button {
                voiceInput.toggle()
            } label: {
                Image(systemName: voiceInput.isListening ? "mic.circle.fill" : "mic.circle")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(voiceInput.isListening ? .red : .primary)
            }
            .disabled(appModel.isSending)
            .accessibilityLabel(voiceInput.isListening ? "Stop voice input" : "Start voice input")

            Button {
                sendDraft()
            } label: {
                Image(systemName: appModel.isSending ? "hourglass" : "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.hierarchical)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appModel.isSending)
            .accessibilityLabel("Send message")
        }
        .padding()
        .background(.bar)
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
                    .foregroundStyle(message.isUser ? .black : .primary)
                    .textSelection(.enabled)

                if message.status == .blocked {
                    Text("Safety boundary")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red)
                        .textCase(.uppercase)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(message.isUser ? Color.yellow : Color.myoIllustrationPaper)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(message.isUser ? Color.clear : Color.black.opacity(0.06), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if !message.isUser {
                Spacer(minLength: 44)
            }
        }
    }
}

struct PlanAdjustmentProposalCard: View {
    let proposal: PlanAdjustmentProposalSummary
    let isApplying: Bool
    let apply: () -> Void

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
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(proposal.patchTitle)
                    .font(.subheadline.weight(.semibold))

                ForEach(proposal.changes, id: \.self) { change in
                    Label(change, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if proposal.requiresFollowUp {
                Label("MYO needs one more detail before applying this safely.", systemImage: "questionmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            if !proposal.sourceCorpusEntryIds.isEmpty {
                Text("Evidence: \(proposal.sourceCorpusEntryIds.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            if canApply {
                Button(action: apply) {
                    Label(isApplying ? "Applying..." : applyButtonTitle, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)
                .disabled(isApplying)
            } else {
                Label("Reply with one more detail before MYO changes your plan.", systemImage: "lock.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.myoIllustrationPaper)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.yellow.opacity(0.55), lineWidth: 1)
        )
    }

    private var riskColor: Color {
        switch proposal.riskLevel {
        case "high", "blocked":
            return .red
        case "medium":
            return .orange
        default:
            return .secondary
        }
    }

    private var canApply: Bool {
        proposal.riskLevel == "low" && !proposal.requiresFollowUp
    }

    private var applyButtonTitle: String {
        if let dayKey = proposal.dayKey {
            return "Apply to \(dayKey)"
        }
        return "Apply to plan"
    }
}

#Preview {
    CoachView()
        .environmentObject(AppModel())
}
