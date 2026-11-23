import Foundation

/// When the coach's voice is allowed to change: rarely, briefly, and only
/// when the engine is really down.
///
/// One voice is the rule. But a provider outage used to leave a whole
/// workout on ticks and captions (watchdog F54). Lines failing can also just
/// mean the gym has no signal, so after failures from two separate replies
/// the backup engine is tried once: if it answers, the network is fine and
/// the engine isn't, and the backup reads lines for a few minutes before the
/// coach's own voice is tried again. If it fails too, it's the signal, and
/// nothing changes. Never while live voice is on: live answers in its own
/// voice, so a backup for the app's lines would be a second person (F56).
struct BackupVoicePolicy {
    static let backupEngine = "chirp"
    /// At most one extra wait per window, so a dead network doesn't slow
    /// every line.
    static let probeSpacing: TimeInterval = 30
    /// Failures this far apart came from two replies, not one reply whose
    /// sentences timed out together (F57).
    static let separateFailureGap: TimeInterval = 5
    /// Then the coach's own voice gets another go: an outage that's over
    /// shouldn't keep the backup for the rest of the workout (F57).
    static let recheckAfter: TimeInterval = 5 * 60

    private var activeSince: Date?
    private var lastProbeAt = Date.distantPast

    func isActive(now: Date = Date()) -> Bool {
        activeSince.map { now.timeIntervalSince($0) < Self.recheckAfter } ?? false
    }

    /// Whether this line should ask the backup engine after `engine` failed.
    /// `failures`: when lines failed in the last minute, oldest first.
    mutating func shouldTryBackup(after engine: String, failures: [Date], liveActive: Bool, now: Date = Date()) -> Bool {
        guard !liveActive, engine != Self.backupEngine else { return false }
        // Already switched: a line started just before the switch.
        if isActive(now: now) { return true }
        guard let first = failures.first, let last = failures.last,
              last.timeIntervalSince(first) >= Self.separateFailureGap,
              now.timeIntervalSince(lastProbeAt) >= Self.probeSpacing else { return false }
        lastProbeAt = now
        return true
    }

    /// The backup read a line while the engine couldn't.
    mutating func backupAnswered(now: Date = Date()) {
        if !isActive(now: now) { activeSince = now }
    }
}
