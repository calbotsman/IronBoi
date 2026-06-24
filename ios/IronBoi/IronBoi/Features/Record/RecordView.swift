import SwiftUI

/// The Record tab — "Your history: this is what we did together."
/// Milestone stamps for earned PRs, then the training log as folded paper
/// cards. Reads live from appModel.workoutLogs.
struct RecordView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        NavigationStack {
            Group {
                if logs.isEmpty, !appModel.hasSession {
                    signedOut
                } else if logs.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .background(PaperBackground())
            .navigationTitle("Record")
        }
    }

    private var logs: [WorkoutLogSummary] {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MYO_SEED_RECORD"] == "1" {
            return Self.demoLogs
        }
        #endif
        return appModel.workoutLogs
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MyoTheme.Spacing.xl) {
                if !stamps.isEmpty {
                    VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
                        MyoSectionLabel(text: "Milestones")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: MyoTheme.Spacing.lg) {
                                ForEach(Array(stamps.enumerated()), id: \.offset) { i, stamp in
                                    MyoStamp(line1: stamp.0, line2: stamp.1, rotation: i.isMultiple(of: 2) ? -6 : 4)
                                }
                            }
                            .padding(.vertical, MyoTheme.Spacing.sm)
                            .padding(.horizontal, MyoTheme.Spacing.sm)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
                    MyoSectionLabel(text: "Your history")
                    ForEach(logs) { log in
                        SessionCard(log: log)
                    }
                }
            }
            .padding(.horizontal, MyoTheme.Spacing.md)
            .padding(.vertical, MyoTheme.Spacing.lg)
        }
    }

    /// Earned, honest milestones — only what the data supports.
    private var stamps: [(String, String?)] {
        var out: [(String, String?)] = []
        let sessions = logs.totalSessions
        for threshold in [50, 25, 10, 1] where sessions >= threshold {
            out.append(("\(threshold) \(threshold == 1 ? "session" : "sessions")", "logged"))
            break
        }
        let reps = logs.totalRepsLogged
        for threshold in [1000, 500, 100] where reps >= threshold {
            out.append(("\(threshold) reps", "completed"))
            break
        }
        if let pr = logs.heaviestLift {
            out.append(("\(pr.pounds) lb", pr.name))
        }
        return out
    }

    #if DEBUG
    private static let demoLogs: [WorkoutLogSummary] = [
        WorkoutLogSummary(sessionId: "1", date: "2026-06-20", title: "Lower Body Strength",
            exercises: [LoggedExercise(name: "Back Squat", sets: Array(repeating: LoggedSet(reps: 5, loadKg: 102), count: 5)),
                        LoggedExercise(name: "Romanian Deadlift", sets: Array(repeating: LoggedSet(reps: 8, loadKg: 84), count: 3)),
                        LoggedExercise(name: "Walking Lunge", sets: Array(repeating: LoggedSet(reps: 12, loadKg: 20), count: 3))],
            durationSec: 3300, perceivedEffort: 7),
        WorkoutLogSummary(sessionId: "2", date: "2026-06-18", title: "Upper Push",
            exercises: [LoggedExercise(name: "Bench Press", sets: Array(repeating: LoggedSet(reps: 5, loadKg: 84), count: 5)),
                        LoggedExercise(name: "Overhead Press", sets: Array(repeating: LoggedSet(reps: 6, loadKg: 50), count: 4))],
            durationSec: 2700, perceivedEffort: 6),
        WorkoutLogSummary(sessionId: "3", date: "2026-06-16", title: "Pull Day",
            exercises: [LoggedExercise(name: "Deadlift", sets: Array(repeating: LoggedSet(reps: 3, loadKg: 140), count: 4)),
                        LoggedExercise(name: "Pull-up", sets: Array(repeating: LoggedSet(reps: 8, loadKg: nil), count: 4))],
            durationSec: 3000, perceivedEffort: 8),
    ]
    #endif

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Record", systemImage: "calendar.day.timeline.left")
        } description: {
            Text("No sessions recorded yet. Start a workout in Train to begin building your record.")
        }
    }

    private var signedOut: some View {
        ContentUnavailableView {
            Label("Your record", systemImage: "calendar.day.timeline.left")
        } description: {
            Text("Sign in to see the workouts you've completed.")
        }
    }
}

/// A completed session as a sheet of paper: ink date block on the left, the
/// work on the right, a folded corner so it reads as a page in the dossier.
private struct SessionCard: View {
    let log: WorkoutLogSummary

    var body: some View {
        HStack(alignment: .top, spacing: MyoTheme.Spacing.md) {
            dateBlock

            VStack(alignment: .leading, spacing: 6) {
                Text(log.title)
                    .myoStyle(.title)
                    .foregroundStyle(MyoColor.Text.primary.color)
                    .fixedSize(horizontal: false, vertical: true)

                Text(statLine)
                    .myoStyle(.numeric)
                    .foregroundStyle(MyoColor.Text.secondary.color)

                if !topExercises.isEmpty {
                    Text(topExercises)
                        .myoStyle(.detail)
                        .foregroundStyle(MyoColor.Text.tertiary.color)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(MyoTheme.Spacing.md)
        .myoCard()
        .overlay(alignment: .topTrailing) { foldedCorner }
    }

    private var dateBlock: some View {
        VStack(spacing: 0) {
            Text(monthText)
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .foregroundStyle(MyoColor.redPen)
                .textCase(.uppercase)
            Text(dayText)
                .font(.system(.title, design: .monospaced).weight(.bold))
                .foregroundStyle(MyoColor.Text.primary.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(width: 52)
    }

    /// A small ink page-fold in the top-right corner.
    private var foldedCorner: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: 16, y: 0))
            p.addLine(to: CGPoint(x: 16, y: 16))
            p.closeSubpath()
        }
        .fill(MyoTheme.Colors.ink.opacity(0.10))
        .frame(width: 16, height: 16)
        .padding(.trailing, 1)
        .padding(.top, 1)
        .accessibilityHidden(true)
    }

    private var monthText: String {
        guard let d = log.day else { return "—" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMM"
        return f.string(from: d)
    }

    private var dayText: String {
        guard let d = log.day else { return "·" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d"
        return f.string(from: d)
    }

    private var statLine: String {
        var parts = ["\(log.exerciseCount) exercises", "\(log.totalSets) sets"]
        if let dur = log.durationSec, dur > 0 { parts.append("\(dur / 60) min") }
        if let e = log.perceivedEffort { parts.append("effort \(e)") }
        return parts.joined(separator: "  ·  ")
    }

    private var topExercises: String {
        log.exercises.prefix(4).map(\.name).joined(separator: ", ")
    }
}

#Preview {
    RecordView()
        .environmentObject(AppModel())
}
