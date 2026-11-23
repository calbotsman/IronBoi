import SwiftUI

/// Three glanceable pages, swiped vertically: Now, Controls, Caption.
/// Nothing on them is made up: every number is the session's own heart
/// rate or what the phone sent.
///
/// Dressed like the phone app: the paper you picked, ink type, mono labels,
/// ochre for what's moving and brick for "in progress", and the coach's
/// colour glowing behind, stronger the harder you work. Wrist down, it dims
/// to the Night paper with no glow, as Always On needs.
struct WatchRootView: View {
    @EnvironmentObject private var workout: WatchWorkoutManager
    @Environment(\.isLuminanceReduced) private var alwaysOn

    private var look: WatchLook {
        WatchLook.from(paperId: workout.state?.paperId, coachHex: workout.state?.coachHex, alwaysOn: alwaysOn)
    }

    var body: some View {
        Group {
            switch workout.phase {
            case .idle:
                Message(title: nil, text: "Start a workout on your iPhone. MYO opens here by itself.")
            case .starting:
                Message(title: nil, text: "Starting…")
            case .failed(let reason):
                Message(title: "Couldn't start", text: reason)
            case .ended(let saved):
                Message(title: "Workout done", text: saved ? "Saved to Apple Health." : "Not saved to Health (off in MYO on your iPhone).")
            case .running, .paused, .ending:
                TabView {
                    NowPage().containerBackground(for: .tabView) { Atmosphere() }
                    ControlsPage().containerBackground(for: .tabView) { look.paper }
                    CaptionPage().containerBackground(for: .tabView) { look.paper }
                }
                .tabViewStyle(.verticalPage)
            }
        }
        .environment(\.watchLook, look)
        .tint(WatchLook.ochre)
    }
}

// MARK: - Look

private struct WatchLookKey: EnvironmentKey {
    static let defaultValue = WatchLook.from(paperId: nil, coachHex: nil)
}

extension EnvironmentValues {
    var watchLook: WatchLook {
        get { self[WatchLookKey.self] }
        set { self[WatchLookKey.self] = newValue }
    }
}

