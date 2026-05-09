//
//  BLEManager.swift
//  OpenRM
//
//  CoreBluetooth wrapper for the ResMed AirSense 11.
//  Handles scanning, connection, characteristic I/O.
//

import Foundation
import Combine
import CoreBluetooth
import os

private let bleLog = Logger(subsystem: "com.openrm.cpap", category: "BLE")

final class BLEManager: NSObject, ObservableObject {
    // UUIDs from libpacific-figlib reverse engineering
    static let serviceUUID = CBUUID(string: "0000fd56-0000-1000-8000-00805f9b34fb")
    static let txCharUUID = CBUUID(string: "A6220002-35F1-4B20-AFAE-CB089D2044AA")
    static let rxCharUUID = CBUUID(string: "A6220003-35F1-4B20-AFAE-CB089D2044AA")

    /// CoreBluetooth state-restoration identifier. Passing this to the
    /// CBCentralManager initializer opts the manager into iOS's BLE
    /// state restoration: if the app is terminated while subscribed
    /// to a peripheral characteristic, iOS relaunches us headlessly
    /// when a relevant BLE event arrives (e.g., CPAP sends an
    /// EventNotification), invokes `centralManager(_:willRestoreState:)`
    /// with the preserved peripheral + subscription list, and we pick
    /// up where we left off without ever showing UI.
    static let restorationIdentifier = "com.openrm.cpap.central"

    @Published var state: State = .disconnected
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var deviceName: String?

    /// True once CBCentralManager has reported `.poweredOn`. At app
    /// launch this is false for a few hundred ms while CoreBluetooth
    /// initialises; auto-connect logic should wait on this before trying
    /// to scan or retrieve peripherals.
    @Published var isBluetoothReady: Bool = false

    enum State: Equatable {
        case disconnected
        case bluetoothOff
        case scanning
        case connecting
        case connected
        case ready   // services discovered, notifications enabled
        case error(String)
    }

    struct DiscoveredDevice: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
        let peripheral: CBPeripheral
        let advertisedServices: [CBUUID]

        static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// Called when notification data arrives from the CPAP.
    var onData: ((Data) -> Void)?

