import SwiftUI

/// The MYO Watch app in the phone's visual language: cream paper with its
/// grain (PaperBackground, shared with the phone), MyoTheme ink and amber,
/// mono uppercase labels, and the MYO body as a soft breathing blob.
///
/// Three pages, swiped vertically: Now (heart rate, calories, the lift),
/// Controls (Set done, pause, end) and Coach (the latest line). Nothing on
/// them is made up: every number is the session's own reading or what the
/// phone sent.
struct WatchRootView: View {
    @EnvironmentObject private var workout: WatchWorkoutManager
    @State private var page = WatchRootView.initialPage

    var body: some View {
        // In a NavigationStack so the system clock can be told it sits on
        // light paper (toolbarColorScheme); otherwise it's white on cream.
        NavigationStack {
            content
                .toolbarColorScheme(.light, for: .navigationBar)
        }
        .preferredColorScheme(.light)
    }

    @ViewBuilder private var content: some View {
        Group {
            switch workout.phase {
            case .idle:
                Message(label: "MYO", title: "Ready when you are", text: "Start a workout on your iPhone. MYO opens here by itself.")
            case .starting:
                Message(label: "Starting", title: nil, text: nil)
            case .failed(let reason):
                Message(label: "Couldn't start", title: nil, text: reason)
            case .ended(let saved):
                Message(label: "Workout done", title: "Nice work",
                        text: saved ? "Saved to Apple Health." : "Not saved to Health (off in MYO on your iPhone).")
            case .running, .paused, .ending:
                TabView(selection: $page) {
                    NowPage().tag(0).paper()
                    ControlsPage().tag(1).paper()
                    CaptionPage().tag(2).paper()
                }
                .tabViewStyle(.verticalPage)
            }
        }
    }

    /// MYO_WATCH_PAGE=1/2 opens on Controls/Coach, for simulator screenshots.
    private static var initialPage: Int {
        #if DEBUG
        return ProcessInfo.processInfo.environment["MYO_WATCH_PAGE"].flatMap(Int.init) ?? 0
        #else
        return 0
        #endif
    }
}

// MARK: - Shared pieces

private extension View {
    /// The phone's cream paper behind a page of the vertical TabView.
    func paper() -> some View {
        containerBackground(for: .tabView) { PaperBackground() }
    }
}

