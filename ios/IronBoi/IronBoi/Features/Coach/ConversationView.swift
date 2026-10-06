import SwiftUI

/// Everything you and Coach have said, with the sources Coach cited.
/// Lives in the profile — the Coach screen stays just the coach.
struct ConversationView: View {
    @EnvironmentObject private var appModel: AppModel
    @AppStorage("coachSpeaksReplies") private var speaksReplies = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if appModel.messages.isEmpty {
                        Text("Nothing yet. Tap the coach and start talking.")
                            .myoStyle(.body)
                            .foregroundStyle(MyoColor.Text.secondary.color)
                            .padding(.top, 80)
                    } else {
                        ForEach(appModel.messages) { message in
                            CoachMessageBubble(message: message).id(message.id)
                        }
                    }
                }
                .padding()
            }
            .onAppear {
                if let last = appModel.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .background(PaperBackground())
        .navigationTitle("Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    speaksReplies.toggle()
                } label: {
                    Image(systemName: speaksReplies ? "speaker.wave.2" : "speaker.slash")
                }
                .tint(MyoTheme.Colors.ink)
                .accessibilityLabel(speaksReplies ? "Mute Coach's voice" : "Unmute Coach's voice")
            }
        }
    }
}
