// Plain-Swift checks for code that has no UI or Apple-device dependency:
// the Watch message format, heart-rate zones and zone smoothing (and, from
// Phase 3, the Bluetooth heart-rate parser). Compiled and run on the Mac by
// scripts/ios-host-tests.sh, locally and in CI. `check` (not `assert`)
// so the checks also run in optimized builds.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line): \(what)") }
}

// MARK: Watch messages round-trip

let state = WatchWorkoutState(
    sessionId: "abc", workoutName: "Upper A", exercise: "Bench", setNumber: 2, totalSets: 4, targetReps: 10,
    weightLb: 95, restEndsAt: Date(timeIntervalSince1970: 1000), nextExercise: "Row", caption: "Ready?",
    ageYears: 38, saveToHealth: true)
let messages: [WatchMessage] = [
    .state(state), .heart(bpm: 142, at: Date(timeIntervalSince1970: 5), activeEnergyKcal: 33.5),
    .heart(bpm: 90, at: Date(timeIntervalSince1970: 6), activeEnergyKcal: nil),
    .setDone, .endRequested, .end(sessionId: "abc", save: false), .endAccepted,
]
for message in messages {
    let data = message.encoded()
    check(data != nil, "encodes \(message)")
    check(data.flatMap(WatchMessage.decode) == message, "round-trips \(message)")
    // Apple's mirrored-session channel: 100 KB per 10 s.
    check((data?.count ?? .max) < 2_000, "small: \(message)")
}
check(WatchMessage.decode(Data("nonsense".utf8)) == nil, "garbage decodes to nil")

// MARK: Zones

// Age 38: max = 208 − 26.6 = 181.4.
check(HeartZones.zone(bpm: 100, ageYears: 38, observedPeak: nil) == 1, "55% → zone 1")
check(HeartZones.zone(bpm: 150, ageYears: 38, observedPeak: nil) == 4, "83% → zone 4")
check(HeartZones.zone(bpm: 175, ageYears: 38, observedPeak: nil) == 5, "96% → zone 5")
check(HeartZones.zone(bpm: 150, ageYears: nil, observedPeak: 190) == nil, "no age → no zone")
check(HeartZones.zone(bpm: 150, ageYears: 38, observedPeak: 200) == 3, "higher observed peak raises max")

// MARK: Zone smoothing and hysteresis

var tracker = ZoneTracker()
let t0 = Date(timeIntervalSince1970: 0)
func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
@discardableResult
func feed(_ bpm: Int, from: TimeInterval, through: TimeInterval) -> Int? {
    var zone: Int?
    for s in stride(from: from, through: through, by: 2) { zone = tracker.add(bpm: bpm, at: at(s), ageYears: 38, observedPeak: nil) }
    return zone
}
check(tracker.add(bpm: 100, at: at(0), ageYears: 38, observedPeak: nil) == 1, "first zone taken at once")
feed(100, from: 2, through: 10)
// One spike: the 10 s average barely moves and drops back, so the zone holds.
check(tracker.add(bpm: 180, at: at(12), ageYears: 38, observedPeak: nil) == 1, "a spike holds the zone")
check(feed(100, from: 14, through: 30) == 1, "back to zone 1")
// Sustained 170 (94%, zone 5) from t=32. The 10 s average reaches zone 5
// at t=42 (all 170); zone 5 must then hold 15 s, so with readings every 2 s
// it's taken at t=58 and not before.
check(feed(170, from: 32, through: 56) == 1, "zone held until the new one has lasted 15 s")
check(feed(170, from: 58, through: 58) == 5, "new zone taken after 15 s")
check(tracker.smoothedBpm == 170, "smoothed over the last 10 s")
tracker.reset()
check(tracker.zone == nil && tracker.smoothedBpm == nil, "reset clears")

extraChecks()

if failures > 0 { print("\(failures) host test(s) failed"); exit(1) }
print("host tests passed")
