import Foundation
import CoreBluetooth
import Combine
import SwiftUI

final class ClipBLE: NSObject, ObservableObject {
    static let shared = ClipBLE()

    static let serviceUUID = CBUUID(string: "7C1A0001-5E6B-4D2C-9A3F-2B8E1C0D4A10")
    static let repUUID     = CBUUID(string: "7C1A0002-5E6B-4D2C-9A3F-2B8E1C0D4A10")
    static let cmdUUID     = CBUUID(string: "7C1A0003-5E6B-4D2C-9A3F-2B8E1C0D4A10")
    static let battUUID    = CBUUID(string: "7C1A0004-5E6B-4D2C-9A3F-2B8E1C0D4A10")
    static let rssiUUID    = CBUUID(string: "7C1A0005-5E6B-4D2C-9A3F-2B8E1C0D4A10")
    static let streamUUID  = CBUUID(string: "7C1A0006-5E6B-4D2C-9A3F-2B8E1C0D4A10")

    enum State: String { case off, idle, scanning, found, connecting, connected, failed }

    struct Failure: Equatable {
        let title: String
        let hint: String
    }

    @Published var state: State = .off
    @Published var reps = 0
    @Published var tempoMs = 0
    @Published var battery: Int?
    @Published var rssi: Int?
    @Published var clipRssi: Int?
    @Published var failure: Failure?

    // Raw motion stream from the clip (6 samples per packet, 100 Hz). While `streaming` is on the
    // app counts reps itself with the RepEngine; the clip's own count is the fallback.
    var onSample: ((MotionSample) -> Void)?
    var streamSupported: Bool { streamChr != nil }
    private(set) var streamSamples = 0
    private var streamSeq: Int?
    private var streamIndex = 0
    var streaming = false {
        didSet {
            guard streaming != oldValue else { return }
            if let clip, let streamChr { clip.setNotifyValue(streaming, for: streamChr) }
            if streaming {
                streamSeq = nil
                streamIndex = 0
                streamSamples = 0
            }
        }
    }

    // The Find screen turns this on: the phone then reads signal strength five times a second
    // and asks the clip to report its own reading of the phone, instead of once a second.
    var finding = false {
        didSet {
            guard finding != oldValue else { return }
            if state == .connected { startRssiTimer() }
            if let clip, let rssiChr { clip.setNotifyValue(finding, for: rssiChr) }
            if !finding { clipRssi = nil }
        }
    }

    // The connection sheet turns this on while it is showing. Then a found clip waits at `.found`
    // until `connectFound()` is called, and searching or connecting for too long ends in `.failed`.
    // Off (the default), a found clip connects straight away and searching never gives up.
    var interactive = false

    private var central: CBCentralManager!
    private var clip: CBPeripheral?
    private var cmd: CBCharacteristic?
    private var rssiChr: CBCharacteristic?
    private var streamChr: CBCharacteristic?
    private var wantsConnection = false
    private var rssiTimer: Timer?
    private var scanTimer: Timer?
    private var connectTimer: Timer?

    private let scanTimeout: TimeInterval = 15
    private let connectTimeout: TimeInterval = 10

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func connect() {
        wantsConnection = true
        failure = nil
        switch central.state {
        case .poweredOn:
            scan()
        case .poweredOff:
            fail(Failure(title: "Bluetooth is off", hint: "Turn on Bluetooth, then try again."))
        case .unauthorized:
            fail(Failure(title: "Bluetooth isn't allowed", hint: "Allow Bluetooth for Clip in Settings, then try again."))
        default:
            break
        }
    }

    func connectFound() {
        guard let clip, central.state == .poweredOn, state != .connecting, state != .connected else { return }
        failure = nil
        state = .connecting
        connectTimer?.invalidate()
        connectTimer = Timer.scheduledTimer(withTimeInterval: connectTimeout, repeats: false) { [weak self] _ in
            self?.retryOrFail(Failure(title: "Clip didn't respond", hint: "Move closer to the clip and try again."))
        }
        central.connect(clip)
    }

    func disconnect() {
        wantsConnection = false
        central.stopScan()
        if let clip { central.cancelPeripheralConnection(clip) }
        reset()
        failure = nil
        state = central.state == .poweredOn ? .idle : .off
    }

    func startSet() { reps = 0; send(0x01) }
    func endSet() { send(0x02) }
    func find() { send(0x03) }
    func stopFind() { send(0x04) }
    func flashRep() { sendNoResponse(0x07) }

    private func scan() {
        guard central.state == .poweredOn, wantsConnection, clip == nil else { return }
        state = .scanning
        central.scanForPeripherals(withServices: [Self.serviceUUID])
        scanTimer?.invalidate()
        if interactive {
            scanTimer = Timer.scheduledTimer(withTimeInterval: scanTimeout, repeats: false) { [weak self] _ in
                self?.fail(Failure(title: "Couldn't find your Clip", hint: "Check it's switched on and nearby, then try again."))
            }
        }
    }

    private func fail(_ failure: Failure) {
        central.stopScan()
        if let clip { central.cancelPeripheralConnection(clip) }
        reset()
        self.failure = failure
        state = .failed
    }

    // With the sheet showing, report the problem. Without it, keep trying quietly like before.
    private func retryOrFail(_ failure: Failure) {
        if interactive {
            fail(failure)
        } else {
            central.stopScan()
            if let clip { central.cancelPeripheralConnection(clip) }
            reset()
            state = .idle
            scan()
        }
    }

