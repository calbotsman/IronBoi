import SwiftUI

/// History — "this is what we've done together." Pushed from the profile.
/// Built like the newer You screens (Memory, profile): a display headline,
/// then labelled groups — progress, milestones, and every session grouped
/// by month. Reads live from appModel.workoutLogs.
struct RecordView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MyoTheme.Spacing.xl) {
                header

                if logs.isEmpty {
                    emptyState
                } else {
                    if let summary = appModel.progressSummary {
                        ProgressSection(summary: summary)
                    }
                    if !stamps.isEmpty { milestones }
                    sessions
                }
            }
            .padding(.horizontal, MyoTheme.Spacing.md)
            .padding(.vertical, MyoTheme.Spacing.lg)
        }
        .background(PaperBackground())
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(MyoTheme.Colors.cream, for: .navigationBar)
    }

    private var logs: [WorkoutLogSummary] {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MYO_SEED_RECORD"] == "1" {
            return Self.demoLogs
        }
        #endif
        return appModel.workoutLogs
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            Text("This is what we've done together.")
                .myoStyle(.display)
                .foregroundStyle(MyoColor.Text.primary.color)
                .fixedSize(horizontal: false, vertical: true)
            Text("Every session you've logged, and what it's adding up to.")
                .myoStyle(.body)
                .foregroundStyle(MyoColor.Text.secondary.color)
        }
    }

    private var emptyState: some View {
        MyoGroupCard {
            MyoSectionLabel(text: "Nothing yet")
            Text(appModel.hasSession
                 ? "Finish a workout from your plan and it will show up here."
                 : "Sign in to see the workouts you've completed.")
                .myoStyle(.body)
                .foregroundStyle(MyoColor.Text.secondary.color)
        }
    }

    private var milestones: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            MyoSectionLabel(text: "Milestones")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MyoTheme.Spacing.lg) {
                    ForEach(Array(stamps.enumerated()), id: \.offset) { i, stamp in
                        MyoStamp(line1: stamp.0, line2: stamp.1, rotation: i.isMultiple(of: 2) ? -4 : 3)
                    }
                }
                // Room for the rotated stamps so their corners aren't clipped.
                .padding(.vertical, MyoTheme.Spacing.md)
                .padding(.horizontal, MyoTheme.Spacing.sm)
            }
            .padding(.horizontal, -MyoTheme.Spacing.sm)
        }
    }

    /// Sessions grouped by month, newest first: one card per month with a
    /// hairline between sessions.
    private var sessions: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.lg) {
            ForEach(monthGroups, id: \.title) { group in
                VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
                    MyoSectionLabel(text: "\(group.title) · \(group.logs.count)")
                    MyoGroupCard {
                        ForEach(Array(group.logs.enumerated()), id: \.element.id) { index, log in
                            if index > 0 { MyoHairline() }
                            SessionRow(log: log)
                        }
                    }
                }
            }
        }
    }

    private var monthGroups: [(title: String, logs: [WorkoutLogSummary])] {
        let sorted = logs.sorted { $0.date > $1.date }
        var groups: [(title: String, logs: [WorkoutLogSummary])] = []
        for log in sorted {
            let title = Self.monthTitle(log)
            if let last = groups.indices.last, groups[last].title == title {
                groups[last].logs.append(log)
            } else {
                groups.append((title, [log]))
            }
        }
        return groups
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private static func monthTitle(_ log: WorkoutLogSummary) -> String {
        guard let day = log.day else { return "Earlier" }
        return monthFormatter.string(from: day)
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
            out.append((WeightLoad.label(Double(pr.pounds), for: pr.name), pr.name))
        }
        return out
    }

    #if DEBUG
    private static let demoLogs: [WorkoutLogSummary] = [
        WorkoutLogSummary(sessionId: "1", date: "2026-06-20", title: "Lower Body Strength · 70%",
            exercises: [LoggedExercise(name: "Back Squat", sets: Array(repeating: LoggedSet(reps: 5, loadKg: 102), count: 5)),
                        LoggedExercise(name: "Romanian Deadlift", sets: Array(repeating: LoggedSet(reps: 8, loadKg: 84), count: 3)),
                        LoggedExercise(name: "Walking Lunge", sets: Array(repeating: LoggedSet(reps: 12, loadKg: 20), count: 3))],
            durationSec: 3300, perceivedEffort: 7),
        WorkoutLogSummary(sessionId: "2", date: "2026-06-18", title: "Upper Push",
            exercises: [LoggedExercise(name: "Bench Press", sets: Array(repeating: LoggedSet(reps: 5, loadKg: 84), count: 5)),
                        LoggedExercise(name: "Overhead Press", sets: Array(repeating: LoggedSet(reps: 6, loadKg: 50), count: 4))],
            durationSec: 2700, perceivedEffort: 6),
        WorkoutLogSummary(sessionId: "3", date: "2026-05-30", title: "Pull Day",
            exercises: [LoggedExercise(name: "Deadlift", sets: Array(repeating: LoggedSet(reps: 3, loadKg: 140), count: 4)),
                        LoggedExercise(name: "Pull-up", sets: Array(repeating: LoggedSet(reps: 8, loadKg: nil), count: 4))],
            durationSec: 3000, perceivedEffort: 8),
    ]
    #endif
}