    /// UUID of the currently-connected peripheral, if any. Used by the
    /// credential store so we can skip scanning on subsequent launches.
    var currentPeripheralIdentifier: UUID? { peripheral?.identifier }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var rxChar: CBCharacteristic?
    private var readyContinuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        // Passing a restore identifier enables iOS BLE state restoration.
        // The system will relaunch us in the background when our
        // subscribed peripheral has events; see `centralManager(_:
        // willRestoreState:)`. REQUIRES the `bluetooth-central`
        // UIBackgroundMode to be declared in Info.plist — otherwise
        // the CBCentralManager initializer throws a hard
        // NSInternalInconsistencyException. We guard against that
        // here: if the background mode isn't declared (e.g. the
        // build's auto-generated Info.plist dropped it), the app
        // runs in foreground-only mode without restoration rather
        // than crashing on launch.
        let hasBluetoothCentralMode: Bool = {
            guard let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes")
                    as? [String] else { return false }
            return modes.contains("bluetooth-central")
        }()
        if hasBluetoothCentralMode {
            let options: [String: Any] = [
                CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier,
            ]
            self.central = CBCentralManager(delegate: self, queue: .main, options: options)
        } else {
            bleLog.error("UIBackgroundModes lacks 'bluetooth-central' — state restoration disabled; BGTask sync remains available.")
            self.central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func startScan() {
        let authStatus = CBCentralManager.authorization
        bleLog.info("startScan: central.state=\(self.central.state.rawValue) authorization=\(authStatus.rawValue) isScanning=\(self.central.isScanning)")
        guard central.state == .poweredOn else {
            bleLog.error("startScan: BT not powered on")
            state = .bluetoothOff
            return
        }
        discoveredDevices.removeAll()
        state = .scanning
        // Scan WITHOUT a service filter — we'll match by name/service
        // in didDiscover. Filtered scans can miss devices whose
        // advertisement packet doesn't include the service UUID
        // (ResMed only includes it in some advertising modes).
        bleLog.info("startScan: starting scan (no service filter)")
        central.scanForPeripherals(withServices: nil, options: nil)
        bleLog.info("startScan: isScanning after call = \(self.central.isScanning)")
    }

    func stopScan() {
        central.stopScan()
        if case .scanning = state { state = .disconnected }
    }

    /// How long to wait for a BLE connect + service discovery before
    /// giving up. CoreBluetooth's connect() has no built-in timeout —
    /// it'll queue a connection request forever if the peripheral is
    /// out of range or paired elsewhere. Ten seconds is generous: the
    /// normal success case is ~1-2s.
    private static let connectTimeoutNanos: UInt64 = 10_000_000_000

    func connect(_ device: DiscoveredDevice) async throws {
        stopScan()
        peripheral = device.peripheral
        peripheral?.delegate = self
        deviceName = device.name
        state = .connecting

        try await withConnectTimeout {
            try await withCheckedThrowingContinuation { continuation in
                self.readyContinuation = continuation
                self.central.connect(device.peripheral, options: nil)
            }
        }
    }

    /// Reconnect directly to a previously-paired peripheral by its UUID,
    /// skipping scanning. Returns nil if the system no longer knows about
    /// the peripheral (in which case fall back to a scan).
    func connectByIdentifier(_ id: UUID) async throws -> Bool {
        bleLog.info("connectByIdentifier: id=\(id) central.state=\(self.central.state.rawValue)")
        guard central.state == .poweredOn else {
            bleLog.error("connectByIdentifier: BT not powered on")
            state = .bluetoothOff
            return false
        }
        let known = central.retrievePeripherals(withIdentifiers: [id])
        bleLog.info("connectByIdentifier: retrievePeripherals returned \(known.count) peripheral(s)")
        guard let p = known.first else {
            bleLog.info("connectByIdentifier: peripheral not known to system")
            return false
        }

        stopScan()
        peripheral = p
        p.delegate = self
        deviceName = p.name
        state = .connecting

        try await withConnectTimeout {
            try await withCheckedThrowingContinuation { continuation in
                self.readyContinuation = continuation
                self.central.connect(p, options: nil)
            }
        }
        return true
    }

    /// Race a CB connect attempt against a timeout. If it times out,
    /// cancel the pending connect, tear down state, and throw.
    private func withConnectTimeout(_ body: @escaping () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.connectTimeoutNanos)
                throw BLEError.connectTimeout
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                // On timeout or failure, cancel any pending connect and
                // resume the waiter with the error so callers see it.
                if let p = self.peripheral {
                    self.central.cancelPeripheralConnection(p)
                }
                if let cont = self.readyContinuation {
                    self.readyContinuation = nil
                    cont.resume(throwing: error)
                }
                self.state = .error("connect timeout")
                group.cancelAll()
                throw error
            }
        }
    }

    func disconnect() {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
    }

    /// Write data to the TX characteristic. Chunks automatically to MTU.
    func write(_ data: Data) throws {
        guard state == .ready, let peripheral = peripheral, let txChar = txChar else {
            throw BLEError.notReady
        }
        let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
        var offset = 0
        while offset < data.count {
            let chunkEnd = min(offset + mtu, data.count)
            let chunk = data.subdata(in: offset..<chunkEnd)
            peripheral.writeValue(chunk, for: txChar, type: .withoutResponse)
            offset = chunkEnd
        }
    }

    enum BLEError: Error, LocalizedError {
        case notReady
        case serviceNotFound
        case characteristicNotFound
        case connectTimeout

        var errorDescription: String? {
            switch self {
            case .notReady: return "BLE not ready"
            case .serviceNotFound: return "CPAP service not found"
            case .characteristicNotFound: return "CPAP characteristic not found"
            case .connectTimeout: return "BLE connect timeout (device likely paired with another client)"
            }
        }
    }
}

