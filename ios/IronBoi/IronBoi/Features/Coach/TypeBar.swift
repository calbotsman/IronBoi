import SwiftUI

/// Typing to MYO, kept as quiet as talking: one slim glass field that rises
/// out of the keyboard button. No border, no focus ring — just the caret.
/// The send arrow only appears once there's something to send, and what you
/// send lifts off the bar and drifts up toward the coach as it goes.
struct TypeBar: View {
    @Binding var isPresented: Bool
    let onSend: (String) -> Void

    @State private var draft = ""
    @State private var lifted: String?
    @State private var liftedUp = false
    @FocusState private var focused: Bool

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // What you just sent, rising away — the "it went" moment.
            if let lifted {
                Text(lifted)
                    .font(.body)
                    .foregroundStyle(MyoColor.Text.primary.color)
                    .lineLimit(2)
                    .padding(.horizontal, 20)
                    .offset(y: liftedUp ? -140 : -6)
                    .opacity(liftedUp ? 0 : 1)
                    .scaleEffect(liftedUp ? 0.92 : 1, anchor: .leading)
                    .blur(radius: liftedUp ? 2 : 0)
                    .allowsHitTesting(false)
            }

            HStack(spacing: 6) {
                TextField("", text: $draft,
                          prompt: Text("Say something to MYO").foregroundStyle(MyoColor.Text.tertiary.color))
                    .font(.body)
                    .foregroundStyle(MyoColor.Text.primary.color)
                    .tint(MyoTheme.Colors.coachAmber)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.leading, 20)
                    .padding(.vertical, 16)

                if !trimmed.isEmpty {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(MyoTheme.Colors.ink)
                            .frame(width: 38, height: 38)
                            .background(MyoTheme.Colors.coachAmber, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                    .accessibilityLabel("Send")
                }
            }
            .frame(minHeight: 56)
            .myoGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: trimmed.isEmpty)
        }
        .onAppear {
            // A beat after it rises, so the keyboard and the bar arrive together.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
        .onChange(of: focused) { _, isFocused in
            // Keyboard dismissed (swipe down, tap away): the bar goes with it.
            if !isFocused, lifted == nil {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isPresented = false }
            }
        }
    }

    private func send() {
        let text = trimmed
        guard !text.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        draft = ""
        lifted = text
        liftedUp = false
        onSend(text)
        withAnimation(.easeOut(duration: 0.7)) { liftedUp = true }
        // Then the bar tucks away so the reply has the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isPresented = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { lifted = nil }
    }
}