/// UPPERCASE mono marginalia, as on the phone (`.myoStyle(.label)`).
private struct MarginLabel: View {
    let text: String
    var color: Color = MyoColor.Text.tertiary.color
    var body: some View {
        Text(text.uppercased())
            .myoStyle(.label)
            .kerning(0.8)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// The MYO body: a soft blue blob with a lighter heart, a glow and the
/// paper's grain, breathing slowly. Plain SwiftUI shapes (no Metal on
/// watchOS), still in Always-On.
struct WatchBlob: View {
    var size: CGFloat
    var breathing = true
    @Environment(\.isLuminanceReduced) private var alwaysOn
    @State private var inhale = false

    /// The brand blue (YouColor's default, #4285F4) and a paler heart.
    static let body = Color(hex: YouColor.defaultHex)
    static let heart = Color(hex: "A9C6FA")

    var body: some View {
        ZStack {
            Circle()
                .fill(Self.body.opacity(0.28))
                .frame(width: size * 1.25, height: size * 1.25)
                .blur(radius: size * 0.16)
            Circle()
                .fill(RadialGradient(colors: [Self.heart, Self.body.opacity(0.92)], center: .center,
                                     startRadius: 0, endRadius: size * 0.55))
                .overlay(
                    PaperTexture.image
                        .resizable(resizingMode: .tile)
                        .opacity(0.5)
                        .blendMode(.multiply)
                        .clipShape(Circle())
                )
                .frame(width: size, height: size)
                .blur(radius: size * 0.035)
        }
        .scaleEffect(breathing && !alwaysOn ? (inhale ? 1.04 : 0.96) : 1)
        .opacity(alwaysOn ? 0.5 : 1)
        .animation(breathing && !alwaysOn ? .easeInOut(duration: 3.2).repeatForever(autoreverses: true) : .default,
                   value: inhale)
        .onAppear { inhale = true }
        .accessibilityHidden(true)
    }
}

private struct Message: View {
    let label: String
    let title: String?
    let text: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                WatchBlob(size: 64)
                    .frame(height: 84)
                MarginLabel(text: label)
                if let title {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(MyoColor.Text.primary.color)
                }
                if let text {
                    Text(text)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(MyoColor.Text.secondary.color)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(PaperBackground())
    }
}

/// Zone 1–5 in the phone's palette: calm is quiet ink, hard is amber, max is the red pen.
private func zoneColor(_ zone: Int?) -> Color {
    switch zone {
    case 3: return MyoTheme.Colors.sage
    case 4: return MyoTheme.Colors.ochre
    case 5: return MyoTheme.Colors.brick
    default: return MyoColor.Text.tertiary.color
    }
}

// MARK: - Now

private struct NowPage: View {
    @EnvironmentObject private var workout: WatchWorkoutManager
    @Environment(\.isLuminanceReduced) private var alwaysOn

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let resting = workout.state?.restEndsAt.map { $0 > now } ?? false
            VStack(spacing: 4) {
                // Clear of the page dots on the right edge.
                if !alwaysOn { StatusLine(now: now).padding(.trailing, 10) }
                HStack(alignment: .center, spacing: 8) {
                    HeartBlob(now: now, restEnds: resting ? workout.state?.restEndsAt : nil)
                    if !alwaysOn { Calories() }
                }
                if resting, let ends = workout.state?.restEndsAt {
                    MarginLabel(text: "Rest · \(Self.clock(ends.timeIntervalSince(now)))", color: MyoTheme.Colors.ochre)
                    if !alwaysOn, let next = workout.state?.nextExercise {
                        Text("Next: \(next)")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(MyoColor.Text.primary.color)
                            .lineLimit(1)
                    }
                } else if !alwaysOn {
                    ExerciseLines()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// "IN PROGRESS 23:41", like the phone's live card; "PAUSED" in the red pen.
private struct StatusLine: View {
    @EnvironmentObject private var workout: WatchWorkoutManager
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            MarginLabel(text: workout.phase == .paused ? "Paused" : workout.phase == .ending ? "Finishing" : "In progress",
                  color: MyoColor.redPen)
            if let started = workout.startedAt {
                Text(NowPage.clock(now.timeIntervalSince(started)))
                    .myoStyle(.label)
                    .monospacedDigit()
                    .foregroundStyle(MyoColor.Text.tertiary.color)
            }
        }
    }
}

/// The big heart rate, on the MYO body. During rest an amber ring around
/// it empties as the rest runs down.
private struct HeartBlob: View {
    @EnvironmentObject private var workout: WatchWorkoutManager
    @Environment(\.isLuminanceReduced) private var alwaysOn
    let now: Date
    let restEnds: Date?
    @State private var restTotal: TimeInterval?

    var body: some View {
        // A reading older than 15 s is not "now": show nothing rather than a stale number.
        let fresh = workout.bpmAt.map { now.timeIntervalSince($0) <= 15 } ?? false
        let zone = fresh ? workout.zone : nil
        ZStack {
            WatchBlob(size: 78)
            if let restEnds {
                let left = max(0, restEnds.timeIntervalSince(now))
                let full = max(restTotal ?? left, left, 1)
                Circle()
                    .trim(from: 0, to: left / full)
                    .stroke(MyoTheme.Colors.coachAmber, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 92, height: 92)
            }
            VStack(spacing: -2) {
                Text(fresh ? "\(workout.bpm ?? 0)" : "--")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(MyoColor.Text.primary.color)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 3) {
                    Image(systemName: "heart.fill").font(.system(size: 9))
                    Text(zone.map { "Z\($0)" } ?? "BPM").myoStyle(.label)
                }
                .foregroundStyle(zone.map(zoneColor) ?? MyoColor.Text.secondary.color)
            }
        }
        .frame(width: 96, height: 96)
        .onAppear { restTotal = restEnds.map { $0.timeIntervalSince(now) } }
        .onChange(of: restEnds) { _, ends in restTotal = ends.map { $0.timeIntervalSinceNow } }
    }
}

private struct Calories: View {
    @EnvironmentObject private var workout: WatchWorkoutManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(workout.activeKcal.map { "\(Int($0.rounded()))" } ?? "--")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(MyoColor.Text.primary.color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            MarginLabel(text: "Kcal")
        }
    }
}

private struct ExerciseLines: View {
    @EnvironmentObject private var workout: WatchWorkoutManager

