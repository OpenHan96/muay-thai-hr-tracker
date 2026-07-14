import Foundation
import CoreBluetooth

enum BTStatus: Equatable {
    case idle, searching, connecting, connected(String), reconnecting, disconnected, demo
    var label: String {
        switch self {
        case .idle: return "Not connected"
        case .searching: return "Searching…"
        case .connecting: return "Connecting…"
        case .connected(let n): return n
        case .reconnecting: return "Reconnecting…"
        case .disconnected: return "Disconnected"
        case .demo: return "Demo HR"
        }
    }
    var isLive: Bool { if case .connected = self { return true }; return self == .demo }
}

/// Connects to a standard BLE Heart Rate Monitor (service 0x180D, char 0x2A37)
/// using the iPhone's own Bluetooth — no Bluefy. Mirrors the web app's BT layer.
final class HeartRateMonitor: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var bpm: Int = 0
    @Published var lastBeat: Date = .distantPast
    @Published var status: BTStatus = .idle
    @Published var battery: Int? = nil

    private let hrService = CBUUID(string: "180D")
    private let hrMeasurement = CBUUID(string: "2A37")
    private let batteryService = CBUUID(string: "180F")
    private let batteryLevel = CBUUID(string: "2A19")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var demoTimer: Timer?
    private var demoBase = 75.0
    /// External hook so the session engine can drive demo target HR (rest vs work).
    var demoTarget: () -> Double = { 75 }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isDemo: Bool { status == .demo }

    private let lastDeviceKey = "fighthr.lastHRDevice"
    private var wantsScan = false

    // MARK: connect
    func connect() {
        stopDemo()
        if let p = peripheral { central.cancelPeripheralConnection(p); peripheral = nil }
        guard central.state == .poweredOn else { wantsScan = true; status = .searching; return }
        status = .searching
        central.scanForPeripherals(withServices: [hrService])
    }

    /// Silently reconnect to the last strap on launch, so HR is live without
    /// tapping Connect first (the connect stays pending until the strap is on).
    private func autoReconnect() {
        guard let saved = UserDefaults.standard.string(forKey: lastDeviceKey),
              let id = UUID(uuidString: saved),
              let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        peripheral = p
        p.delegate = self
        status = .connecting
        central.connect(p)
    }

    func disconnect() {
        watchdog?.invalidate(); watchdog = nil
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        status = .idle
    }

    /// If the strap goes silent while "connected" (BLE stack wedged, armband
    /// dozed off), force a reconnect instead of freezing on a stale number.
    private var watchdog: Timer?
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, case .connected = self.status else { return }
            if Date().timeIntervalSince(self.lastBeat) > 12, let p = self.peripheral {
                self.status = .reconnecting
                self.central.cancelPeripheralConnection(p)   // didDisconnect → auto-reconnect
            }
        }
    }

    // MARK: demo
    func toggleDemo() {
        if status == .demo { stopDemo(); status = .idle; return }
        disconnect()
        status = .demo
        demoBase = 75
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let target = self.demoTarget()
            self.demoBase += (target - self.demoBase) * 0.05 + Double.random(in: -2...2)
            self.ingest(Int(min(195, max(55, self.demoBase)).rounded()))
        }
    }
    private func stopDemo() { demoTimer?.invalidate(); demoTimer = nil }

    private func ingest(_ hr: Int) {
        guard hr > 0, hr < 250 else { return }
        bpm = hr
        lastBeat = Date()
    }

    /// HR is "fresh" if a beat arrived in the last 8s (mirrors hrFresh guard).
    var isFresh: Bool { Date().timeIntervalSince(lastBeat) < 8 }

    // MARK: CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn {
            if wantsScan {
                wantsScan = false
                status = .searching
                c.scanForPeripherals(withServices: [hrService])
            } else if status == .idle {
                autoReconnect()
            }
        } else if status != .demo {
            status = .disconnected
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        c.stopScan()
        peripheral = p
        p.delegate = self
        status = .connecting
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        UserDefaults.standard.set(p.identifier.uuidString, forKey: lastDeviceKey)
        p.discoverServices([hrService, batteryService])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard status != .demo else { return }
        status = .disconnected
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard status != .idle, status != .demo else { return }
        status = .reconnecting
        c.connect(p)   // CoreBluetooth retries the known peripheral indefinitely
    }

    // MARK: CBPeripheralDelegate
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] {
            if s.uuid == hrService { p.discoverCharacteristics([hrMeasurement], for: s) }
            if s.uuid == batteryService { p.discoverCharacteristics([batteryLevel], for: s) }
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == hrMeasurement {
                p.setNotifyValue(true, for: ch)
                lastBeat = Date()   // seed freshness so the watchdog waits for real data
                status = .connected(p.name ?? "HR monitor")
                startWatchdog()
            }
            if ch.uuid == batteryLevel { p.readValue(for: ch) }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let data = ch.value else { return }
        if ch.uuid == hrMeasurement { parseHR(data) }
        if ch.uuid == batteryLevel, let b = data.first { battery = Int(b) }
    }

    /// Flags byte: bit0 = 16-bit HR. Mirrors onHrNotify in index.html.
    private func parseHR(_ data: Data) {
        guard data.count >= 2 else { return }
        let flags = data[0]
        let uses16BitValue = (flags & 0x01) != 0
        guard !uses16BitValue || data.count >= 3 else { return }
        let hr = uses16BitValue ? Int(data[1]) | (Int(data[2]) << 8) : Int(data[1])
        ingest(hr)
    }
}
