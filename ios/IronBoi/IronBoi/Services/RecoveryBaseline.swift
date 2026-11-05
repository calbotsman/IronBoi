import Foundation

/// Recovery from Apple Health, as numbers the coach can use: the last 24 h
/// against your own usual, and whether today is clearly low.
///
/// Pure (no HealthKit) so it's unit-tested: HealthSync reads the samples,
/// this decides. Sent as `liveContext.recovery` (RecoveryContext in
/// functions/src/contracts/coach-agent.ts — keep keys and bounds in step).
///
/// The rules, and why (none of these are tuned to anyone's own data):
/// - **Baseline = median of the 28 daily values before the last 24 h.** A
///   median, so one bad night, a drink or a sensor glitch doesn't move it;
///   28 days, so it follows training blocks and seasons but not a single
///   week. Needs `minBaselineDays` (10) days with data, a third of the
///   window, or there's no baseline and that signal can't flag.
/// - **Resting HR flags at ≥ baseline + 7 bpm.** Day-to-day resting HR
///   varies by ~2–3 bpm in healthy adults, so +7 is well outside normal
///   wobble, the size of rise seen with illness, heat or poor recovery
///   (and the responsive-coach plan's number).
/// - **HRV (SDNN) flags at ≤ 80 % of baseline.** Wrist HRV is noisy — the
///   day-to-day coefficient of variation is often 10–20 % — so −20 % is a
///   real dip but not proof on its own.
/// - **Sleep flags under 6 h** of actual sleep in the last 24 h (in bed
///   doesn't count; a nap counts, so it's "the last 24 h", not "last night").
///   Under 6 h is the usual "short sleep" cut-off in sleep research; adults
///   are advised 7+.
/// - **Low = two or more flags at once.** Each signal alone misfires too
///   often (a forgotten Watch on the charger gives "3 h sleep"; one HRV spot
///   reading is noise), and two independent systems agreeing is what
///   "clearly low" means. The coach only ever *offers* a lighter session,
///   so a false positive costs one sentence, but crying wolf daily would
///   teach people to ignore it.
enum RecoveryBaseline {
    static let windowDays = 28
    static let minBaselineDays = 10
    static let restingHrRiseBpm = 7.0
    static let hrvDropFraction = 0.8
    static let shortSleepHours = 6.0
    static let signalsForLow = 2

    enum Signal: String, CaseIterable { case restingHrHigh = "resting_hr_high", hrvLow = "hrv_low", sleepShort = "sleep_short" }

    /// One value per 24 h window: `daysAgo` 0 is the last 24 h, 1 the 24 h
    /// before that, and so on.
    struct Daily: Equatable {
        let daysAgo: Int
        let value: Double
    }

    struct Summary: Equatable {
        var restingHr: Int?
        var restingHrBaseline: Int?
        var hrvMs: Int?
        var hrvBaselineMs: Int?
        var sleepHours: Double?
        var signals: [Signal]
        var isLow: Bool { signals.count >= RecoveryBaseline.signalsForLow }
        var hasData: Bool { restingHr != nil || hrvMs != nil || sleepHours != nil }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Today's value and its 28-day baseline (nil when too few days).
    static func split(_ days: [Daily]) -> (today: Double?, baseline: Double?) {
        let finite = days.filter { $0.value.isFinite && $0.value > 0 }
        let today = finite.first { $0.daysAgo == 0 }?.value
        let window = finite.filter { (1...windowDays).contains($0.daysAgo) }.map(\.value)
        return (today, window.count >= minBaselineDays ? median(window) : nil)
    }

    static func summarize(restingHr: [Daily], hrv: [Daily], sleepHours: Double?) -> Summary {
        let hr = split(restingHr)
        let hv = split(hrv)
        var signals: [Signal] = []
        if let today = hr.today, let base = hr.baseline, today >= base + restingHrRiseBpm { signals.append(.restingHrHigh) }
        if let today = hv.today, let base = hv.baseline, today <= base * hrvDropFraction { signals.append(.hrvLow) }
        if let sleepHours, sleepHours < shortSleepHours { signals.append(.sleepShort) }
        func bpm(_ v: Double?) -> Int? { v.map { Int($0.rounded()) }.flatMap { (25...150).contains($0) ? $0 : nil } }
        func ms(_ v: Double?) -> Int? { v.map { Int($0.rounded()) }.flatMap { (1...300).contains($0) ? $0 : nil } }
        return Summary(
            restingHr: bpm(hr.today), restingHrBaseline: bpm(hr.baseline),
            hrvMs: ms(hv.today), hrvBaselineMs: ms(hv.baseline),
            sleepHours: sleepHours.map { (min(max($0, 0), 24) * 10).rounded() / 10 },
            signals: signals)
    }

    /// Hours actually asleep in `window`, from sleep intervals that may
    /// overlap (a Watch and an Oura both writing the same night): merged
    /// first so the night isn't counted twice, clipped to the window.
    /// Nil when there's nothing, so "no data" never reads as "no sleep".
    static func sleepHours(asleep intervals: [DateInterval], in window: DateInterval) -> Double? {
        let clipped = intervals.compactMap { $0.intersection(with: window) }.filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        guard !clipped.isEmpty else { return nil }
        var total: TimeInterval = 0
        var current = clipped[0]
        for next in clipped.dropFirst() {
            if next.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, next.end))
            } else {
                total += current.duration
                current = next
            }
        }
        total += current.duration
        return total / 3600
    }

    /// The `liveContext.recovery` payload. `offerLighter` is the once-a-day
    /// go-ahead for the coach to offer a lighter session (AppModel decides).
    static func payload(_ summary: Summary, offerLighter: Bool) -> [String: Any]? {
        guard summary.hasData else { return nil }
        var out: [String: Any] = ["signals": summary.signals.map(\.rawValue), "low": summary.isLow]
        if let v = summary.restingHr { out["restingHr"] = v }
        if let v = summary.restingHrBaseline { out["restingHrBaseline"] = v }
        if let v = summary.hrvMs { out["hrvMs"] = v }
        if let v = summary.hrvBaselineMs { out["hrvBaselineMs"] = v }
        if let v = summary.sleepHours { out["sleepHours"] = v }
        if summary.isLow { out["offerLighter"] = offerLighter }
        return out
    }

    /// Whether a coach reply is the lighter-session offer ("Recovery's low
    /// today, want a lighter version?"), so it counts as made only once
    /// it was actually said, not when the coach was cleared to say it.
    static func mentionsLighterOffer(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("lighter") || t.contains("easier") || t.contains("recovery") || t.contains("dial it back")
    }

    /// Whether the coach may offer the lighter version now: recovery is
    /// clearly low, it hasn't been offered today, and the workout hasn't
    /// really started (none running, or no set done yet).
    static func mayOfferLighter(summary: Summary?, offeredOn: String?, today: String, setsDone: Int?) -> Bool {
        guard let summary, summary.isLow, offeredOn != today else { return false }
        return (setsDone ?? 0) == 0
    }
}