extension BLEManager: CBCentralManagerDelegate {
    /// iOS calls this before `centralManagerDidUpdateState` when the
    /// app was relaunched by BLE state restoration. The dict contains
    /// the peripherals we were connected to at termination time, plus
    /// any outstanding scan options. We re-adopt the peripheral so
    /// subsequent notifications flow through our normal delegate path.
    ///
    /// Note: services/characteristics are NOT restored — we have to
    /// re-discover them. `didConnect` may or may not fire again
    /// depending on whether the peripheral is still connected at
    /// restore time. We rely on the existing didConnect /
    /// didDiscoverServices flow to re-establish the TX/RX chars.
    func centralManager(_ central: CBCentralManager,
                        willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey]
            as? [CBPeripheral] ?? []
        guard let p = restored.first else { return }
        self.peripheral = p
        p.delegate = self
        deviceName = p.name
        // Don't issue discoverServices here — CBCentralManager hasn't
        // transitioned to .poweredOn yet and any peripheral operation
        // raises "API MISUSE: can only accept this command while in the
        // powered on state". Recording the peripheral reference is all
        // we can safely do; centralManagerDidUpdateState will pick up
        // from here once the stack is ready.
        if p.state == .connecting {
            state = .connecting
        } else if p.state == .connected {
            state = .connected
        } else {
            state = .disconnected
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            isBluetoothReady = true
            if case .bluetoothOff = state { state = .disconnected }
            // If willRestoreState handed us a peripheral that was already
            // connected before the app relaunch, we deferred service
            // discovery until this point. Kick it off now.
            if let p = peripheral, p.state == .connected, txChar == nil {
                state = .connected
                p.discoverServices([Self.serviceUUID])
            }
        case .poweredOff, .unauthorized, .unsupported, .unknown, .resetting:
            isBluetoothReady = false
            state = .bluetoothOff
        @unknown default:
            isBluetoothReady = false
            state = .error("Unknown BT state")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? "Unknown"
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let device = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, peripheral: peripheral, advertisedServices: serviceUUIDs)
        if let idx = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            // Update with latest RSSI and services (may appear empty first, then populated)
            discoveredDevices[idx] = device
        } else {
            discoveredDevices.append(device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .connected
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        bleLog.error("didFailToConnect: \(peripheral.identifier) error=\(error?.localizedDescription ?? "nil", privacy: .public)")
        state = .error("Connect failed: \(error?.localizedDescription ?? "unknown")")
        readyContinuation?.resume(throwing: error ?? BLEError.notReady)
        readyContinuation = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        state = .disconnected
        txChar = nil
        rxChar = nil
        self.peripheral = nil
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            bleLog.error("didDiscoverServices: target service not found")
            state = .error("Service not found")
            readyContinuation?.resume(throwing: BLEError.serviceNotFound)
            readyContinuation = nil
            return
        }
        peripheral.discoverCharacteristics([Self.txCharUUID, Self.rxCharUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard service.uuid == Self.serviceUUID else { return }
        for char in service.characteristics ?? [] {
            if char.uuid == Self.txCharUUID { txChar = char }
            if char.uuid == Self.rxCharUUID {
                rxChar = char
                peripheral.setNotifyValue(true, for: char)
            }
        }
        if txChar != nil && rxChar != nil {
            state = .ready
            readyContinuation?.resume()
            readyContinuation = nil
        } else {
            bleLog.error("missing chars: tx=\(self.txChar != nil) rx=\(self.rxChar != nil)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            bleLog.error("setNotify failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            bleLog.error("didUpdateValue error: \(error.localizedDescription, privacy: .public)")
        }
        guard characteristic.uuid == Self.rxCharUUID, let value = characteristic.value else { return }
        onData?(value)
    }
}
