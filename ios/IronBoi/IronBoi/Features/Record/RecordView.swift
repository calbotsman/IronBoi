import SwiftUI

/// History — "this is what we've done together." Pushed from the profile.
/// Built like the newer You screens (Memory, profile): a display headline,
/// then labelled groups — streak, lifts, records, milestones, and every
/// session grouped by month. Reads live from appModel.trainingHistory (the
/// server-built summary) and appModel.workoutLogs. Without a history doc yet
/// it falls back to the older progress cards.
struct RecordView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MyoTheme.Spacing.xl) {
                header

                if logs.isEmpty {
                    emptyState
                } else {
                    if let history {
                        StreakSection(history: history)
                        if !history.lifts.isEmpty { LiftsSection(lifts: history.lifts) }
                        if !history.recentRecords.isEmpty { RecordsSection(records: history.recentRecords) }
                    }
                    if let summary = appModel.progressSummary, let flags = progressFlags(summary) {
                        ProgressSection(summary: summary, showsAdherence: flags.adherence, showsLifts: flags.lifts)
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

    private var history: TrainingHistoryModel? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MYO_SEED_RECORD"] == "1" {
            return Self.demoHistory
        }
        #endif
        return appModel.trainingHistory
    }

    /// The older progress cards, minus what the history already shows: the
    /// streak replaces "last 6 weeks", the lift rows replace "strength".
    /// Nil when nothing would be left to show.
    private func progressFlags(_ summary: ProgressSummaryModel) -> (adherence: Bool, lifts: Bool)? {
        let adherence = history == nil
        let lifts = history?.lifts.isEmpty ?? true
        let anything = adherence || (lifts && !summary.lifts.isEmpty) || !summary.body.weightSeries.isEmpty
        if !anything { return nil }
        return (adherence: adherence, lifts: lifts)
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
                            NavigationLink {
                                SessionDetailView(log: log, allLogs: logs)
                            } label: {
                                SessionRow(log: log)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows every set")
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
        WorkoutLogSummary(sessionId: "4", date: "2026-05-28", title: "Upper Push",
            exercises: [LoggedExercise(name: "Bench Press", sets: Array(repeating: LoggedSet(reps: 5, loadKg: 82), count: 5)),
                        LoggedExercise(name: "Overhead Press", sets: Array(repeating: LoggedSet(reps: 5, loadKg: 50), count: 4)),
                        LoggedExercise(name: "Plank", sets: Array(repeating: LoggedSet(reps: nil, loadKg: nil, durationSec: 45), count: 2))],
            durationSec: 2600, perceivedEffort: 6),
    ]

    /// A history doc shaped like the server's, built around today so the
    /// calendar strip has something to draw (Mon/Wed/Fri plan, one miss).
    private static let demoHistory: TrainingHistoryModel? = {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let iso = DateFormatter()
        iso.calendar = cal
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.dateFormat = "yyyy-MM-dd"
        let now = Date()
        let todayISO = iso.string(from: now)
        guard let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start,
              let first = cal.date(byAdding: .day, value: -56, to: weekStart) else { return nil }
        let keys = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        var days: [[String: Any]] = []
        for offset in 0..<63 {
            guard let day = cal.date(byAdding: .day, value: offset, to: first) else { continue }
            let date = iso.string(from: day)
            let planned = [0, 2, 4].contains(offset % 7)
            let status: String
            if date == todayISO {
                status = planned ? "today" : "rest"
            } else if date > todayISO {
                status = planned ? "planned" : "rest"
            } else if planned {
                status = offset == 30 ? "missed" : "done"
            } else {
                status = offset == 19 ? "extra" : "rest"
            }
            days.append(["date": date, "dayKey": keys[offset % 7], "status": status] as [String: Any])
        }
        let goblet: [String: Any] = [
            "exerciseKey": "kb_goblet_squat", "exerciseName": "KB Goblet Squat",
            "currentLb": 35.0, "startLb": 20.0, "firstDate": "2026-09-14", "lastDate": "2026-11-04", "sessions": 14,
            "events": [
                ["date": "2026-11-04", "kind": "session_up", "fromLb": 30.0, "toLb": 35.0, "reason": "all 3×10 hit at 30 lb"],
                ["date": "2026-10-28", "kind": "hold_missed_reps", "fromLb": 30.0, "toLb": 30.0, "reason": "8 of 10 on the last set"],
                ["date": "2026-10-12", "kind": "weekly_up", "fromLb": 25.0, "toLb": 30.0, "reason": "a clean week at 25 lb"],
                ["date": "2026-09-28", "kind": "session_up", "fromLb": 20.0, "toLb": 25.0, "reason": "all 3×10 hit at 20 lb"],
            ] as [[String: Any]],
            "e1rmSeries": [
                ["date": "2026-09-14", "value": 27.0], ["date": "2026-09-28", "value": 30.0],
                ["date": "2026-10-12", "value": 33.0], ["date": "2026-10-28", "value": 38.0],
                ["date": "2026-11-04", "value": 40.0],
            ] as [[String: Any]],
            "prs": [["exerciseName": "KB Goblet Squat", "kind": "heaviest", "weightLb": 35.0, "reps": 10, "date": "2026-11-04"]] as [[String: Any]],
        ]
        let row: [String: Any] = [
            "exerciseKey": "single_arm_db_row", "exerciseName": "Single-arm DB Row",
            "currentLb": 40.0, "startLb": 40.0, "firstDate": "2026-10-20", "lastDate": "2026-11-03", "sessions": 3,
            "events": [] as [[String: Any]], "e1rmSeries": [] as [[String: Any]], "prs": [] as [[String: Any]],
        ]
        let data: [String: Any] = [
            "computedAt": "", "today": todayISO,
            "streak": ["currentWeeks": 3, "bestWeeks": 5, "thisWeekMet": false] as [String: Any],
            "thisWeek": ["weekStart": iso.string(from: weekStart), "planned": 3, "done": 1, "volumeLb": 8200.0] as [String: Any],
            "calendar": days,
            "lifts": [goblet, row] as [[String: Any]],
            "recentRecords": [
                ["exerciseName": "KB Goblet Squat", "kind": "heaviest", "weightLb": 35.0, "reps": 10, "date": "2026-11-04"],
                ["exerciseName": "Single-arm DB Row", "kind": "most_reps", "weightLb": 40.0, "reps": 12, "date": "2026-11-03"],
                ["exerciseName": "KB Goblet Squat", "kind": "best_e1rm", "weightLb": 35.0, "reps": 10, "e1rmLb": 46.7, "date": "2026-11-04"],
            ] as [[String: Any]],
        ]
        return TrainingHistoryModel(firestore: data)
    }()
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

                Text(log.historyStatLine)
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

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(MyoColor.Text.tertiary.color)
                .padding(.top, MyoTheme.Spacing.md)
                .accessibilityHidden(true)
        }
        .padding(.vertical, MyoTheme.Spacing.xs)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
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
    /// Off when the training history's streak and lift rows show these.
    var showsAdherence = true
    var showsLifts = true

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.lg) {
            if showsAdherence {
                group("Last 6 weeks") { adherenceCard }
            }

            if showsLifts, !summary.lifts.isEmpty {
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

    // Getting stronger is good news: sage, not the red pen (which reads as
    // a warning).
    private func trendColor(_ pct: Double) -> Color {
        if pct > 0.5 { return MyoColor.State.success.color }
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


// MARK: - Training history (derivedSummaries/training_history; the app only renders)

/// "2026-11-04" → "Nov 4" (the device's own day/month order).
private enum HistoryDate {
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ iso: String) -> Date? { parser.date(from: iso) }

    static func short(_ iso: String) -> String {
        guard let d = date(iso) else { return iso }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}

private extension WorkoutLogSummary {
    /// "18 sets · 45 min · effort 7/10"
    var historyStatLine: String {
        var parts = ["\(totalSets) sets"]
        if let dur = durationSec, dur > 0 { parts.append("\(dur / 60) min") }
        if let e = perceivedEffort { parts.append("effort \(e)/10") }
        return parts.joined(separator: " · ")
    }
}

/// Weights, said the History way. Logs store kilos; History speaks pounds,
/// to the nearest half pound.
private enum HistoryWeight {
    static func pounds(kg: Double) -> Double { (kg * 2.20462 * 2).rounded() / 2 }

    /// The unit a change is counted in: "lb each" for a pair of bells.
    static func unit(for exerciseName: String) -> String {
        WeightLoad.basis(for: exerciseName) == .each ? "lb each" : "lb"
    }

    /// "+15 lb", "−5 lb each".
    static func delta(_ pounds: Double, for exerciseName: String) -> String {
        "\(pounds > 0 ? "+" : "−")\(WeightLoad.number(abs(pounds))) \(unit(for: exerciseName))"
    }
}

// MARK: Streak (H1)

/// The streak in big type, the best one small, this week's count, and nine
/// weeks of days as dots.
private struct StreakSection: View {
    let history: TrainingHistoryModel

    private var streak: TrainingStreak { history.streak }
    private var week: TrainingWeek { history.thisWeek }

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            MyoSectionLabel(text: "Streak")
            MyoGroupCard {
                headline
                weekLine
                if !history.calendar.isEmpty {
                    CalendarStrip(days: history.calendar, today: history.today)
                }
            }
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(streak.currentWeeks > 0 ? "\(streak.currentWeeks)-week streak" : "No streak yet")
                .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                .foregroundStyle(MyoColor.Text.primary.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if streak.bestWeeks > 0 {
                Text("Best: \(streak.bestWeeks) \(streak.bestWeeks == 1 ? "week" : "weeks")")
                    .myoStyle(.detail)
                    .foregroundStyle(MyoColor.Text.tertiary.color)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var weekLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(weekText)
                .myoStyle(.body)
                .foregroundStyle(MyoColor.Text.secondary.color)
            if streak.thisWeekMet {
                Text("This week counts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MyoColor.State.success.color)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var weekText: String {
        if week.planned > 0 { return "\(week.done) of \(week.planned) sessions this week" }
        return "\(week.done) \(week.done == 1 ? "session" : "sessions") this week"
    }
}

/// One column per week (oldest on the left), Monday at the top. Done is a
/// filled dot, missed a small cross, planned an outline, rest a faint speck,
/// and today is ringed.
private struct CalendarStrip: View {
    let days: [TrainingDay]
    let today: String

    private static let dayKeys = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let initials = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            HStack(alignment: .top, spacing: 4) {
                labels
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    column(week)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary)

            legend
        }
    }

    /// Seven slots per week, filled by weekday so a short first week still
    /// lines up.
    private var weeks: [[TrainingDay?]] {
        var out: [[TrainingDay?]] = []
        for day in days {
            let slot = Self.dayKeys.firstIndex(of: day.dayKey) ?? 0
            if out.isEmpty || slot == 0 {
                out.append(Array(repeating: nil, count: 7))
            }
            out[out.count - 1][slot] = day
        }
        return out
    }

    private var labels: some View {
        VStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                Text(Self.initials[i])
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(MyoColor.Text.tertiary.color)
                    .frame(width: 14, height: 16)
            }
        }
        .accessibilityHidden(true)
    }

    private func column(_ week: [TrainingDay?]) -> some View {
        VStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                DayDot(status: week[i]?.status, isToday: week[i]?.date == today)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var legend: some View {
        HStack(spacing: MyoTheme.Spacing.md) {
            legendItem("done", "Done")
            legendItem("missed", "Missed")
            legendItem("planned", "Planned")
            legendItem("rest", "Rest")
        }
        .accessibilityHidden(true)
    }

    private func legendItem(_ status: String, _ title: String) -> some View {
        HStack(spacing: 4) {
            DayDot(status: status, isToday: false)
            Text(title)
                .font(.caption2)
                .foregroundStyle(MyoColor.Text.tertiary.color)
        }
    }

    private var summary: String {
        let done = days.filter { $0.status == "done" || $0.status == "extra" }.count
        let missed = days.filter { $0.status == "missed" }.count
        var text = "Last \(weeks.count) weeks: \(done) \(done == 1 ? "session" : "sessions") done"
        if missed > 0 { text += ", \(missed) missed" }
        return text + "."
    }
}

private struct DayDot: View {
    /// done | missed | rest | today | planned | extra; nil for an empty slot.
    let status: String?
    let isToday: Bool

    var body: some View {
        ZStack {
            mark
            if isToday {
                Circle()
                    .stroke(MyoColor.Action.primary.color, lineWidth: 2)
                    .frame(width: 16, height: 16)
            }
        }
        .frame(width: 16, height: 16)
    }

    @ViewBuilder
    private var mark: some View {
        switch status ?? "" {
        case "done", "extra":
            Circle()
                .fill(MyoColor.Text.primary.color)
                .frame(width: 10, height: 10)
        case "missed":
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(MyoColor.State.warning.color)
        case "planned", "today":
            Circle()
                .stroke(MyoColor.Text.secondary.color, lineWidth: 1.5)
                .frame(width: 9, height: 9)
        case "rest":
            Circle()
                .fill(MyoColor.Text.disabled.color)
                .frame(width: 4, height: 4)
        default:
            Color.clear
                .frame(width: 10, height: 10)
        }
    }
}

// MARK: Lifts (H2)

private enum LiftText {
    /// "35 lb each", or "Bodyweight" with no load.
    static func current(_ lift: LiftProgress) -> String {
        lift.currentLb > 0 ? WeightLoad.label(lift.currentLb, for: lift.exerciseName) : "Bodyweight"
    }

    /// Rounded to the half pound so float noise never reads as a change.
    static func change(_ lift: LiftProgress) -> Double {
        ((lift.currentLb - lift.startLb) * 2).rounded() / 2
    }

    /// "+15 lb since Oct 13", "Same weight since Oct 13", "First done Nov 4".
    static func changeLine(_ lift: LiftProgress) -> String {
        let delta = change(lift)
        let since = lift.firstDate.isEmpty ? "" : " since \(HistoryDate.short(lift.firstDate))"
        if delta == 0 {
            if lift.sessions <= 1, !lift.firstDate.isEmpty { return "First done \(HistoryDate.short(lift.firstDate))" }
            return "Same weight\(since)"
        }
        return HistoryWeight.delta(delta, for: lift.exerciseName) + since
    }
}

/// One row per lift, most recently trained first; each opens its timeline.
private struct LiftsSection: View {
    let lifts: [LiftProgress]

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            MyoSectionLabel(text: "Lifts · \(lifts.count)")
            MyoGroupCard {
                ForEach(Array(lifts.enumerated()), id: \.offset) { index, lift in
                    if index > 0 { MyoHairline() }
                    NavigationLink {
                        LiftDetailView(lift: lift)
                    } label: {
                        LiftRow(lift: lift)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows every weight change")
                }
            }
        }
    }
}

private struct LiftRow: View {
    let lift: LiftProgress

    var body: some View {
        HStack(spacing: MyoTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lift.exerciseName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MyoColor.Text.primary.color)
                    .lineLimit(2)
                Text(LiftText.current(lift))
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(MyoColor.Text.primary.color)
                Text(LiftText.changeLine(lift))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(LiftText.change(lift) > 0 ? MyoColor.State.success.color : MyoColor.Text.secondary.color)
            }

            Spacer(minLength: MyoTheme.Spacing.sm)

            E1RMLine(series: lift.e1rmSeries)
                .frame(width: 56, height: 20)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(MyoColor.Text.tertiary.color)
                .accessibilityHidden(true)
        }
        .padding(.vertical, MyoTheme.Spacing.xs)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The estimated-max line. Needs three points to show a shape (two always
/// drew a full-height diagonal); rising is sage, never the red pen.
private struct E1RMLine: View {
    let series: [ProgressPoint]
    var lineWidth: CGFloat = 1.5

    var body: some View {
        if series.count >= 3 {
            Sparkline(points: series.map(\.value))
                .stroke(lineColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .accessibilityHidden(true)
        } else {
            Color.clear
                .accessibilityHidden(true)
        }
    }

    private var lineColor: Color {
        let first = series.first?.value ?? 0
        let last = series.last?.value ?? 0
        return last > first ? MyoColor.State.success.color : MyoColor.Text.secondary.color
    }
}

/// A lift's whole story: where it is now, the estimated-max line, its
/// records, and every weight change newest first with the reason.
private struct LiftDetailView: View {
    let lift: LiftProgress

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MyoTheme.Spacing.xl) {
                header
                if lift.e1rmSeries.count >= 3 { e1rmGroup }
                if !lift.prs.isEmpty { recordsGroup }
                if !lift.events.isEmpty { timelineGroup }
            }
            .padding(.horizontal, MyoTheme.Spacing.md)
            .padding(.vertical, MyoTheme.Spacing.lg)
        }
        .background(PaperBackground())
        .navigationTitle(lift.exerciseName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(MyoTheme.Colors.cream, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            Text(lift.exerciseName)
                .myoStyle(.display)
                .foregroundStyle(MyoColor.Text.primary.color)
                .fixedSize(horizontal: false, vertical: true)
            Text(LiftText.current(lift))
                .font(.system(.title, design: .monospaced).weight(.semibold))
                .foregroundStyle(MyoColor.Text.primary.color)
            Text(LiftText.changeLine(lift))
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(LiftText.change(lift) > 0 ? MyoColor.State.success.color : MyoColor.Text.secondary.color)
            Text(startedLine)
                .myoStyle(.detail)
                .foregroundStyle(MyoColor.Text.tertiary.color)
        }
        .accessibilityElement(children: .combine)
    }

    /// "Started at 20 lb · 14 sessions"
    private var startedLine: String {
        var parts: [String] = []
        if lift.startLb > 0 { parts.append("Started at \(WeightLoad.label(lift.startLb, for: lift.exerciseName))") }
        parts.append("\(lift.sessions) \(lift.sessions == 1 ? "session" : "sessions")")
        return parts.joined(separator: " · ")
    }

    private var e1rmGroup: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            MyoSectionLabel(text: "Estimated max")
            MyoGroupCard {
                E1RMLine(series: lift.e1rmSeries, lineWidth: 2)
                    .frame(height: 64)
                    .frame(maxWidth: .infinity)
                HStack {
                    endpoint(lift.e1rmSeries.first)
                    Spacer()
                    endpoint(lift.e1rmSeries.last)
                }
                Text("Best estimated one-rep max each session.")
                    .myoStyle(.detail)
                    .foregroundStyle(MyoColor.Text.tertiary.color)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func endpoint(_ point: ProgressPoint?) -> some View {
        Text(endpointText(point))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(MyoColor.Text.secondary.color)
    }

    /// "Oct 13: 120 lb"
    private func endpointText(_ point: ProgressPoint?) -> String {
        guard let point else { return "" }
        let pounds = (point.value * 2).rounded() / 2
        return "\(HistoryDate.short(point.date)): \(WeightLoad.number(pounds)) lb"
    }

    private var recordsGroup: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            MyoSectionLabel(text: "Records")
            MyoGroupCard {
                ForEach(Array(lift.prs.enumerated()), id: \.offset) { index, record in
                    if index > 0 { MyoHairline() }
                    RecordRow(record: record, showsName: false)
                }
            }
        }
    }

    private var timelineGroup: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            MyoSectionLabel(text: "Weight changes · \(lift.events.count)")
            MyoGroupCard {
                ForEach(Array(lift.events.enumerated()), id: \.offset) { index, event in
                    if index > 0 { MyoHairline() }
                    EventRow(event: event, exerciseName: lift.exerciseName,
                             records: lift.prs.filter { $0.date == event.date })
                }
            }
        }
    }
}

