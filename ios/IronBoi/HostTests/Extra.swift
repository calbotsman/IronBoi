import Foundation

// Bluetooth Heart Rate Measurement (0x2A37) parsing, from hand-built packets.
func extraChecks() {
    func parse(_ bytes: [UInt8]) -> HeartRateMeasurement.Reading? { HeartRateMeasurement.parse(Data(bytes)) }
    check(parse([0x00, 72]) == .init(bpm: 72, contactDetected: nil, rrIntervals: []), "UInt8 bpm")
    check(parse([0x01, 0x2C, 0x01]) == .init(bpm: 300, contactDetected: nil, rrIntervals: []), "UInt16 bpm, little-endian")
    check(parse([0x06, 80])?.contactDetected == true, "contact supported + detected")
    check(parse([0x04, 80])?.contactDetected == false, "contact supported, not detected")
    check(parse([0x02, 80])?.contactDetected == nil, "detected bit without supported bit means unknown")
    // Polar-style: contact + RR intervals of 1024 (1.0 s) and 512 (0.5 s).
    check(parse([0x16, 64, 0x00, 0x04, 0x00, 0x02]) == .init(bpm: 64, contactDetected: true, rrIntervals: [1.0, 0.5]),
          "RR intervals in 1/1024 s")
    // Energy expended (UInt16) comes before the RR intervals.
    check(parse([0x18, 90, 0x10, 0x00, 0x00, 0x04]) == .init(bpm: 90, contactDetected: nil, rrIntervals: [1.0]),
          "energy expended skipped before RR")
    check(parse([]) == nil, "empty packet")
    check(parse([0x01, 0x10]) == nil, "truncated UInt16 bpm")
    check(parse([0x08, 70, 0x01]) == nil, "truncated energy field")
}
