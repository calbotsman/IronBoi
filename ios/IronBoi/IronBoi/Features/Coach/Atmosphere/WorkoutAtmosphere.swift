import QuartzCore
import SwiftUI

/// The paper's weather during a workout: colour and grain that follow your
/// effort (Atmosphere.metal). Sits between the paper and everything else;
/// draws nothing outside a workout, so the rest of the app costs nothing.
struct WorkoutAtmosphere: View {
    var active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(CoachColor.storageKey) private var coachHex = CoachColor.defaultHex

    /// 30 fps is plenty: effort moves over seconds and the fastest grain
    /// re-seeds at 10 Hz. The orb above keeps its own 60. Under Reduce
    /// Motion the grain is still, so once a second is enough for the colour.
    private static let frameInterval: TimeInterval = 1.0 / 30

    var body: some View {
        ZStack {
            if active {
                TimelineView(.animation(minimumInterval: reduceMotion ? 1 : Self.frameInterval)) { timeline in
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.white)
                            .colorEffect(ShaderLibrary.workoutAtmosphere(
                                .float2(geo.size),
                                // Wrapped so float precision holds over a long session.
                                .float(reduceMotion ? 0 : Float(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))),
                                .float(EffortSignal.shared.current()),
                                .color(MyoTheme.Colors.cream),
                                .color(Color(hex: coachHex)),
                                .color(MyoTheme.Colors.ink),
                                .float(PaperStore.shared.paper.isDark ? 1 : 0)
                            ))
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 1.6), value: active)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
