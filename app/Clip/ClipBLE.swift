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

      enum State: String { case off, idle, scanning, connecting, connected }

      @Published var state: State = .off
      @Published var reps = 0
      @Published var tempoMs = 0
      @Published var battery: Int?
      @Published var rssi: Int?

      private var central: CBCentralManager!
      private var clip: CBPeripheral?
      private var cmd: CBCharacteristic?
      private var wantsConnection = false
      private var rssiTimer: Timer?

      private override init() {
                super.init()
                central = CBCentralManager(delegate: self, queue: .main)
      }

      func connect() {
                wantsConnection = true
                scan()
      }

      func disconnect() {
                wantsConnection = false
                central.stopScan()
                if let clip { central.cancelPeripheralConnection(clip) }
                state = central.state == .poweredOn ? .idle : .off
      }

      func startSet() { reps = 0; send(0x01) }
      func endSet() { send(0x02) }
      func find() { send(0x03) }

      private func scan() {
                guard central.state == .poweredOn, wantsConnection, clip == nil else { return }
                state = .scanning
                central.scanForPeripherals(withServices: [Self.serviceUUID])
      }

      private func send(_ byte: UInt8) {
                guard let clip, let cmd else { return }
                clip.writeValue(Data([byte]), for: cmd, type: .withResponse)
      }

      private func reset() {
                clip = nil
                cmd = nil
                rssi = nil
                rssiTimer?.invalidate()
                rssiTimer = nil
      }
}

extension ClipBLE: CBCentralManagerDelegate {
      func centralManagerDidUpdateState(_ central: CBCentralManager) {
                if central.state == .poweredOn {
                              state = .idle
                              scan()
                } else {
                              state = .off
                              reset()
                }
      }

      func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                                  advertisementData: [String: Any], rssi RSSI: NSNumber) {
                central.stopScan()
                clip = peripheral
                rssi = RSSI.intValue
                state = .connecting
                central.connect(peripheral)
      }

      func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
                peripheral.delegate = self
                peripheral.discoverServices([Self.serviceUUID])
                state = .connected
                rssiTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                                                                                                    self?.clip?.readRSSI()
                                                                                       }
      }

      func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
                reset()
                state = .idle
                scan()
      }

      func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
                reset()
                state = .idle
                scan()
      }
}

extension ClipBLE: CBPeripheralDelegate {
      func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
                for service in peripheral.services ?? [] where service.uuid == Self.serviceUUID {
                              peripheral.discoverCharacteristics([Self.repUUID, Self.cmdUUID, Self.battUUID], for: service)
                }
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
                                            default:
                                                break
                              }
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
                }
      }

      func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
                rssi = RSSI.intValue
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
                              Spacer()
                              Button {
                                                ble.find()
                              } label: {
                                                Label("Find", systemImage: "location.magnifyingglass")
                              }
                              .buttonStyle(.bordered)
                              .disabled(ble.state != .connected)
                }
                .font(.subheadline)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
      }

      private var color: Color {
                switch ble.state {
                          case .connected: return .green
                          case .scanning, .connecting: return .orange
                          default: return .gray
                }
      }
}