    var body: some View {
        VStack(spacing: 1) {
            if let state = workout.state {
                Text(state.exercise ?? state.workoutName)
                    .font(.system(.headline, design: .default).weight(.semibold))
                    .foregroundStyle(MyoColor.Text.primary.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let line = Self.setLine(state) {
                    Text(line)
                        .myoStyle(.numeric)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(MyoColor.Text.secondary.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } else {
                MarginLabel(text: "Connecting to iPhone")
            }
        }
    }

    /// "Set 2/4 · 5 × 315 lb" — the phone's set line, narrowed for the Watch.
    static func setLine(_ state: WatchWorkoutState) -> String? {
        var parts: [String] = []
        if let set = state.setNumber, let total = state.totalSets { parts.append("Set \(set)/\(total)") }
        let reps = state.targetReps.flatMap { $0 > 0 ? $0 : nil }
        let weight = state.weightLb.flatMap { $0 > 0 ? $0 : nil }
            .map { $0.rounded() == $0 ? "\(Int($0)) lb" : String(format: "%.1f lb", $0) }
        switch (reps, weight) {
        case let (r?, w?): parts.append("\(r) × \(w)")
        case let (r?, nil): parts.append("\(r) reps")
        case let (nil, w?): parts.append(w)
        default: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Controls

private struct ControlsPage: View {
    @EnvironmentObject private var workout: WatchWorkoutManager
    @State private var confirmEnd = false

    var body: some View {
        VStack(spacing: 10) {
            if let state = workout.state, let set = state.setNumber, let total = state.totalSets {
                MarginLabel(text: "Set \(set) of \(total)")
            } else {
                MarginLabel(text: "Controls")
            }

            // The phone's amber capsule (its mic button), as the one big action.
            Button {
                workout.setDone()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.body.weight(.bold))
                    Text("Set done").font(.headline)
                }
                .foregroundStyle(MyoTheme.Colors.ink)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Capsule().fill(MyoTheme.Colors.ochreLight))
                .overlay(Capsule().stroke(MyoTheme.Colors.coachAmber.opacity(0.6), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .disabled(workout.state?.exercise == nil || workout.phase != .running)
            .opacity(workout.state?.exercise == nil || workout.phase != .running ? 0.45 : 1)

            HStack(spacing: 16) {
                RoundButton(systemImage: workout.phase == .paused ? "play.fill" : "pause.fill",
                            tint: MyoTheme.Colors.ink, label: workout.phase == .paused ? "Resume" : "Pause") {
                    workout.togglePause()
                }
                .disabled(workout.phase == .ending)
                RoundButton(systemImage: "xmark", tint: MyoColor.redPen, label: "End") {
                    confirmEnd = true
                }
                .disabled(workout.phase == .ending)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("End this workout?", isPresented: $confirmEnd) {
            Button("End workout", role: .destructive) { workout.requestEnd() }
        }
    }
}

/// The phone's secondary round button (its keyboard button): a raised cream disc.
private struct RoundButton: View {
    let systemImage: String
    let tint: Color
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(MyoTheme.Colors.creamElevated))
                    .overlay(Circle().stroke(MyoColor.hairline, lineWidth: 1))
                    .shadow(color: MyoTheme.Colors.shadow.opacity(0.08), radius: 4, y: 2)
                MarginLabel(text: label)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Coach

private struct CaptionPage: View {
    @EnvironmentObject private var workout: WatchWorkoutManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    WatchBlob(size: 16, breathing: false).frame(width: 22, height: 22)
                    MarginLabel(text: "Coach")
                }
                if let caption = workout.state?.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.system(.title3, design: .default).weight(.medium))
                        .foregroundStyle(MyoColor.Text.primary.color)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Your coach's latest line shows here.")
                        .font(.footnote)
                        .foregroundStyle(MyoColor.Text.secondary.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
