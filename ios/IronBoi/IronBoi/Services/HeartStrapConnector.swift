import CoreBluetooth
import Foundation

/// Bluetooth heart-rate straps and anything that speaks the standard Heart
/// Rate Service (0x180D): Polar H9/H10, Wahoo TICKR, a Garmin watch in
/// "Broadcast heart rate" mode, Whoop with "HR Broadcast" on.
///
/// Pair once in Settings (HeartStrapView); after that the strap is
/// connected at workout start and let go at the end. Readings go to
/// `HeartRateHub` as source `.strap`. If the strap sleeps or drops
/// mid-workout, a new connect request is left pending: CoreBluetooth
/// requests don't time out, so it reconnects when the strap wakes.
/// docs/product/responsive-coach-plan.md §3.
@MainActor
final class HeartStrapConnector: NSObject, ObservableObject {
    static let shared = HeartStrapConnector()

    enum Status: Equatable {
        case bluetoothOff
        case notAllowed
        case idle
        case scanning
        case connecting
        case connected
    }

    struct Found: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
    }

    @Published private(set) var status: Status = .idle
    /// Straps seen while scanning, strongest signal first.
    @Published private(set) var found: [Found] = []
    /// The paired strap's name, if one is paired.
    @Published private(set) var pairedName: String?
    /// The last reading from the strap (also published to HeartRateHub).
    @Published private(set) var lastBpm: Int?

    static let heartRateService = CBUUID(string: "180D")
    static let measurement = CBUUID(string: "2A37")
    private static let idKey = "heartStrap.id"
    private static let nameKey = "heartStrap.name"

    /// Created on first use, so the Bluetooth permission prompt only appears
    /// when someone pairs a strap (or has one paired and starts a workout).
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var strap: CBPeripheral?
    /// Keep the strap connected (a workout or the pairing screen wants it).
    private var wanted = false
    /// What to do once Bluetooth reports it's on.
    private var pending: (() -> Void)?

    private let defaults = UserDefaults.standard

    override init() {
        super.init()
        pairedName = defaults.string(forKey: Self.nameKey)
    }

    var pairedId: UUID? { defaults.string(forKey: Self.idKey).flatMap(UUID.init(uuidString:)) }

    // MARK: - Pairing

    func startScan() {
        whenOn { [weak self] central in
            guard let self else { return }
            self.found = []
            self.status = self.strap?.state == .connected ? .connected : .scanning
            central.scanForPeripherals(withServices: [Self.heartRateService], options: nil)
        }
    }

    func stopScan() {
        central?.stopScan()
        if status == .scanning { status = .idle }
    }

    /// Pair this strap (forgetting any other) and connect to it, so the
    /// pairing screen can show its live reading.
    func pair(_ item: Found) {
        stopScan()
        if let old = strap, old.identifier != item.id { central?.cancelPeripheralConnection(old) }
        defaults.set(item.id.uuidString, forKey: Self.idKey)
        defaults.set(item.name, forKey: Self.nameKey)
        pairedName = item.name
        lastBpm = nil
        connect()
    }

    func forget() {
        disconnect()
        defaults.removeObject(forKey: Self.idKey)
        defaults.removeObject(forKey: Self.nameKey)
        pairedName = nil
        strap = nil
    }

    // MARK: - Workout

    /// Connect to the paired strap, if there is one. Called at workout start
    /// and when the pairing screen opens.
    func connect() {
        guard let id = pairedId else { return }
        wanted = true
        whenOn { [weak self] central in
            guard let self else { return }
            if let known = self.peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first {
                self.attach(known, central: central)
            } else {
                // Not seen since launch and not retrievable: find it by scanning.
                self.status = .scanning
                central.scanForPeripherals(withServices: [Self.heartRateService], options: nil)
            }
        }
    }

    /// Let go of the strap: the workout ended or the pairing screen closed.
    func disconnect() {
        wanted = false
        pending = nil
        central?.stopScan()
        if let strap { central?.cancelPeripheralConnection(strap) }
        lastBpm = nil
        if status != .bluetoothOff, status != .notAllowed { status = .idle }
    }

    private func attach(_ peripheral: CBPeripheral, central: CBCentralManager) {
        strap = peripheral
        peripheral.delegate = self
        if peripheral.state == .connected {
            status = .connected
            peripheral.discoverServices([Self.heartRateService])
        } else {
            status = .connecting
            central.connect(peripheral, options: nil)
        }
    }

    // MARK: - Bluetooth state

    private func whenOn(_ action: @escaping (CBCentralManager) -> Void) {
        let central = self.central ?? CBCentralManager(delegate: self, queue: .main)
        self.central = central
        if central.state == .poweredOn {
            action(central)
        } else {
            pending = { action(central) }
        }
    }

    private func update(for state: CBManagerState) {
        switch state {
        case .poweredOn:
            if status == .bluetoothOff || status == .notAllowed { status = .idle }
            let run = pending
            pending = nil
            run?()
        case .unauthorized:
            status = .notAllowed
        case .poweredOff, .unsupported:
            status = .bluetoothOff
        default:
            break
        }
    }

    fileprivate func received(_ data: Data) {
        guard let reading = HeartRateMeasurement.parse(data) else { return }
        // A strap that's on but not touching skin reports nonsense; skip it.
        if reading.contactDetected == false { return }
        guard (25...250).contains(reading.bpm) else { return }
        lastBpm = reading.bpm
        HeartRateHub.shared.publish(HeartSample(bpm: reading.bpm, at: Date(), source: .strap))
    }
}

// MARK: - CBCentralManagerDelegate (callbacks arrive on the main queue)

extension HeartStrapConnector: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { update(for: central.state) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            peripherals[peripheral.identifier] = peripheral
            if wanted, peripheral.identifier == pairedId {
                central.stopScan()
                attach(peripheral, central: central)
                return
            }
            let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Heart rate monitor"
            let item = Found(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
            found.removeAll { $0.id == item.id }
            found.append(item)
            found.sort { $0.rssi > $1.rssi }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard peripheral === strap else { return }
            status = .connected
            peripheral.discoverServices([Self.heartRateService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === strap else { return }
            AudioHub.log("strap: connect failed: \(error?.localizedDescription ?? "unknown")")
            if wanted { central.connect(peripheral, options: nil) } else { status = .idle }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === strap else { return }
            lastBpm = nil
            if wanted {
                // Asleep or out of range: wait for it to come back.
                AudioHub.log("strap: dropped (\(error?.localizedDescription ?? "no error")), waiting to reconnect")
                status = .connecting
                central.connect(peripheral, options: nil)
            } else {
                status = .idle
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension HeartStrapConnector: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.heartRateService }) else { return }
            peripheral.discoverCharacteristics([Self.measurement], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.measurement }) else { return }
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == Self.measurement, let value = characteristic.value else { return }
            received(value)
        }
    }
}

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