/// One completed session: weekday + day on the left, the work on the right.
/// A scaled session ("… · 70%") shows its scale as a small tag instead of
/// part of the title.
private struct SessionRow: View {
    let log: WorkoutLogSummary

    var body: some View {
        HStack(alignment: .top, spacing: MyoTheme.Spacing.md) {
            dateBlock

            VStack(alignment: .leading, spacing: 4) {
                Text(parts.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MyoColor.Text.primary.color)
                    .fixedSize(horizontal: false, vertical: true)

                Text(statLine)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(MyoColor.Text.secondary.color)

                if !topExercises.isEmpty {
                    Text(topExercises)
                        .myoStyle(.detail)
                        .foregroundStyle(MyoColor.Text.tertiary.color)
                        .lineLimit(2)
                }

                if let scale = parts.scale {
                    Text("\(scale) load")
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(MyoColor.Text.secondary.color)
                        .padding(.horizontal, MyoTheme.Spacing.sm)
                        .padding(.vertical, 3)
                        .background(MyoTheme.Colors.ink.opacity(0.06))
                        .clipShape(Capsule())
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, MyoTheme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var dateBlock: some View {
        VStack(spacing: 0) {
            Text(weekdayText)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(MyoColor.redPen)
                .textCase(.uppercase)
            Text(dayText)
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .foregroundStyle(MyoColor.Text.primary.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(width: 40)
    }

    /// Splits a trailing " · 70%" off the stored title.
    private var parts: (title: String, scale: String?) {
        let title = log.title
        guard let range = title.range(of: #"\s*·\s*\d{1,3}%$"#, options: .regularExpression) else {
            return (title, nil)
        }
        let scale = title[range].filter { $0.isNumber || $0 == "%" }
        return (String(title[..<range.lowerBound]), scale.isEmpty ? nil : String(scale))
    }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE"; return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d"; return f
    }()

    private var weekdayText: String {
        guard let d = log.day else { return "—" }
        return Self.weekdayFormatter.string(from: d)
    }

    private var dayText: String {
        guard let d = log.day else { return "·" }
        return Self.dayFormatter.string(from: d)
    }

    private var statLine: String {
        var parts = ["\(log.totalSets) sets"]
        if let dur = log.durationSec, dur > 0 { parts.append("\(dur / 60) min") }
        if let e = log.perceivedEffort { parts.append("effort \(e)/10") }
        return parts.joined(separator: " · ")
    }

    private var topExercises: String {
        let names = log.exercises.prefix(3).map(\.name)
        let more = log.exercises.count - names.count
        return names.joined(separator: ", ") + (more > 0 ? " + \(more) more" : "")
    }
}

#Preview {
    NavigationStack {
        RecordView()
            .environmentObject(AppModel())
    }
}

// MARK: - Progress section (server-computed trends; the app only renders)

/// "Am I getting somewhere?" — showing up, strength, body weight, each as
/// its own labelled card. Every number comes from
/// derivedSummaries/progress_current; no math here.
private struct ProgressSection: View {
    let summary: ProgressSummaryModel

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.lg) {
            group("Last 6 weeks") { adherenceCard }

            if !summary.lifts.isEmpty {
                group("Strength · \(summary.lifts.count)") { liftsCard }
            }

            if !summary.body.weightSeries.isEmpty {
                group("Body weight") { weightCard }
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            MyoSectionLabel(text: title)
            content()
        }
    }

    private var adherenceCard: some View {
        MyoGroupCard {
            HStack(alignment: .bottom, spacing: MyoTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(summary.adherence.completedSessions)")
                            .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                            .foregroundStyle(MyoColor.Text.primary.color)
                        Text(summary.adherence.completedSessions == 1 ? "session" : "sessions")
                            .myoStyle(.body)
                            .foregroundStyle(MyoColor.Text.secondary.color)
                    }
                    if summary.adherence.plannedSessions > 0 {
                        Text("of \(summary.adherence.plannedSessions) planned since you started")
                            .myoStyle(.detail)
                            .foregroundStyle(MyoColor.Text.tertiary.color)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 4) {
                    WeeklyBars(rates: summary.adherence.weeklyRate)
                        .frame(width: 104, height: 40)
                        .accessibilityLabel("Weekly adherence over the last six weeks")
                    Text("THIS WEEK →")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(MyoColor.Text.tertiary.color)
                        .accessibilityHidden(true)
                }
            }

            if summary.adherence.streakWeeks > 0 {
                Text("\(summary.adherence.streakWeeks)-week streak")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(MyoColor.redPen)
                    .textCase(.uppercase)
            }
        }
    }

    private var liftsCard: some View {
        MyoGroupCard {
            ForEach(Array(summary.lifts.enumerated()), id: \.element.id) { index, lift in
                if index > 0 { MyoHairline() }
                HStack(spacing: MyoTheme.Spacing.md) {
                    Text(lift.exerciseName)
                        .myoStyle(.body)
                        .foregroundStyle(MyoColor.Text.primary.color)
                        .lineLimit(2)

                    Spacer(minLength: MyoTheme.Spacing.sm)

                    // A line needs at least three points to show a shape;
                    // two points always drew a full-height diagonal that
                    // made a small change look like a cliff.
                    Group {
                        if lift.e1rmSeries.count >= 3 {
                            Sparkline(points: lift.e1rmSeries.map(\.value))
                                .stroke(trendColor(lift.trendPct), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 56, height: 18)
                    .accessibilityHidden(true)

                    Text(trendLabel(lift.trendPct))
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(trendColor(lift.trendPct))
                        .frame(minWidth: 64, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }

            Text("Estimated one-rep max, change over the last 6 weeks.")
                .myoStyle(.detail)
                .foregroundStyle(MyoColor.Text.tertiary.color)
        }
    }

    private var weightCard: some View {
        MyoGroupCard {
            HStack(alignment: .center, spacing: MyoTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    if let avg = summary.body.rollingAvgKg {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Self.pounds(avg))
                                .font(.system(.title, design: .monospaced).weight(.semibold))
                                .foregroundStyle(MyoColor.Text.primary.color)
                            Text("lb this week")
                                .myoStyle(.body)
                                .foregroundStyle(MyoColor.Text.secondary.color)
                        }
                    }

                    if let trend = summary.body.trendPctPerWeek {
                        Text(weightTrendLabel(trend))
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(showsSafetyCaution ? MyoColor.State.danger.color : MyoColor.Text.tertiary.color)
                    }
                }

                Spacer(minLength: 0)

                if summary.body.weightSeries.count >= 3 {
                    Sparkline(points: summary.body.weightSeries.map(\.value))
                        .stroke(MyoColor.Text.secondary.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 96, height: 32)
                        .accessibilityLabel("Body weight trend")
                }
            }

            if showsSafetyCaution {
                Label("Faster than a safe pace — worth a chat with Coach", systemImage: "exclamationmark.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MyoColor.State.danger.color)
            }
        }
    }

    // Defense-in-depth against stale persisted docs: the caution needs BOTH
    // the server flag AND an actually-dangerous rate (< -1%/wk), mirroring
    // the pairing the coach prompt uses. A doc written under older
    // semantics can't scare a plateaued user.
    private var showsSafetyCaution: Bool {
        !summary.body.withinSafeBand && (summary.body.trendPctPerWeek ?? 0) < -1
    }

    private func trendLabel(_ pct: Double) -> String {
        if abs(pct) < 0.5 { return "steady" }
        return "\(pct > 0 ? "+" : "−")\(String(format: "%.0f", abs(pct)))%"
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

