import Foundation
import SwiftUI

/// The knobs behind the blob's physics, in one place, so they can be tuned
/// live in the simulator (MYO_TUNER=1, DEBUG only) and the winning values
/// baked back in here as the defaults. One `shared` instance: the orb model
/// reads it every frame on the main thread, the tuner writes it.
///
/// Round 1 — mass. The blob squashes and stretches along the direction it is
/// moving, and a landing flattens it along the direction it arrived from,
/// harder the faster it was going. Before this, squash was vertical-only and
/// the one impulse was a constant kick when the person folded back in.
final class OrbPhysics: ObservableObject {
    static let shared = OrbPhysics()

    // MARK: Squash spring (the blob's one true spring)

    /// How quickly the blob springs back to round, in rad/s. Higher = snappier.
    @Published var squashStiffness: Float = 13
    /// 0 = rings forever, 1 = no wobble at all. ~0.35 gives two or three wobbles.
    @Published var squashDamping: Float = 0.35

    // MARK: Mass

    /// Elongation along the direction of travel, per unit of speed (shader
    /// units per second). 0 = a moving blob stays round.
    @Published var stretchGain: Float = 0.12
    /// Cap on how long the blob can get while moving (1 = round).
    @Published var stretchMax: Float = 1.35
    /// The flatten on arrival when the person folds into the blob, before
    /// speed is counted. Was the only impulse (2.4) before round 1.
    @Published var landKick: Float = 2.4
    /// Extra flatten per unit of arrival speed.
    @Published var landKickPerSpeed: Float = 1.5
    /// How quickly the remembered arrival speed fades (1/s): higher = only
    /// the very last moment counts.
    @Published var arrivalMemory: Float = 4
    /// Below this speed the blob treats itself as still: the squash axis
    /// holds and no stretch is applied.
    @Published var restSpeed: Float = 0.05
    /// How fast the squash axis turns to follow a new direction (1/s).
    @Published var axisFollow: Float = 10

    var reduceMotionScale: Float = 1

    private init() {}

    // MARK: Copy / paste

    var asJSON: String {
        let pairs: [(String, Float)] = [
            ("squashStiffness", squashStiffness), ("squashDamping", squashDamping),
            ("stretchGain", stretchGain), ("stretchMax", stretchMax),
            ("landKick", landKick), ("landKickPerSpeed", landKickPerSpeed),
            ("restSpeed", restSpeed), ("axisFollow", axisFollow),
            ("arrivalMemory", arrivalMemory),
        ]
        let body = pairs.map { "  \"\($0.0)\": \(String(format: "%.3f", $0.1))" }.joined(separator: ",\n")
        return "{\n\(body)\n}"
    }

    func resetToDefaults() {
        squashStiffness = 13
        squashDamping = 0.35
        stretchGain = 0.12
        stretchMax = 1.35
        landKick = 2.4
        landKickPerSpeed = 1.5
        arrivalMemory = 4
        restSpeed = 0.05
        axisFollow = 10
    }
}

#if DEBUG
/// The live tuner, shown over the Coach screen with MYO_TUNER=1. Sliders
/// write straight into `OrbPhysics.shared`; "Copy" puts the values on the
/// clipboard as JSON to paste back for baking in.
struct OrbPhysicsTuner: View {
    @ObservedObject var physics = OrbPhysics.shared
    @State private var open = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { open.toggle() }
            } label: {
                Text(open ? "Close" : "Physics")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 6) {
                    row("stiffness", $physics.squashStiffness, 4...30)
                    row("damping", $physics.squashDamping, 0.05...1)
                    row("stretch gain", $physics.stretchGain, 0...0.5)
                    row("stretch max", $physics.stretchMax, 1...1.8)
                    row("land kick", $physics.landKick, 0...4)
                    row("kick / speed", $physics.landKickPerSpeed, 0...4)
                    row("arrival memory", $physics.arrivalMemory, 1...12)
                    row("rest speed", $physics.restSpeed, 0...0.3)
                    row("axis follow", $physics.axisFollow, 1...30)
                    HStack {
                        Button("Reset") { physics.resetToDefaults() }
                        Spacer()
                        Button(copied ? "Copied" : "Copy") {
                            UIPasteboard.general.string = physics.asJSON
                            copied = true
                            Task { try? await Task.sleep(nanoseconds: 1_200_000_000); copied = false }
                        }
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(12)
                .frame(width: 260)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        // Below the profile button, so the two never overlap.
        .padding(.trailing, 12)
        .padding(.top, 56)
    }

    private func row(_ name: String, _ value: Binding<Float>, _ range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(name).font(.caption2)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue)).font(.caption2.monospacedDigit())
            }
            Slider(value: value, in: range)
        }
    }
}
#endif
