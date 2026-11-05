import SwiftUI

/// Pair a Bluetooth heart-rate strap: scan, pick, see it read your heart,
/// or forget it. Once paired, MYO connects to it at every workout start.
struct HeartStrapView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject private var strap = HeartStrapConnector.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MyoTheme.Spacing.xl) {
                if let name = strap.pairedName {
                    MyoGroupCard {
                        MyoSectionLabel(text: "Paired")
                        MyoValueRow(label: name) {
                            Text(reading)
                                .font(.body.monospacedDigit())
                                .foregroundStyle(MyoColor.Text.secondary.color)
                        }
                        Button("Forget this strap", role: .destructive) { strap.forget() }
                            .font(.footnote.weight(.semibold))
                    }
                }

                MyoGroupCard {
                    MyoSectionLabel(text: strap.pairedName == nil ? "Find your strap" : "Pair a different one")
                    switch strap.status {
                    case .bluetoothOff:
                        note("Bluetooth is off. Turn it on in Control Center.")
                    case .notAllowed:
                        note("MYO isn't allowed to use Bluetooth. Turn it on in Settings → MYO.")
                    default:
                        if strap.status == .scanning {
                            HStack(spacing: MyoTheme.Spacing.sm) {
                                ProgressView()
                                note("Looking… wear the strap (a dry strap may not wake up).")
                            }
                        } else {
                            Button("Scan for straps") { strap.startScan() }
                                .font(.body.weight(.semibold))
                                .tint(MyoTheme.Colors.ink)
                        }
                        ForEach(strap.found.filter { $0.name != strap.pairedName }) { item in
                            Button {
                                strap.pair(item)
                            } label: {
                                HStack {
                                    Text(item.name).foregroundStyle(MyoColor.Text.primary.color)
                                    Spacer()
                                    Text("Pair").font(.footnote.weight(.semibold))
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                MyoGroupCard {
                    MyoSectionLabel(text: "Works with")
                    note("Any strap or band using the standard Bluetooth heart rate profile: Polar H9/H10/Verity, Wahoo TICKR, most chest straps.")
                    note("Garmin watch: turn on Broadcast Heart Rate on the watch before you start.")
                    note("Whoop: turn on Heart Rate Broadcast in the Whoop app.")
                    note("With an Apple Watch on too, the Watch's heart rate is used and the strap is the backup.")
                }
            }
            .padding(MyoTheme.Spacing.md)
        }
        .background(PaperBackground())
        .navigationTitle("Heart rate strap")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Show a live reading from the paired strap while you're here.
            if strap.pairedName != nil { strap.connect() }
        }
        .onDisappear {
            strap.stopScan()
            // Keep it connected only if a workout is running.
            if appModel.activeWorkout == nil { strap.disconnect() }
        }
    }

    private var reading: String {
        switch strap.status {
        case .connected: return strap.lastBpm.map { "\($0) bpm" } ?? "Connected"
        case .connecting: return "Connecting…"
        case .scanning: return "Looking…"
        default: return "Not connected"
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(MyoColor.Text.secondary.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
