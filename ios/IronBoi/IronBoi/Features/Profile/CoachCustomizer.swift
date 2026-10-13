import SwiftUI

// "Meet your coach" — pick a personality, fine-tune it, choose the body's
// colour. Shown once to new users right after onboarding, and from You at
// any time.
//
// Where each choice lives (no new backend fields):
//   delivery  → profile.preferences.coachingTone (direct | warm | balanced),
//               saved through upsertProfile; the prompt already honours it.
//   energy    → CoachingStyle.toneKey on this device (calm | steady | hype),
//               sent per message as coachTone; steady sends nothing.
//   talk      → CoachingStyle.tipsKey on this device (quiet | brief | full).
//   colour    → CoachColor.storageKey on this device; the orb reads it.
// Energy and talk are the same settings "calm down" / "no tips" change by
// voice, so the widget and the spoken asides stay in sync.

// MARK: - Personalities

struct CoachPersonality: Identifiable, Equatable {
    let id: String
    let name: String
    let blurb: String
    let delivery: CoachingTone
    let energy: CoachingStyle.Tone
    let tips: CoachingStyle.Tips

    static let all: [CoachPersonality] = [
        CoachPersonality(id: "classic", name: "The Classic",
                         blurb: "Upbeat and clear. Teaches as you go.",
                         delivery: .balanced, energy: .hype, tips: .full),
        CoachPersonality(id: "hype", name: "Hype Partner",
                         blurb: "In your corner, loud about it.",
                         delivery: .warm, energy: .hype, tips: .full),
        CoachPersonality(id: "drill", name: "Drill Sergeant",
                         blurb: "Short orders. No hand-holding.",
                         delivery: .direct, energy: .hype, tips: .brief),
        CoachPersonality(id: "mentor", name: "Calm Mentor",
                         blurb: "Patient, quiet, explains the why.",
                         delivery: .warm, energy: .calm, tips: .full),
        CoachPersonality(id: "straight", name: "Straight Shooter",
                         blurb: "Numbers first. Says what it sees.",
                         delivery: .direct, energy: .steady, tips: .brief),
    ]

    /// The preset these settings add up to, or nil for a custom mix.
    static func matching(delivery: CoachingTone, energy: CoachingStyle.Tone,
                         tips: CoachingStyle.Tips) -> CoachPersonality? {
        all.first { $0.delivery == delivery && $0.energy == energy && $0.tips == tips }
    }

    /// What Coach might say after your third set of squats, in this mix.
    static func sampleLine(delivery: CoachingTone, energy: CoachingStyle.Tone,
                           tips: CoachingStyle.Tips) -> String {
        if tips == .quiet { return "Eight. Rest." }
        let opener: String
        switch energy {
        case .hype: opener = "Let's go!"
        case .steady: opener = "Good set."
        case .calm: opener = "Nice."
        }
        let read: String
        switch delivery {
        case .warm: read = "You kept your chest up the whole way. That's real progress."
        case .balanced: read = "Depth was solid on all eight."
        case .direct: read = "Eight reps. Depth on every one."
        }
        guard tips == .full else { return "\(opener) \(read)" }
        let cue: String
        switch delivery {
        case .warm: cue = "Next set, think about pushing the floor away."
        case .balanced: cue = "Next set: brace before you drop."
        case .direct: cue = "Next set: brace harder at the bottom."
        }
        return "\(opener) \(read) \(cue)"
    }
}

// MARK: - The widget

struct CoachCustomizerView: View {
    enum Context { case firstRun, settings }

    let context: Context
    /// The profile's coaching tone. In settings this is the You screen's
    /// draft, so its Save bar persists it; on first run the caller saves.
    @Binding var delivery: CoachingTone
    var onDone: () -> Void

    @AppStorage(CoachingStyle.toneKey) private var energyRaw = CoachingStyle.Tone.hype.rawValue
    @AppStorage(CoachingStyle.tipsKey) private var tipsRaw = CoachingStyle.Tips.full.rawValue
    @AppStorage(CoachColor.storageKey) private var coachHex = CoachColor.defaultHex
    @AppStorage(YouColor.storageKey) private var youHex = YouColor.defaultHex

    @StateObject private var previewBody = BodyDirector()
    private static let quietVoice = VoiceMeter()

    private var energy: Binding<CoachingStyle.Tone> {
        Binding(get: { CoachingStyle.Tone(rawValue: energyRaw) ?? .hype },
                set: { energyRaw = $0.rawValue })
    }

