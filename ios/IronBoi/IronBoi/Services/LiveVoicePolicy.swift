import Foundation

/// Who is listening when the mic is on with live voice wanted — the regular
/// coach or the live one — and when to try live again. Pure: no audio, no
/// network, no clock; it returns what to do and the stage does it. That's
/// what lets the reconnect rules be tested (IronBoiTests).
///
/// The rule it keeps: the mic button on means something is listening. The
/// regular coach opens the mic the moment it's turned on; live connects
/// behind it and takes over once it's ready (and you're not mid-sentence).
/// If live fails or drops without you asking, the regular coach is back on
/// the mic at once, and live is retried in the background with backoff.
struct LiveVoicePolicy: Equatable {
    enum Mode: Equatable {
        /// Mic off.
        case off
        /// The regular coach has the mic (live may be connecting behind it).
        case regular
        /// The live coach has the mic.
        case live
    }

    /// Why a live connection ended.
    enum EndReason: String, Equatable {
        /// You turned it off (or the conversation ended): nothing to recover.
        case user
        /// No network path, or the connection stalled.
        case network
        /// The socket closed or failed.
        case closed
        /// Minting a token or opening the socket failed.
        case connectFailed
        /// Didn't get ready in time.
        case timeout
        /// The provider sent an error.
        case providerError
        /// No microphone input.
        case noMic
    }

    enum Effect: Equatable {
        /// Open the regular coach's mic (and listen).
        case openRegularMic
        /// Close everything the regular coach has open.
        case closeRegularMic
        /// Start a live connection (it stays in standby until handed over).
        case connectLive
        /// Live is ready: give it the mic as soon as you're not mid-turn.
        case handOverWhenIdle
        /// End the live connection, without releasing the audio session.
        case dropLive
        case scheduleRetry(after: TimeInterval)
        case cancelRetry
    }

    /// Waits between live attempts after a failure: 2 s, 4 s, 8 s, 15 s, then
    /// every 30 s.
    static let backoff: [TimeInterval] = [2, 4, 8, 15, 30]
    /// Attempts per mic-on before it settles on the regular coach (each one
    /// mints a token, and mints are capped per day).
    static let maxFailures = 6

    private(set) var mode: Mode = .off
    /// A live connection is being made or is ready, not yet holding the mic.
    private(set) var liveInFlight = false
    private(set) var failures = 0
    /// False after too many failures: the regular coach stays for this mic-on.
    private(set) var retrying = true

    /// The mic button turned on.
    mutating func micOn(liveWanted: Bool) -> [Effect] {
        guard mode == .off else { return [] }
        mode = .regular
        failures = 0
        retrying = liveWanted
        guard liveWanted else { return [.openRegularMic] }
        liveInFlight = true
        return [.openRegularMic, .connectLive]
    }

    /// The mic button turned off, or the conversation ended.
    mutating func micOff() -> [Effect] {
        guard mode != .off || liveInFlight else { return [] }
        mode = .off
        liveInFlight = false
        failures = 0
        return [.cancelRetry, .dropLive, .closeRegularMic]
    }

    /// The live connection said it's ready.
    mutating func liveReady() -> [Effect] {
        guard liveInFlight else { return [] }
        guard mode == .regular else {
            liveInFlight = false
            return mode == .off ? [.dropLive] : []
        }
        return [.handOverWhenIdle]
    }

    /// The stage gave live the mic. Not a success yet: a session that gets
    /// ready and then dies (quota, an error right after setup) would
    /// otherwise retry forever, a mint each time. See `liveHealthy`.
    mutating func handedOver() {
        guard mode == .regular, liveInFlight else { return }
        mode = .live
        liveInFlight = false
    }

    /// How long live must hold the mic before it counts as working and the
    /// backoff starts over. Failures that come back each time (quota, an
    /// error right after setup) kill a session within seconds; two minutes
    /// of talk is a connection that works, not a lucky one.
    static let healthyAfter: TimeInterval = 120

    /// Live has held the mic for `healthyAfter`: the backoff starts over.
    mutating func liveHealthy() {
        guard mode == .live else { return }
        failures = 0
    }

    /// The live connection ended, for whatever reason.
    mutating func liveEnded(_ reason: EndReason) -> [Effect] {
        guard mode != .off, reason != .user else {
            liveInFlight = false
            return []
        }
        let hadMic = mode == .live
        guard hadMic || liveInFlight else { return [] }
        mode = .regular
        liveInFlight = false
        failures += 1
        var effects: [Effect] = hadMic ? [.openRegularMic] : []
        if failures >= Self.maxFailures {
            retrying = false
        }
        if retrying {
            effects.append(.scheduleRetry(after: Self.delay(afterFailures: failures)))
        }
        return effects
    }

    /// A scheduled retry came due.
    mutating func retryDue() -> [Effect] {
        guard mode == .regular, !liveInFlight, retrying else { return [] }
        liveInFlight = true
        return [.connectLive]
    }

    static func delay(afterFailures failures: Int) -> TimeInterval {
        backoff[min(max(failures, 1), backoff.count) - 1]
    }
}