private enum Mono {
    /// The phone's annotation voice: SF Mono, for labels and numbers.
    static func label(_ size: CGFloat = 11, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// The phone's workout weather, Watch-sized: paper, with the coach's colour
/// rising through it as effort climbs.
private struct Atmosphere: View {
    @EnvironmentObject private var workout: WatchWorkoutManager
    @Environment(\.watchLook) private var look
    @Environment(\.isLuminanceReduced) private var alwaysOn

    var body: some View {
        ZStack {
            look.paper
            if !alwaysOn {
                RadialGradient(colors: [look.coach.opacity(0.16 + 0.42 * effort), look.coach.opacity(0)],
                               center: .center, startRadius: 0, endRadius: 150)
                    .animation(.easeInOut(duration: 2), value: effort)
            }
        }
        .ignoresSafeArea()
    }

    /// 0 calm … 1 pumping, from your share of max heart rate (55% … 90%), as on the phone.
    private var effort: Double {
        guard let bpm = workout.bpm else { return workout.state?.restEndsAt == nil ? 0.5 : 0.15 }
        let maxHR = 208 - 0.7 * Double(workout.state?.ageYears ?? 35)
        return min(max((Double(bpm) / maxHR - 0.55) / 0.35, 0), 1)
    }
}

private struct Message: View {
    @Environment(\.watchLook) private var look
    let title: String?
    let text: String
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                (Text("MYO").foregroundStyle(look.ink) + Text(".").foregroundStyle(WatchLook.ochre))
                    .font(.system(size: 26, weight: .bold))
                if let title {
                    Text(title).font(.headline).foregroundStyle(look.ink)
                }
                Text(text).font(.footnote).multilineTextAlignment(.center).foregroundStyle(look.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .containerBackground(look.paper, for: .navigation)
        .background(look.paper.ignoresSafeArea())
    }
}

// MARK: - Now

private struct NowPage: View {
    @EnvironmentObject private var workout: WatchWorkoutManager
    @Environment(\.watchLook) private var look
    @Environment(\.isLuminanceReduced) private var alwaysOn

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 6) {
                HeartPill(now: context.date)
                Spacer(minLength: 0)
                if let ends = workout.state?.restEndsAt, ends > context.date {
                    RestBlock(ends: ends, now: context.date, compact: alwaysOn)
                } else {
                    ExerciseLines()
                }
                Spacer(minLength: 0)
                if workout.phase == .paused, !alwaysOn {
                    Text("PAUSED").font(Mono.label(11, .semibold)).foregroundStyle(WatchLook.brick)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The phone's stats pill: heart, number, zone, on a raised sheet of paper.
private struct HeartPill: View {
    @EnvironmentObject private var workout: WatchWorkoutManager
    @Environment(\.watchLook) private var look
    @Environment(\.isLuminanceReduced) private var alwaysOn
    let now: Date

    var body: some View {
        // A reading older than 15 s is not "now": show nothing rather than a stale number.
        let fresh = workout.bpmAt.map { now.timeIntervalSince($0) <= 15 } ?? false
        HStack(spacing: 5) {
            Image(systemName: "heart.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(look.coach)
                .symbolEffect(.pulse, options: .repeating, isActive: fresh && !alwaysOn)
            Text(fresh ? "\(workout.bpm ?? 0)" : "--")
                .font(Mono.label(17, .semibold))
                .monospacedDigit()
                .foregroundStyle(look.ink)
                .contentTransition(.numericText())
            if fresh, let zone = workout.zone {
                Text("·").foregroundStyle(look.tertiary)
                Text("Z\(zone)").font(Mono.label(13)).foregroundStyle(look.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Capsule().fill(look.raised.opacity(alwaysOn ? 0.6 : 0.9)))
        .overlay(Capsule().stroke(look.hairline, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fresh ? "Heart rate \(workout.bpm ?? 0)" + (workout.zone.map { ", zone \($0)" } ?? "") : "No heart rate yet")
    }
}

/// Rest as on the phone: a mono REST label, the clock big and light, what's next.
private struct RestBlock: View {
    @EnvironmentObject private var workout: WatchWorkoutManager
    @Environment(\.watchLook) private var look
    let ends: Date
    let now: Date
    let compact: Bool
    @State private var total: TimeInterval?

    var body: some View {
        let left = max(0, ends.timeIntervalSince(now))
        // The ring's full length is the rest as first seen, so it empties evenly.
        let full = max(total ?? left, left, 1)
        let secs = Int(left.rounded(.up))
        ZStack {
            if !compact {
                Circle().stroke(look.hairline, lineWidth: 3)
                Circle().trim(from: 0, to: left / full)
                    .stroke(WatchLook.ochre, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: left)
            }
            VStack(spacing: 0) {
                Text("REST").font(Mono.label(10)).tracking(1.5).foregroundStyle(look.tertiary)
                Text(String(format: "%d:%02d", secs / 60, secs % 60))
                    .font(.system(size: 38, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(look.ink)
                    .contentTransition(.numericText(countsDown: true))
                if !compact, let next = workout.state?.nextExercise ?? workout.state?.exercise {
                    Text("Next: \(next)").font(.system(size: 12)).lineLimit(1).foregroundStyle(look.secondary)
                        .frame(maxWidth: 100)
                }
            }
        }
        .frame(width: 128, height: 128)
        .onAppear { total = left }
        .onChange(of: ends) { _, newEnds in total = max(0, newEnds.timeIntervalSinceNow) }
    }
}

/// The phone's live workout card, without the card: IN PROGRESS, the lift, the set.
private struct ExerciseLines: View {
    @EnvironmentObject private var workout: WatchWorkoutManager
    @Environment(\.watchLook) private var look

    var body: some View {
        VStack(spacing: 4) {
            if let state = workout.state {
                Text("IN PROGRESS").font(Mono.label(10, .semibold)).tracking(1.2)
                    .foregroundStyle(look.isDark ? WatchLook.brickLight : WatchLook.brick)
                if let exercise = state.exercise {
                    Text(exercise).font(.system(size: 20, weight: .semibold)).lineLimit(2)
                        .multilineTextAlignment(.center).foregroundStyle(look.ink)
                    if let line = Self.setLine(state) {
                        Text(line).font(Mono.label(10)).foregroundStyle(look.secondary)
                            .multilineTextAlignment(.center).minimumScaleFactor(0.8).lineLimit(1)
                    }
                } else {
                    Text(state.workoutName).font(.system(size: 20, weight: .semibold)).foregroundStyle(look.ink)
                }
            } else {
                Text("Connecting to your iPhone…").font(.footnote).foregroundStyle(look.secondary)
            }
        }
    }

    /// "Set 2 of 4 · 10 reps · 95 lb"
    static func setLine(_ state: WatchWorkoutState) -> String? {
        var parts: [String] = []
        if let set = state.setNumber, let total = state.totalSets { parts.append("Set \(set) of \(total)") }
        if let reps = state.targetReps, reps > 0 { parts.append("\(reps) reps") }
        if let weight = state.weightLb, weight > 0 {
            parts.append(weight.rounded() == weight ? "\(Int(weight)) lb" : String(format: "%.1f lb", weight))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Controls

private struct ControlsPage: View {
    @EnvironmentObject private var workout: WatchWorkoutManager
    @Environment(\.watchLook) private var look
    @State private var confirmEnd = false

    var body: some View {
        VStack(spacing: 10) {
            Button {
                workout.setDone()
            } label: {
                Label("Set done", systemImage: "checkmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(look.ink)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Capsule().fill(look.raised))
                    .overlay(Capsule().stroke(WatchLook.ochre, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .disabled(workout.state?.exercise == nil || workout.phase != .running)
            .opacity(workout.state?.exercise == nil || workout.phase != .running ? 0.4 : 1)

            HStack(spacing: 10) {
                RoundButton(systemImage: workout.phase == .paused ? "play.fill" : "pause.fill", color: look.ink) {
                    workout.togglePause()
                }
                .disabled(workout.phase == .ending)
                RoundButton(systemImage: "xmark", color: WatchLook.brick) {
                    confirmEnd = true
                }
                .disabled(workout.phase == .ending)
            }
        }
        .padding(.horizontal, 4)
        .confirmationDialog("End this workout?", isPresented: $confirmEnd) {
            Button("End workout", role: .destructive) { workout.requestEnd() }
        }
    }
}

private struct RoundButton: View {
    @Environment(\.watchLook) private var look
    let systemImage: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(Capsule().fill(look.raised))
                .overlay(Capsule().stroke(look.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Caption

private struct CaptionPage: View {
    @EnvironmentObject private var workout: WatchWorkoutManager
    @Environment(\.watchLook) private var look

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("COACH").font(Mono.label(10)).tracking(1.5).foregroundStyle(look.tertiary)
                if let caption = workout.state?.caption, !caption.isEmpty {
                    Text(caption).font(.system(size: 16)).foregroundStyle(look.ink)
                } else {
                    Text("Your coach's latest line shows here.").font(.footnote).foregroundStyle(look.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