    private func becomeConnected() {
        connectTimer?.invalidate()
        connectTimer = nil
        state = .connected
        startRssiTimer()
    }

    private func startRssiTimer() {
        rssiTimer?.invalidate()
        rssiTimer = Timer.scheduledTimer(withTimeInterval: finding ? 0.2 : 1.0, repeats: true) { [weak self] _ in
            self?.clip?.readRSSI()
        }
        clip?.readRSSI()
    }

    private func send(_ byte: UInt8) {
        guard let clip, let cmd else { return }
        clip.writeValue(Data([byte]), for: cmd, type: .withResponse)
    }

    private func sendNoResponse(_ byte: UInt8) {
        guard let clip, let cmd else { return }
        clip.writeValue(Data([byte]), for: cmd, type: .withoutResponse)
    }

    private func reset() {
        clip = nil
        cmd = nil
        rssiChr = nil
        streamChr = nil
        streaming = false
        rssi = nil
        clipRssi = nil
        rssiTimer?.invalidate(); rssiTimer = nil
        scanTimer?.invalidate(); scanTimer = nil
        connectTimer?.invalidate(); connectTimer = nil
    }
}

extension ClipBLE: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            state = .idle
            scan()
        } else {
            reset()
            state = .off
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        central.stopScan()
        scanTimer?.invalidate()
        scanTimer = nil
        clip = peripheral
        rssi = RSSI.intValue
        if interactive {
            state = .found
        } else {
            connectFound()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == clip else { return }
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == clip else { return }
        if wantsConnection {
            retryOrFail(Failure(title: "Couldn't connect", hint: "Move closer to the clip and try again."))
        } else {
            reset()
            state = .idle
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == clip else { return }
        let wasConnected = state == .connected
        if !wantsConnection {
            reset()
            state = central.state == .poweredOn ? .idle : .off
        } else if wasConnected {
            reset()
            state = .idle
            scan()
        } else {
            retryOrFail(Failure(title: "Clip disconnected", hint: "Move closer to the clip and try again."))
        }
    }
}

extension ClipBLE: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            retryOrFail(Failure(title: "Clip didn't respond", hint: "Restart the clip, then try again."))
            return
        }
        peripheral.discoverCharacteristics([Self.repUUID, Self.cmdUUID, Self.battUUID, Self.rssiUUID, Self.streamUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case Self.repUUID:
                peripheral.setNotifyValue(true, for: c)
            case Self.cmdUUID:
                cmd = c
            case Self.battUUID:
                peripheral.readValue(for: c)
                peripheral.setNotifyValue(true, for: c)
            case Self.rssiUUID:
                rssiChr = c
                if finding { peripheral.setNotifyValue(true, for: c) }
            case Self.streamUUID:
                streamChr = c
                if streaming { peripheral.setNotifyValue(true, for: c) }
            default:
                break
            }
        }
        if cmd != nil {
            becomeConnected()
        } else {
            retryOrFail(Failure(title: "Clip didn't respond", hint: "Restart the clip, then try again."))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let b = [UInt8](data)
        if characteristic.uuid == Self.repUUID, b.count >= 4 {
            reps = Int(b[0]) | Int(b[1]) << 8
            tempoMs = Int(b[2]) | Int(b[3]) << 8
        } else if characteristic.uuid == Self.battUUID, let first = b.first {
            battery = Int(first)
        } else if characteristic.uuid == Self.rssiUUID, let first = b.first {
            let value = Int(Int8(bitPattern: first))
            clipRssi = value < 0 ? value : nil
        } else if characteristic.uuid == Self.streamUUID {
            parseStream(b)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        rssi = RSSI.intValue
    }

    // [seq][count] then count × (ax, ay, az in cm/s², gx, gy, gz in 0.1 °/s) as int16 little-endian.
    // Sample times are built from the packet sequence, so a dropped packet leaves a gap in time
    // rather than squeezing the samples together.
    private func parseStream(_ b: [UInt8]) {
        guard b.count >= 2 else { return }
        let seq = Int(b[0])
        let count = Int(b[1])
        guard b.count >= 2 + count * 12 else { return }
        if let last = streamSeq {
            let missed = (seq - last - 1 + 256) % 256
            streamIndex += missed * 6
        }
        streamSeq = seq
        for i in 0..<count {
            let o = 2 + i * 12
            func v(_ k: Int) -> Double {
                Double(Int16(bitPattern: UInt16(b[o + 2 * k]) | UInt16(b[o + 2 * k + 1]) << 8))
            }
            let sample = MotionSample(t: Double(streamIndex) * RepConstants.dt,
                                      ax: v(0) / 100, ay: v(1) / 100, az: v(2) / 100,
                                      gx: v(3) / 10, gy: v(4) / 10, gz: v(5) / 10)
            streamIndex += 1
            streamSamples += 1
            onSample?(sample)
        }
    }
}

struct ClipStatusView: View {
    @ObservedObject var ble = ClipBLE.shared

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(ble.state.rawValue.capitalized)
            if let b = ble.battery {
                Label("\(b)%", systemImage: "battery.75")
            }
            if let r = ble.rssi {
                Text("\(r) dBm").monospacedDigit().foregroundStyle(.secondary)
            }
            if ble.state == .connected && !ble.streamSupported {
                Text("old firmware").foregroundStyle(.orange)
            }
            Spacer()
        }
        .font(.subheadline)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var color: Color {
        switch ble.state {
        case .connected: return .green
        case .scanning, .found, .connecting: return .orange
        case .failed: return .red
        default: return .gray
        }
    }
}