private enum EventText {
    static func title(_ kind: String) -> String {
        switch kind {
        case "session_up": return "Went up"
        case "weekly_up": return "Weekly step up"
        case "hold_missed_reps": return "Held · missed reps"
        case "hold_not_trained": return "Held · not trained"
        case "deload": return "Eased off"
        case "changed_in_workout": return "Changed in the workout"
        case "plan_change": return "Plan change"
        default: return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func isUp(_ event: ProgressionEventModel) -> Bool {
        event.toLb > event.fromLb
    }
}

/// "NOV 4 · WENT UP" / "30 → 35 lb" / "all 3×10 hit at 30 lb", plus a PR
/// badge when a record was set that day.
private struct EventRow: View {
    let event: ProgressionEventModel
    let exerciseName: String
    let records: [PersonalRecordModel]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(HistoryDate.short(event.date)) · \(EventText.title(event.kind))")
                .myoStyle(.label)
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(EventText.isUp(event) ? MyoColor.State.success.color : MyoColor.Text.tertiary.color)
            Text(weights)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(MyoColor.Text.primary.color)
            if !event.reason.isEmpty {
                Text(event.reason)
                    .myoStyle(.body)
                    .foregroundStyle(MyoColor.Text.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !records.isEmpty { badges }
        }
        .padding(.vertical, MyoTheme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var weights: String {
        if abs(event.toLb - event.fromLb) < 0.25 { return WeightLoad.label(event.toLb, for: exerciseName) }
        return WeightLoad.change(from: event.fromLb, to: event.toLb, for: exerciseName)
    }

    private var badges: some View {
        HStack(spacing: 6) {
            ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                Text("PR · \(RecordText.kind(record.kind))")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(MyoColor.State.success.color)
                    .padding(.horizontal, MyoTheme.Spacing.sm)
                    .padding(.vertical, 3)
                    .background(MyoColor.State.success.color.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.top, 2)
    }
}

// MARK: Personal records (H3)

private enum RecordText {
    static func kind(_ kind: String) -> String {
        switch kind {
        case "heaviest": return "Heaviest"
        case "most_reps": return "Most reps"
        case "best_e1rm": return "Best est. max"
        default: return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// "35 lb × 10"
    static func set(_ record: PersonalRecordModel) -> String {
        let weight = WeightLoad.label(record.weightLb, for: record.exerciseName)
        return record.reps > 0 ? "\(weight) × \(record.reps)" : weight
    }

    /// The big number: the set, or the estimate for a best-e1RM record.
    static func value(_ record: PersonalRecordModel) -> String {
        if record.kind == "best_e1rm", let e1rm = record.e1rmLb {
            return "≈ \(WeightLoad.number((e1rm * 2).rounded() / 2)) lb"
        }
        return set(record)
    }

    /// The small line: the date, and the set behind an estimate.
    static func detail(_ record: PersonalRecordModel) -> String {
        let date = HistoryDate.short(record.date)
        if record.kind == "best_e1rm", record.e1rmLb != nil { return "\(set(record)), \(date)" }
        return date
    }
}

/// Newest records across every lift ("Heaviest · KB Goblet Squat · 35 lb × 10 · Nov 4").
private struct RecordsSection: View {
    let records: [PersonalRecordModel]

    private var shown: [PersonalRecordModel] { Array(records.prefix(6)) }

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            MyoSectionLabel(text: "Personal records")
            MyoGroupCard {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, record in
                    if index > 0 { MyoHairline() }
                    RecordRow(record: record, showsName: true)
                }
            }
        }
    }
}

private struct RecordRow: View {
    let record: PersonalRecordModel
    let showsName: Bool

    var body: some View {
        HStack(alignment: .center, spacing: MyoTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(RecordText.kind(record.kind))
                    .myoStyle(.label)
                    .textCase(.uppercase)
                    .kerning(0.5)
                    .foregroundStyle(MyoColor.State.success.color)
                if showsName {
                    Text(record.exerciseName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(MyoColor.Text.primary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: MyoTheme.Spacing.sm)

            VStack(alignment: .trailing, spacing: 2) {
                Text(RecordText.value(record))
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(MyoColor.Text.primary.color)
                    .multilineTextAlignment(.trailing)
                Text(RecordText.detail(record))
                    .myoStyle(.detail)
                    .foregroundStyle(MyoColor.Text.tertiary.color)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Session detail (H4)

/// "+5 lb vs Oct 28", worked out on the phone from the logs.
private struct ExerciseComparison {
    let text: String
    let isUp: Bool
}

private enum SessionCompare {
    /// The heaviest set (most reps on a tie), in pounds. Nil with no load.
    static func topSet(_ exercise: LoggedExercise) -> (lb: Double, reps: Int)? {
        var best: (lb: Double, reps: Int)?
        for set in exercise.sets {
            guard let kg = set.loadKg, kg > 0 else { continue }
            let lb = HistoryWeight.pounds(kg: kg)
            let reps = set.reps ?? 0
            if let current = best, lb < current.lb || (lb == current.lb && reps <= current.reps) { continue }
            best = (lb, reps)
        }
        return best
    }

    static func totalReps(_ exercise: LoggedExercise) -> Int {
        exercise.sets.reduce(0) { $0 + ($1.reps ?? 0) }
    }

    /// The same lift in the most recent earlier session.
    static func previous(_ exercise: LoggedExercise, before log: WorkoutLogSummary,
                         in logs: [WorkoutLogSummary]) -> (date: String, exercise: LoggedExercise)? {
        let name = exercise.name.lowercased()
        let earlier = logs
            .filter { $0.sessionId != log.sessionId && $0.date < log.date }
            .sorted { $0.date > $1.date }
        for other in earlier {
            if let match = other.exercises.first(where: { $0.name.lowercased() == name }) {
                return (other.date, match)
            }
        }
        return nil
    }

    /// Top set against last time's: weight first, then reps; total reps
    /// for lifts without load. Nil the first time, or when they can't be
    /// compared (one loaded, one not; timed sets).
    static func compare(_ exercise: LoggedExercise, in log: WorkoutLogSummary,
                        logs: [WorkoutLogSummary]) -> ExerciseComparison? {
        // Timed sets keep seconds in `reps`: no "+15 reps" for a longer plank.
        guard !exercise.sets.contains(where: { ($0.durationSec ?? 0) > 0 }),
              let last = previous(exercise, before: log, in: logs) else { return nil }
        let vs = "vs \(HistoryDate.short(last.date))"
        let now = topSet(exercise)
        let then = topSet(last.exercise)
        if let now, let then {
            let dLb = ((now.lb - then.lb) * 2).rounded() / 2
            if dLb != 0 { return ExerciseComparison(text: "\(HistoryWeight.delta(dLb, for: exercise.name)) \(vs)", isUp: dLb > 0) }
            return repsComparison(now.reps - then.reps, vs: vs)
        }
        if now == nil, then == nil {
            let nowReps = totalReps(exercise)
            let thenReps = totalReps(last.exercise)
            guard nowReps > 0, thenReps > 0 else { return nil }
            return repsComparison(nowReps - thenReps, vs: vs)
        }
        return nil
    }

    private static func repsComparison(_ delta: Int, vs: String) -> ExerciseComparison {
        if delta == 0 { return ExerciseComparison(text: "Same \(vs)", isUp: false) }
        let reps = abs(delta) == 1 ? "rep" : "reps"
        return ExerciseComparison(text: "\(delta > 0 ? "+" : "−")\(abs(delta)) \(reps) \(vs)", isUp: delta > 0)
    }

    /// "35 lb each × 10", "12 reps", "0:45", "Done".
    static func setText(_ set: LoggedSet, exercise: String) -> String {
        var weight: String?
        if let kg = set.loadKg, kg > 0 {
            weight = WeightLoad.label(HistoryWeight.pounds(kg: kg), for: exercise)
        }
        // Timed first: a hold or cardio set also carries its seconds in
        // `reps`, so "45 reps" for a plank came from checking reps first.
        if let sec = set.durationSec, sec > 0 {
            let time = sec >= 60 ? "\(sec / 60):" + String(format: "%02d", sec % 60) : "\(sec) sec"
            if let weight { return "\(weight) · \(time)" }
            return time
        }
        if let reps = set.reps, reps > 0 {
            if let weight { return "\(weight) × \(reps)" }
            return "\(reps) reps"
        }
        return weight ?? "Done"
    }
}

/// Every exercise in one session, each set's weight × reps, and how the
/// top set compares with last time.
private struct SessionDetailView: View {
    let log: WorkoutLogSummary
    let allLogs: [WorkoutLogSummary]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MyoTheme.Spacing.lg) {
                header
                if log.exercises.isEmpty {
                    MyoGroupCard {
                        Text("No sets were logged for this session.")
                            .myoStyle(.body)
                            .foregroundStyle(MyoColor.Text.secondary.color)
                    }
                } else {
                    ForEach(Array(log.exercises.enumerated()), id: \.offset) { _, exercise in
                        ExerciseCard(exercise: exercise,
                                     comparison: SessionCompare.compare(exercise, in: log, logs: allLogs))
                    }
                }
            }
            .padding(.horizontal, MyoTheme.Spacing.md)
            .padding(.vertical, MyoTheme.Spacing.lg)
        }
        .background(PaperBackground())
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(MyoTheme.Colors.cream, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.sm) {
            Text(dateText)
                .myoStyle(.label)
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(MyoColor.redPen)
            Text(log.title)
                .myoStyle(.display)
                .foregroundStyle(MyoColor.Text.primary.color)
                .fixedSize(horizontal: false, vertical: true)
            Text(log.historyStatLine)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(MyoColor.Text.secondary.color)
        }
        .accessibilityElement(children: .combine)
    }

    private var dateText: String {
        guard let day = log.day else { return log.date }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

private struct ExerciseCard: View {
    let exercise: LoggedExercise
    let comparison: ExerciseComparison?

    var body: some View {
        MyoGroupCard {
            HStack(alignment: .firstTextBaseline, spacing: MyoTheme.Spacing.sm) {
                Text(exercise.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MyoColor.Text.primary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: MyoTheme.Spacing.sm)
                if let comparison {
                    Text(comparison.text)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(comparison.isUp ? MyoColor.State.success.color : MyoColor.Text.secondary.color)
                        .multilineTextAlignment(.trailing)
                }
            }
            .accessibilityElement(children: .combine)

            if exercise.sets.isEmpty {
                Text("No sets logged")
                    .myoStyle(.detail)
                    .foregroundStyle(MyoColor.Text.tertiary.color)
            } else {
                setsList
            }
        }
    }

    private var setsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(exercise.sets.enumerated()), id: \.offset) { index, set in
                setRow(index: index, set: set)
            }
        }
    }

    private func setRow(index: Int, set: LoggedSet) -> some View {
        let text = SessionCompare.setText(set, exercise: exercise.name)
        return HStack(spacing: MyoTheme.Spacing.md) {
            Text("\(index + 1)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(MyoColor.Text.tertiary.color)
                .frame(width: 20, alignment: .leading)
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(MyoColor.Text.primary.color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Set \(index + 1): \(text)")
    }
}
