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
                if let summary = appModel.progressSummary {
                    ProgressSection(summary: summary)
                }

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

// MARK: - Progress section (server-computed trends; the app only renders)

/// "Am I getting somewhere?" — adherence, strength trends, weight trend.
/// Every number comes from derivedSummaries/progress_current; no math here.
private struct ProgressSection: View {
    let summary: ProgressSummaryModel

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
            MyoSectionLabel(text: "Progress — last 6 weeks")

            adherenceCard

            if !summary.lifts.isEmpty {
                liftsCard
            }

            if !summary.body.weightSeries.isEmpty {
                weightCard
            }
        }
    }

    private var adherenceCard: some View {
        HStack(alignment: .center, spacing: MyoTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Showing up")
                    .myoStyle(.title)
                    .foregroundStyle(MyoColor.Text.primary.color)
                Text(
                    summary.adherence.plannedSessions > 0
                        ? "\(summary.adherence.completedSessions) of \(summary.adherence.plannedSessions) planned sessions"
                        : "\(summary.adherence.completedSessions) sessions logged"
                )
                    .myoStyle(.numeric)
                    .foregroundStyle(MyoColor.Text.secondary.color)
                if summary.adherence.streakWeeks > 0 {
                    Text("\(summary.adherence.streakWeeks)-week streak")
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .foregroundStyle(MyoColor.redPen)
                        .textCase(.uppercase)
                }
            }

            Spacer(minLength: 0)

            WeeklyBars(rates: summary.adherence.weeklyRate)
                .frame(width: 96, height: 44)
                .accessibilityLabel("Weekly adherence over the last six weeks")
        }
        .padding(MyoTheme.Spacing.md)
        .myoCard()
    }

    private var liftsCard: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            Text("Strength")
                .myoStyle(.title)
                .foregroundStyle(MyoColor.Text.primary.color)

            ForEach(summary.lifts) { lift in
                HStack(spacing: MyoTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lift.exerciseName)
                            .myoStyle(.detail)
                            .foregroundStyle(MyoColor.Text.primary.color)
                            .lineLimit(1)
                        Text(trendLabel(lift.trendPct))
                            .font(.system(.caption2, design: .monospaced).weight(.semibold))
                            .foregroundStyle(trendColor(lift.trendPct))
                    }

                    Spacer(minLength: 0)

                    Sparkline(points: lift.e1rmSeries.map(\.value))
                        .stroke(trendColor(lift.trendPct), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 96, height: 26)
                        .accessibilityLabel("\(lift.exerciseName) strength trend")
                }
            }
        }
        .padding(MyoTheme.Spacing.md)
        .myoCard()
    }

    private var weightCard: some View {
        HStack(alignment: .center, spacing: MyoTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Body weight")
                    .myoStyle(.title)
                    .foregroundStyle(MyoColor.Text.primary.color)

                if let avg = summary.body.rollingAvgKg {
                    Text("\(Self.pounds(avg)) lb this week")
                        .myoStyle(.numeric)
                        .foregroundStyle(MyoColor.Text.secondary.color)
                }

                if let trend = summary.body.trendPctPerWeek {
                    Text(weightTrendLabel(trend))
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .foregroundStyle(showsSafetyCaution ? MyoColor.State.danger.color : MyoColor.Text.tertiary.color)
                }

                if showsSafetyCaution {
                    Label("Faster than a safe pace — worth a chat with Coach", systemImage: "exclamationmark.shield")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MyoColor.State.danger.color)
                }
            }

            Spacer(minLength: 0)

            Sparkline(points: summary.body.weightSeries.map(\.value))
                .stroke(MyoColor.Text.secondary.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: 96, height: 32)
                .accessibilityLabel("Body weight trend")
        }
        .padding(MyoTheme.Spacing.md)
        .myoCard()
    }

    // Defense-in-depth against stale persisted docs: the caution needs BOTH
    // the server flag AND an actually-dangerous rate (< -1%/wk), mirroring
    // the pairing the coach prompt uses. A doc written under older
    // semantics can't scare a plateaued user.
    private var showsSafetyCaution: Bool {
        !summary.body.withinSafeBand && (summary.body.trendPctPerWeek ?? 0) < -1
    }

    private func trendLabel(_ pct: Double) -> String {
        if abs(pct) < 0.5 { return "holding steady" }
        let arrow = pct > 0 ? "▲" : "▼"
        return "\(arrow) \(String(format: "%.0f", abs(pct)))% over 6 wks"
    }

    private func trendColor(_ pct: Double) -> Color {
        if pct > 0.5 { return MyoColor.redPen }
        return MyoColor.Text.secondary.color
    }

    private func weightTrendLabel(_ pctPerWeek: Double) -> String {
        if abs(pctPerWeek) < 0.05 { return "holding steady" }
        let direction = pctPerWeek < 0 ? "down" : "up"
        return "\(direction) \(String(format: "%.1f", abs(pctPerWeek)))% / week"
    }

    private static func pounds(_ kg: Double) -> String {
        String(format: "%.1f", kg * 2.20462)
    }
}

/// Six thin vertical bars, one per week bucket, oldest → newest.
private struct WeeklyBars: View {
    let rates: [Double]

    var body: some View {
        GeometryReader { geo in
            let count = max(rates.count, 1)
            let barWidth = max(4, (geo.size.width - CGFloat(count - 1) * 4) / CGFloat(count))
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(rates.enumerated()), id: \.offset) { _, rate in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(rate >= 0.999 ? MyoColor.redPen : MyoTheme.Colors.ink.opacity(0.35))
                        .frame(width: barWidth, height: max(3, geo.size.height * CGFloat(rate)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

/// A minimal normalized polyline — pen on paper, no axes.
private struct Sparkline: Shape {
    let points: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1,
              let minValue = points.min(),
              let maxValue = points.max()
        else { return path }
        let range = maxValue - minValue
        let stepX = rect.width / CGFloat(points.count - 1)
        for (index, value) in points.enumerated() {
            let normalized = range > 0 ? (value - minValue) / range : 0.5
            let point = CGPoint(
                x: rect.minX + CGFloat(index) * stepX,
                y: rect.maxY - CGFloat(normalized) * rect.height
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

