import Foundation

/// When the coach's voice is allowed to change: once, for the session, and
/// only when the engine is really down.
///
/// One voice is the rule. But a provider outage used to leave a whole
/// workout on ticks and captions (watchdog F54). Lines failing can also just
/// mean the gym has no signal, so after two failed lines the backup engine
/// is tried once: if it answers, the network is fine and the engine isn't,
/// and the backup reads everything until the next workout. If it fails too,
/// it's the signal, and nothing changes.
struct BackupVoicePolicy {
    static let backupEngine = "chirp"
    /// Same as VoiceCache's low-signal window: at most one extra wait each
    /// time that window opens, so a dead network doesn't slow every line.
    static let probeSpacing: TimeInterval = 30

    private(set) var isActive = false
    private var lastProbeAt = Date.distantPast

    /// Whether this line should ask the backup engine after `engine` failed.
    /// `failingRepeatedly`: two lines failed within a minute.
    mutating func shouldTryBackup(after engine: String, failingRepeatedly: Bool, now: Date = Date()) -> Bool {
        guard engine != Self.backupEngine else { return false }
        // Already switched: a line started just before the switch.
        if isActive { return true }
        guard failingRepeatedly, now.timeIntervalSince(lastProbeAt) >= Self.probeSpacing else { return false }
        lastProbeAt = now
        return true
    }

    /// The backup read a line while the engine couldn't.
    mutating func backupAnswered() { isActive = true }
}
