import Combine
import CoreBluetooth
import Foundation

struct CubeStatus {
    enum Park: UInt8 {
        case ready, waitingForData, needsPark
    }

    enum Clip: UInt8 {
        case closed, ready, playing
    }

    let park: Park
    let clip: Clip
    let result: UInt8
    let requestID: UInt8
    let password: String

    init?(_ data: Data) {
        let bytes = Array(data)
        guard bytes.count == 17, bytes[0] == 1,
              let park = Park(rawValue: bytes[1]), let clip = Clip(rawValue: bytes[2]) else {
            return nil
        }
        self.park = park
        self.clip = clip
        result = bytes[3]
        requestID = bytes[4]
        password = clip == .closed ? "" : String(decoding: bytes[5...16], as: UTF8.self)
    }
}

final class CubeRemote: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let serviceID = CBUUID(string: "1AD64E14-72BE-418D-8C36-08B4F2100F10")
    private static let commandID = CBUUID(string: "1AD64E14-72BE-418D-8C36-08B4F2100F11")
    private static let statusID = CBUUID(string: "1AD64E14-72BE-418D-8C36-08B4F2100F12")

    @Published private(set) var cubes: [CBPeripheral] = []
    @Published private(set) var status: CubeStatus?
    @Published private(set) var message = "Starting Bluetooth…"
    @Published private(set) var bluetoothReady = false
    @Published private(set) var scanning = false
    @Published private(set) var connecting = false
    @Published private(set) var busy = false

    private var central: CBCentralManager!
    private var cube: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var pendingRequest: UInt8?
    private var requestDeadline: Date?
    private var scanDeadline: Date?
    private var connectionDeadline: Date?
    private var readPending = false
    private var timer: Timer?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        timer?.invalidate()
    }

    func findCubes() {
        guard bluetoothReady, cube == nil, !scanning else { return }
        cubes.removeAll()
        message = "Looking for your Orbit Cube…"
        scanning = true
        scanDeadline = Date().addingTimeInterval(12)
        central.scanForPeripherals(withServices: [Self.serviceID])
    }

    func connect(_ peripheral: CBPeripheral) {
        guard bluetoothReady, cube == nil else { return }
        stopScan()
        cube = peripheral
        connecting = true
        connectionDeadline = Date().addingTimeInterval(55)
        message = "Connecting to the cube…"
        central.connect(peripheral, options: nil)
    }

    func disconnect() {
        if let cube {
            central.cancelPeripheralConnection(cube)
        }
        resetConnection("Disconnected.")
    }

    func setClip(open: Bool) {
        guard !busy, let cube, let commandCharacteristic, let status else { return }
        guard !open || status.park == .ready else { return }
        let id = status.requestID &+ 1
        pendingRequest = id
        requestDeadline = Date().addingTimeInterval(10)
        busy = true
        message = open ? "Opening Orbit Clip…" : "Closing Orbit Clip…"
        cube.writeValue(Data([open ? 1 : 2, id]), for: commandCharacteristic, type: .withResponse)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothReady = central.state == .poweredOn
        switch central.state {
        case .poweredOn:
            message = "Find your cube to connect."
        case .poweredOff:
            resetConnection("Turn on Bluetooth on your iPhone.")
        case .unauthorized:
            resetConnection("Allow Bluetooth for Orbit Cube in iPhone Settings.")
        case .unsupported:
            resetConnection("Bluetooth Low Energy is unavailable on this device.")
        case .resetting, .unknown:
            resetConnection("Waiting for Bluetooth…")
        @unknown default:
            resetConnection("Bluetooth is unavailable.")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning, !cubes.contains(where: { $0.identifier == peripheral.identifier }) else { return }
        cubes.append(peripheral)
        message = "Tap your cube to connect."
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard cube == peripheral else { return }
        message = "If asked, enter the six-digit Bluetooth PIN shown on the cube."
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard cube == peripheral else { return }
        resetConnection("Could not connect. Find your cube and try again.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard cube == peripheral else { return }
        resetConnection("Cube disconnected. Find it to reconnect.")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard cube == peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else {
            failConnection("Orbit Bluetooth service is unavailable. Check the cube firmware.")
            return
        }
        peripheral.discoverCharacteristics([Self.commandID, Self.statusID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard cube == peripheral else { return }
        guard error == nil,
              let command = service.characteristics?.first(where: { $0.uuid == Self.commandID }),
              let state = service.characteristics?.first(where: { $0.uuid == Self.statusID }) else {
            failConnection("This cube firmware does not support the Orbit remote.")
            return
        }
        commandCharacteristic = command
        statusCharacteristic = state
        readStatus()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard cube == peripheral, characteristic.uuid == Self.statusID else { return }
        readPending = false
        guard error == nil else {
            message = connecting ? "Enter the Bluetooth PIN shown on the cube." : "Waiting for cube status…"
            return
        }
        guard let data = characteristic.value, let next = CubeStatus(data) else {
            failConnection("The cube and app are using different versions of the Orbit protocol.")
            return
        }
        if connecting {
            connecting = false
            connectionDeadline = nil
            message = "Cube connected."
        }
        status = next
        if pendingRequest == next.requestID {
            finishRequest(clipMessage(for: next))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard cube == peripheral, characteristic.uuid == Self.commandID, busy else { return }
        if error != nil {
            finishRequest("The cube did not accept the command.")
        } else {
            readStatus()
        }
    }

    private func refresh() {
        let now = Date()
        if let scanDeadline, now >= scanDeadline {
            stopScan()
            if cubes.isEmpty {
                message = "No cube found. Power it on and try again nearby."
            }
        }
        if let connectionDeadline, now >= connectionDeadline {
            failConnection("Pairing timed out. Reconnect and enter the PIN shown on the cube.")
        }
        if let requestDeadline, now >= requestDeadline {
            finishRequest("No reply from the cube. Check its status and try again.")
        }
        readStatus()
    }

    private func readStatus() {
        guard !readPending, let cube, cube.state == .connected, let statusCharacteristic else { return }
        readPending = true
        cube.readValue(for: statusCharacteristic)
    }

    private func stopScan() {
        if scanning, central.state == .poweredOn {
            central.stopScan()
        }
        scanning = false
        scanDeadline = nil
    }

    private func failConnection(_ text: String) {
        if let cube {
            central.cancelPeripheralConnection(cube)
        }
        resetConnection(text)
    }

    private func resetConnection(_ text: String) {
        stopScan()
        cube = nil
        cubes.removeAll()
        status = nil
        commandCharacteristic = nil
        statusCharacteristic = nil
        connecting = false
        connectionDeadline = nil
        readPending = false
        finishRequest(text)
    }

    private func finishRequest(_ text: String) {
        pendingRequest = nil
        requestDeadline = nil
        busy = false
        message = text
    }

    private func clipMessage(for status: CubeStatus) -> String {
        switch status.result {
        case 0: return status.clip == .closed ? "Orbit Clip is closed." : "Orbit Clip is open."
        case 1: return "Wait for live Park and speed data from the Commander."
        case 2: return "Put the car in Park and stop before opening Clip."
        case 3: return "The cube ran out of memory while opening Clip."
        case 4: return "The display could not start Clip Wi-Fi."
        case 5: return "The cube could not start the Clip webpage."
        default: return "The cube could not open Clip."
        }
    }
}
