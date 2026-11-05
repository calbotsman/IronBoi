import SwiftUI

/// "Train with friends" in the You tab. Draws nothing unless the prototype
/// is available in this build; while you haven't opted in it is a single
/// row — no friend list, no empty state.
struct SocialCard: View {
    @ObservedObject private var social = SocialModel.shared
    @State private var code = ""
    @State private var confirmOff = false

    var body: some View {
        if SocialFeature.isAvailable {
            MyoGroupCard {
                MyoSectionLabel(text: "Friends")
                if social.isOn { onContent } else { offRow }
                if let note = social.note {
                    Text(note)
                        .myoStyle(.body)
                        .foregroundStyle(MyoColor.Text.secondary.color)
                }
            }
            .task { await social.loadFriends() }
            .onAppear { if let pending = social.pendingCode { code = pending } }
            .onChange(of: social.pendingCode) { _, next in if let next { code = next } }
            .confirmationDialog("Stop training with friends?", isPresented: $confirmOff, titleVisibility: .visible) {
                Button("Turn off and remove all friends", role: .destructive) {
                    Task { await social.setOn(false) }
                }
            } message: {
                Text("Your friends stop seeing whether you trained, and you leave every connection.")
            }
        }
    }

    private var offRow: some View {
        Button {
            Task { await social.setOn(true) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Train with friends")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(MyoTheme.Colors.ink)
                    Text("Friends you invite see your first name, whether you trained today, and your weekly streak. Nothing else.")
                        .myoStyle(.body)
                        .foregroundStyle(MyoColor.Text.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "person.2")
                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.5))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(social.busy)
    }

    @ViewBuilder private var onContent: some View {
        ForEach(social.friends) { friend in
            HStack {
                Text(friend.firstName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MyoTheme.Colors.ink)
                Spacer()
                Text(friend.trainedToday ? "Trained today" : "Not yet today")
                    .myoStyle(.body)
                    .foregroundStyle(friend.trainedToday ? MyoTheme.Colors.sage : MyoColor.Text.secondary.color)
                if friend.streakWeeks > 0 {
                    Text("· \(friend.streakWeeks)w")
                        .myoStyle(.body)
                        .foregroundStyle(MyoColor.Text.secondary.color)
                        .accessibilityLabel("\(friend.streakWeeks)-week streak")
                }
                Menu {
                    Button("Leave", role: .destructive) { Task { await social.leave(friend) } }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(MyoTheme.Colors.ink.opacity(0.5))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Options for \(friend.firstName)")
            }
            .frame(minHeight: 44)
            MyoHairline()
        }

        if let invite = social.invite {
            ShareLink(
                item: invite.link,
                message: Text("Train with me on MYO. Open \(invite.link) or enter code \(invite.code) in You → Friends.")
            ) {
                row(title: "Send invite · \(invite.code)", icon: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
        } else {
            Button { Task { await social.makeInvite() } } label: {
                row(title: "Invite a friend", icon: "link")
            }
            .buttonStyle(.plain)
            .disabled(social.busy)
        }

        HStack {
            TextField("Friend's code", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.body.monospaced())
            Button("Join") { Task { await social.accept(code); code = "" } }
                .fontWeight(.semibold)
                .disabled(code.filter { $0.isLetter || $0.isNumber }.count < 12 || social.busy)
        }
        .frame(minHeight: 44)

        MyoHairline()
        Button { confirmOff = true } label: {
            row(title: "Stop training with friends", icon: "person.2.slash")
        }
        .buttonStyle(.plain)
    }

    private func row(title: String, icon: String) -> some View {
        HStack {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(MyoTheme.Colors.ink)
            Spacer()
            Image(systemName: icon)
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.5))
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// The one onboarding question, asked once after onboarding finishes.
/// Default is no: "Not now" (or swiping it away) leaves the app as it was.
struct SocialOnboardingQuestion: View {
    @ObservedObject private var social = SocialModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
            Text("Train with friends?")
                .myoStyle(.display)
                .foregroundStyle(MyoColor.Text.primary.color)
            Text("Invite a friend with a link. You'll each see if the other trained today and your streak — nothing about bodies, weights or health. I might mention when they've trained. You can change this any time in You.")
                .myoStyle(.body)
                .foregroundStyle(MyoColor.Text.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                Task { await social.answerOnboarding(false) }
            } label: {
                Text("Not now")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(MyoTheme.Colors.cream)
                    .background(MyoTheme.Colors.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            Button {
                Task { await social.answerOnboarding(true) }
            } label: {
                Text("Yes, train with friends")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(MyoTheme.Colors.ink)
            }
            .buttonStyle(.plain)
        }
        .padding(MyoTheme.Spacing.lg)
        .background(PaperBackground().ignoresSafeArea())
        .presentationDetents([.medium])
        .interactiveDismissDisabled(false)
    }
}
