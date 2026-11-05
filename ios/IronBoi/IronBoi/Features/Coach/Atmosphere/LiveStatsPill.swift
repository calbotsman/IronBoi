import SwiftUI

/// Heart rate, calories and one number for the moment you're in, in a
/// small glass pill at the top of the workout screen. Swipe it away and it
/// folds to a dot; tap the dot to bring it back. Remembered across workouts.
struct LiveStatsPill: View {
    @ObservedObject var vitals: WorkoutVitals
    @AppStorage("workoutStatsPillShown") private var shown = true
    /// Recovered while folded away: open for a few seconds to say so.
    @State private var peeking = false
    @State private var drag: CGSize = .zero

    private var open: Bool { shown || peeking }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if open {
                pill
                    .offset(x: min(drag.width, 0), y: min(drag.height, 0))
                    .opacity(1 - Double(min(1, max(-drag.width, -drag.height) / 120)))
                    .gesture(dismissGesture)
                    .transition(.asymmetric(insertion: .scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity),
                                            removal: .scale(scale: 0.4, anchor: .topLeading).combined(with: .opacity)))
            } else {
                nub.transition(.opacity)
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: open)
        .onChange(of: vitals.recoveredCount) { _, _ in
            guard !shown else { return }
            peeking = true
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                peeking = false
            }
        }
    }

    // MARK: - Pieces

    private var pill: some View {
        HStack(spacing: 10) {
            if let heart = vitals.heart {
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MyoTheme.Colors.coachAmber)
                    Text("\(heart.bpm)")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Heart rate \(heart.bpm)" + (heart.zone.map { ", zone \($0)" } ?? ""))
            }
            if let kcal = vitals.kcal {
                if vitals.heart != nil { divider }
                Text("\(kcal) kcal")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityLabel("About \(kcal) calories")
            }
            if let context = vitals.context {
                if vitals.heart != nil || vitals.kcal != nil { divider }
                contextLabel(context)
            }
        }
        .font(.system(.footnote, design: .monospaced).weight(.medium))
        .foregroundStyle(MyoColor.Text.primary.color)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .myoGlass(tint: recovered ? MyoTheme.Colors.sage.opacity(0.35) : nil)
        .animation(.easeInOut(duration: 0.4), value: recovered)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Hide stats") { setShown(false) }
    }

    private var recovered: Bool { vitals.context == .recovered }

    private var divider: some View {
        Circle().fill(MyoColor.Text.secondary.color.opacity(0.5)).frame(width: 3, height: 3)
    }

    @ViewBuilder
    private func contextLabel(_ context: WorkoutVitals.Context) -> some View {
        switch context {
        case .inZone(let zone, let seconds):
            Text("Z\(zone) \(Self.clock(seconds))")
                .monospacedDigit()
                .accessibilityLabel("Zone \(zone) for \(Self.spoken(seconds))")
        case .recovering(let drop, _):
            Text("\u{2193}\(drop) bpm")
                .monospacedDigit()
                .accessibilityLabel("Heart rate down \(drop) since the rest began")
        case .recovered:
            Text("Recovered")
        case .restLeft(let seconds):
            Text("Rest \(Self.clock(seconds))")
                .monospacedDigit()
                .accessibilityLabel("\(Self.spoken(seconds)) of rest left")
        case .elapsed(let minutes):
            Text("\(minutes) min")
                .monospacedDigit()
                .accessibilityLabel("\(minutes) minutes in")
        }
    }

    /// Folded away: a dot with a heart, where the pill was.
    private var nub: some View {
        Button { setShown(true) } label: {
            Image(systemName: "heart.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MyoTheme.Colors.coachAmber)
                .frame(width: 30, height: 30)
                .myoGlass(in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show workout stats")
    }

    /// Swipe up or left to put it away.
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { drag = $0.translation }
            .onEnded { value in
                let away = value.translation.width < -50 || value.translation.height < -24
                    || value.predictedEndTranslation.width < -140 || value.predictedEndTranslation.height < -80
                if away {
                    peeking = false
                    setShown(false)
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { drag = .zero }
            }
    }

    private func setShown(_ value: Bool) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) { shown = value }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func spoken(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) seconds" : "\(seconds / 60) minutes \(seconds % 60) seconds"
    }
}