    private var tips: Binding<CoachingStyle.Tips> {
        Binding(get: { CoachingStyle.Tips(rawValue: tipsRaw) ?? .full },
                set: { tipsRaw = $0.rawValue })
    }

    private var current: CoachPersonality? {
        CoachPersonality.matching(delivery: delivery, energy: energy.wrappedValue, tips: tips.wrappedValue)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MyoTheme.Spacing.lg) {
                header
                preview
                personalitySection
                fineTuneSection
                colorSection
            }
            .padding(.horizontal, MyoTheme.Spacing.md)
            .padding(.top, MyoTheme.Spacing.lg)
            .padding(.bottom, MyoTheme.Spacing.md)
        }
        .background(PaperBackground().ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { doneBar }
    }

    // MARK: Header + preview

    private var header: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.xs) {
            MyoSectionLabel(text: context == .firstRun ? "One last thing" : "Your coach")
            Text(context == .firstRun ? "Meet your coach." : "Make Coach yours.")
                .myoStyle(.display)
                .foregroundStyle(MyoColor.Text.primary.color)
            Text("Pick how it talks and what it looks like. Change it any time from You.")
                .myoStyle(.body)
                .foregroundStyle(MyoColor.Text.secondary.color)
        }
    }

    private var preview: some View {
        VStack(spacing: MyoTheme.Spacing.sm) {
            GeometryReader { geo in
                OrbView(
                    phase: .rest,
                    you: Self.quietVoice,
                    agent: Self.quietVoice,
                    focus: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2),
                    director: previewBody,
                    scale: 0.9
                )
            }
            .frame(height: 200)
            .clipped()
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: MyoTheme.Spacing.xs) {
                MyoSectionLabel(text: "After a set, Coach says")
                Text(CoachPersonality.sampleLine(delivery: delivery,
                                                 energy: energy.wrappedValue,
                                                 tips: tips.wrappedValue))
                    .myoStyle(.body)
                    .foregroundStyle(MyoColor.Text.primary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MyoTheme.Spacing.md)
            .myoCard()
            .animation(MyoTheme.Motion.fade, value: delivery)
            .animation(MyoTheme.Motion.fade, value: energyRaw)
            .animation(MyoTheme.Motion.fade, value: tipsRaw)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Personality

    private var personalitySection: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            HStack {
                MyoSectionLabel(text: "Personality")
                Spacer()
                if current == nil {
                    Text("Custom mix")
                        .myoStyle(.label)
                        .foregroundStyle(MyoTheme.Colors.ochre)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MyoTheme.Spacing.sm) {
                    ForEach(CoachPersonality.all) { personality in
                        personalityCard(personality)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
    }

    private func personalityCard(_ p: CoachPersonality) -> some View {
        let selected = current == p
        return Button {
            withAnimation(MyoTheme.Motion.fade) {
                delivery = p.delivery
                energy.wrappedValue = p.energy
                tips.wrappedValue = p.tips
            }
        } label: {
            VStack(alignment: .leading, spacing: MyoTheme.Spacing.xs) {
                Text(p.name)
                    .font(.body.weight(selected ? .bold : .semibold))
                    .foregroundStyle(MyoColor.Text.primary.color)
                Text(p.blurb)
                    .myoStyle(.detail)
                    .foregroundStyle(MyoColor.Text.secondary.color)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(width: 140, height: 96, alignment: .topLeading)
            .padding(MyoTheme.Spacing.md)
            .background(selected ? MyoColor.Surface.selected.color : MyoColor.Surface.elevated.color)
            .overlay(
                RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous)
                    .stroke(selected ? MyoTheme.Colors.ink : MyoColor.hairline, lineWidth: selected ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(p.name). \(p.blurb)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: Fine-tune

    private var fineTuneSection: some View {
        MyoGroupCard {
            MyoSectionLabel(text: "Fine-tune")
            StepDial<CoachingStyle.Tone>(title: "Energy",
                     stops: [(.calm, "Calm"), (.steady, "Steady"), (.hype, "Hype")],
                     selection: energy)
            MyoHairline()
            StepDial<CoachingTone>(title: "Delivery",
                     stops: [(.warm, "Warm"), (.balanced, "Balanced"), (.direct, "Direct")],
                     selection: $delivery)
            MyoHairline()
            StepDial<CoachingStyle.Tips>(title: "How much it talks",
                     stops: [(.quiet, "Just counts"), (.brief, "Short"), (.full, "Full tips")],
                     selection: tips)
        }
    }

    // MARK: Colour

    private var colorSection: some View {
        MyoGroupCard {
            MyoSectionLabel(text: "Body color")
            FlowLayout(spacing: MyoTheme.Spacing.sm) {
                ForEach(CoachColor.presets, id: \.hex) { preset in
                    Button {
                        withAnimation(MyoTheme.Motion.fade) { coachHex = preset.hex }
                    } label: {
                        Circle()
                            .fill(Color(hex: preset.hex))
                            .frame(width: 30, height: 30)
                            .overlay(Circle().stroke(MyoTheme.Colors.ink, lineWidth: coachHex == preset.hex ? 2 : 0).padding(-4))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.name)
                    .accessibilityAddTraits(coachHex == preset.hex ? [.isSelected] : [])
                }
                ColorPicker(
                    "Custom color",
                    selection: Binding(get: { Color(hex: coachHex) }, set: { coachHex = $0.hexString }),
                    supportsOpacity: false
                )
                .labelsHidden()
                .frame(width: 44, height: 44)
            }
            if CoachColor.clashes(coachHex, youHex) {
                Text("That's close to your color, so your words will be hard to see as they land.")
                    .myoStyle(.detail)
                    .foregroundStyle(MyoColor.State.warning.color)
            }
        }
    }

    // MARK: Done

    private var doneBar: some View {
        VStack(spacing: 0) {
            MyoHairline()
            Button(action: onDone) {
                Text(context == .firstRun ? "Start training" : "Done")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(MyoTheme.Colors.ink)
            .foregroundStyle(MyoTheme.Colors.cream)
            .padding(.horizontal, MyoTheme.Spacing.md)
            .padding(.vertical, MyoTheme.Spacing.sm)
        }
        .background(MyoTheme.Colors.cream)
    }
}

// MARK: - Snapping slider

/// A slider that snaps to a few named stops. Labels sit under the track;
/// the chosen one is bold, so the state survives without colour.
struct StepDial<Value: Hashable>: View {
    let title: String
    let stops: [(value: Value, label: String)]
    @Binding var selection: Value

    private var index: Binding<Double> {
        Binding(
            get: { Double(stops.firstIndex { $0.value == selection } ?? 0) },
            set: { new in
                let i = min(max(Int(new.rounded()), 0), stops.count - 1)
                if stops[i].value != selection {
                    withAnimation(MyoTheme.Motion.fade) { selection = stops[i].value }
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.xs) {
            Text(title)
                .myoStyle(.body)
                .foregroundStyle(MyoColor.Text.primary.color)
            Slider(value: index, in: 0...Double(max(stops.count - 1, 1)), step: 1)
                .tint(MyoTheme.Colors.brick)
                .accessibilityLabel(title)
                .accessibilityValue(stops.first { $0.value == selection }?.label ?? "")
            HStack {
                ForEach(Array(stops.enumerated()), id: \.offset) { i, stop in
                    if i > 0 { Spacer(minLength: 0) }
                    Text(stop.label)
                        .myoStyle(.label)
                        .fontWeight(stop.value == selection ? .bold : .regular)
                        .foregroundStyle(stop.value == selection ? MyoColor.Text.primary.color : MyoColor.Text.tertiary.color)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

// MARK: - First-run sheet

/// Wraps the widget for new users: edits a local copy of the coaching tone
/// and saves it to the profile when they tap "Start training".
struct CoachSetupSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var delivery: CoachingTone = .balanced
    var onFinish: () -> Void

    var body: some View {
        CoachCustomizerView(context: .firstRun, delivery: $delivery) {
            if delivery != appModel.profile.preferences.coachingTone {
                var next = appModel.profile
                next.preferences.coachingTone = delivery
                Task { await appModel.upsertProfile(next) }
            }
            onFinish()
        }
        .onAppear { delivery = appModel.profile.preferences.coachingTone }
    }
}

/// New users see the setup sheet once, after their first program is ready.
/// The flag is raised when onboarding is shown, so people who finished
/// onboarding before this shipped never get it sprung on them.
enum CoachSetup {
    static let pendingKey = "coachSetupPending"
}

#Preview {
    CoachCustomizerView(context: .firstRun, delivery: .constant(.balanced)) {}
}
