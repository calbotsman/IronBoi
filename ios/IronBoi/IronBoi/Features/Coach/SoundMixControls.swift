import SwiftUI

/// Coach's voice against your music: voice on or captions only, Coach's
/// level, and how much the music dips. The same controls in the workout
/// (the speaker button by the mic) and in Preferences. Every change is
/// heard at once.
struct SoundMixControls: View {
    @AppStorage(CoachMix.voiceOnKey) private var voiceOn = true
    @AppStorage(CoachMix.voiceLevelKey) private var level = CoachMix.defaultVoiceLevel
    @AppStorage(CoachMix.musicDipKey) private var dipRaw = CoachMix.defaultDip.rawValue
    /// False while live voice owns the mic: a new dip waits for the next session.
    var canRetake = true

    private var dip: Binding<CoachMix.MusicDip> {
        Binding(get: { CoachMix.MusicDip(rawValue: dipRaw) ?? CoachMix.defaultDip },
                set: { dipRaw = $0.rawValue })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
            MyoValueRow(label: "Coach talks") {
                Toggle("Coach talks", isOn: $voiceOn).labelsHidden()
            }
            Text(voiceOn
                 ? "Coach answers out loud. The mic stays on so you can count and cut in."
                 : "Captions only: the mic still counts and listens, answers show on screen, and your music is never lowered.")
                .font(.caption)
                .foregroundStyle(MyoColor.Text.tertiary.color)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Coach's voice")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(MyoColor.Text.secondary.color)
                    HStack(spacing: MyoTheme.Spacing.sm) {
                        Image(systemName: "speaker.fill").font(.caption)
                        Slider(value: $level, in: 0...1) { Text("Coach's voice") }
                        Image(systemName: "speaker.wave.3.fill").font(.caption)
                    }
                    .foregroundStyle(MyoColor.Text.tertiary.color)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Music dips")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(MyoColor.Text.secondary.color)
                    Picker("Music dips", selection: dip) {
                        ForEach(CoachMix.MusicDip.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(dip.wrappedValue.detail)
                        .font(.caption)
                        .foregroundStyle(MyoColor.Text.tertiary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!voiceOn)
            .opacity(voiceOn ? 1 : 0.4)
        }
        .onChange(of: voiceOn) { _, _ in AudioHub.shared.applyMix(retake: canRetake) }
        .onChange(of: level) { _, _ in AudioHub.shared.applyMix(retake: canRetake) }
        .onChange(of: dipRaw) { _, _ in AudioHub.shared.applyMix(retake: canRetake) }
    }
}

/// The in-workout sheet around the controls.
struct SoundMixSheet: View {
    var canRetake = true

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
            Text("Sound")
                .myoStyle(.title)
                .foregroundStyle(MyoColor.Text.primary.color)
            SoundMixControls(canRetake: canRetake)
        }
        .padding(MyoTheme.Spacing.lg)
        .presentationDetents([.height(400)])
        .presentationDragIndicator(.visible)
    }
}
