import SwiftUI

/// Three glanceable pages, swiped vertically: Now, Controls, Caption.
/// Nothing on them is made up: every number is the session's own heart
/// rate or what the phone sent.
struct WatchRootView: View {
    @EnvironmentObject private var workout: WatchWorkoutManager

    var body: some View {
        switch workout.phase {
        case .idle:
            Message(title: "MYO", text: "Start a workout on your iPhone. MYO opens here by itself.")
        case .starting:
            ProgressView("Starting…")
        case .failed(let reason):
            Message(title: "Couldn't start", text: reason)
        case .ended(let saved):
            Message(title: "Workout done", text: saved ? "Saved to Apple Health." : "Not saved to Health (off in MYO on your iPhone).")
        case .running, .paused, .ending:
            TabView {
                NowPage()
                ControlsPage()
                CaptionPage()
            }
            .tabViewStyle(.verticalPage)
        }
    }
}

private struct Message: View {
    let title: String
    let text: String
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(title).font(.headline)
                Text(text).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Now

private struct NowPage: View {
    @EnvironmentObject private var workout: WatchWorkoutManager
    @Environment(\.isLuminanceReduced) private var alwaysOn

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 4) {
                HeartReadout(now: context.date)
                if let ends = workout.state?.restEndsAt, ends > context.date {
                    RestRing(ends: ends, now: context.date, compact: alwaysOn)
                    if !alwaysOn, let next = workout.state?.nextExercise {
                        Text("next: \(next)").font(.footnote).lineLimit(1)
                    }
                } else if !alwaysOn {
                    ExerciseLines()
                }
                if workout.phase == .paused, !alwaysOn {
                    Text("Paused").font(.footnote).foregroundStyle(.yellow)
                }
            }
        }
    }
}

private struct HeartReadout: View {
    @EnvironmentObject private var workout: WatchWorkoutManager
    let now: Date

    var body: some View {
        // A reading older than 15 s is not "now": show nothing rather than a stale number.
        let fresh = workout.bpmAt.map { now.timeIntervalSince($0) <= 15 } ?? false
        let zone = fresh ? workout.bpm.flatMap {
            HeartZones.zone(bpm: $0, ageYears: workout.state?.ageYears, observedPeak: workout.peakBpm)
        } : nil
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(fresh ? "\(workout.bpm ?? 0)" : "--")
                .font(.system(size: 48, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Self.color(zone: zone))
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "heart.fill").foregroundStyle(.red)
                Text(zone.map { "Z\($0)" } ?? "BPM").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    static func color(zone: Int?) -> Color {
        switch zone {
        case 1: return .gray
        case 2: return .blue
        case 3: return .green
        case 4: return .orange
        case 5: return .red
        default: return .primary
        }
    }
}

private struct RestRing: View {
    @EnvironmentObject private var workout: WatchWorkoutManager
    let ends: Date
    let now: Date
    let compact: Bool
    @State private var total: TimeInterval?

    var body: some View {
        let left = max(0, ends.timeIntervalSince(now))
        // The ring's full length is the rest as first seen, so it empties evenly.
        let full = max(total ?? left, left, 1)
        ZStack {
            if !compact {
                Circle().stroke(.gray.opacity(0.3), lineWidth: 5)
                Circle().trim(from: 0, to: left / full)
                    .stroke(.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text("\(Int(left.rounded(.up)))s").font(.title3).monospacedDigit()
        }
        .frame(width: 64, height: 64)
        .onAppear { total = left }
        .onChange(of: ends) { _, newEnds in total = max(0, newEnds.timeIntervalSinceNow) }
    }
}

private struct ExerciseLines: View {
    @EnvironmentObject private var workout: WatchWorkoutManager

    var body: some View {
        if let state = workout.state {
            if let exercise = state.exercise {
                Text(exercise).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                if let line = Self.setLine(state) { Text(line).font(.footnote).foregroundStyle(.secondary) }
            } else {
                Text(state.workoutName).font(.headline)
            }
        } else {
            Text("Connecting to your iPhone…").font(.footnote).foregroundStyle(.secondary)
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
    @State private var confirmEnd = false

    var body: some View {
        VStack(spacing: 8) {
            Button {
                workout.setDone()
            } label: {
                Label("Set done", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .tint(.green)
            .disabled(workout.state?.exercise == nil || workout.phase != .running)

            HStack {
                Button {
                    workout.togglePause()
                } label: {
                    Image(systemName: workout.phase == .paused ? "play.fill" : "pause.fill")
                }
                .disabled(workout.phase == .ending)
                Button(role: .destructive) {
                    confirmEnd = true
                } label: {
                    Image(systemName: "xmark")
                }
                .disabled(workout.phase == .ending)
            }
        }
        .confirmationDialog("End this workout?", isPresented: $confirmEnd) {
            Button("End workout", role: .destructive) { workout.requestEnd() }
        }
    }
}

// MARK: - Caption

private struct CaptionPage: View {
    @EnvironmentObject private var workout: WatchWorkoutManager

    var body: some View {
        ScrollView {
            if let caption = workout.state?.caption, !caption.isEmpty {
                Text(caption).font(.body)
            } else {
                Text("Your coach's latest line shows here.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
