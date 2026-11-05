import Foundation

// MARK: - Heart Rate Measurement (0x2A37)

/// Parses the Bluetooth Heart Rate Measurement characteristic.
/// Flags byte: bit 0 = bpm is UInt16 (else UInt8); bits 1–2 = sensor
/// contact (bit 2 supported, bit 1 detected); bit 3 = energy expended
/// (UInt16) present; bit 4 = RR intervals (UInt16 each, 1/1024 s) follow.
/// All multi-byte fields are little-endian.
enum HeartRateMeasurement {
    struct Reading: Equatable {
        let bpm: Int
        /// Nil when the sensor doesn't report skin contact.
        let contactDetected: Bool?
        /// Beat-to-beat intervals in seconds, when sent.
        let rrIntervals: [Double]
    }

    static func parse(_ data: Data) -> Reading? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        var index = 1
        func uint16() -> Int? {
            guard index + 1 < bytes.count else { return nil }
            defer { index += 2 }
            return Int(bytes[index]) | Int(bytes[index + 1]) << 8
        }
        let bpm: Int
        if flags & 0x01 != 0 {
            guard let value = uint16() else { return nil }
            bpm = value
        } else {
            guard index < bytes.count else { return nil }
            bpm = Int(bytes[index])
            index += 1
        }
        let contact: Bool? = flags & 0x04 != 0 ? flags & 0x02 != 0 : nil
        if flags & 0x08 != 0 { guard uint16() != nil else { return nil } }
        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while let value = uint16() { rr.append(Double(value) / 1024) }
        }
        return Reading(bpm: bpm, contactDetected: contact, rrIntervals: rr)
    }
}
