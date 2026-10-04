import Combine
import CoreBluetooth
import Foundation

final class BLEGimbalController: NSObject, ObservableObject {
    static let suppliedServiceUUIDText = "B11C0001-672A-8DAB-F442-AODAB5O63A98"
    static let likelyServiceUUIDText = "B11C0001-672A-8DAB-F442-A0DAB5063A98"
    static let recordLEDCharacteristicUUIDText = "B11C0005-672A-8DAB-F442-A0DAB5063A98"
    static let buttonCharacteristicUUIDText = "B11C0007-672A-8DAB-F442-A0DAB5063A98"

    private static let serviceUUIDDefaultsKey = "flowmotion.serviceUUID"
    private static let deviceNameDefaultsKey = "flowmotion.deviceName"

    @Published var serviceUUIDText: String {
        didSet {
            UserDefaults.standard.set(serviceUUIDText, forKey: Self.serviceUUIDDefaultsKey)
        }
    }
    @Published var deviceNameText: String {
        didSet {
            UserDefaults.standard.set(deviceNameText, forKey: Self.deviceNameDefaultsKey)
        }
    }
    @Published private(set) var bluetoothState = "Bluetooth idle"
    @Published private(set) var connectionState = "Not connected"
    @Published private(set) var connectedDeviceName = "No gimbal"
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    @Published private(set) var lastPacketHex = "None"
    @Published private(set) var lastCharacteristicUUID = "None"
    @Published private(set) var lastButton = "None"
    @Published private(set) var recordLEDState = "Unknown"
    @Published private(set) var subscribedCharacteristicCount = 0
    @Published private(set) var lastGesture: GimbalButtonEvent?

    private var centralManager: CBCentralManager!
    private var targetServiceUUID: CBUUID?
    private let recordLEDCharacteristicUUID = CBUUID(string: BLEGimbalController.recordLEDCharacteristicUUIDText)
    private let buttonCharacteristicUUID = CBUUID(string: BLEGimbalController.buttonCharacteristicUUIDText)
    private var fallbackTargetName = "FM ONE"
    private var peripheral: CBPeripheral?
    private var recordLEDCharacteristic: CBCharacteristic?
    private let interpreter = ButtonInterpreter()

    override init() {
        serviceUUIDText = UserDefaults.standard.string(forKey: Self.serviceUUIDDefaultsKey)
            ?? Self.likelyServiceUUIDText
        deviceNameText = UserDefaults.standard.string(forKey: Self.deviceNameDefaultsKey)
            ?? "FM ONE"
        super.init()
        interpreter.onEvent = { [weak self] event in
            self?.lastGesture = event
        }
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    var uuidValidationMessage: String? {
        let trimmed = normalizedServiceUUIDText
        guard !trimmed.isEmpty else {
            return "Enter a service UUID."
        }

        if UUID(uuidString: trimmed) == nil {
            if trimmed.uppercased().contains("O") {
                return "The service UUID contains the letter O. BLE UUIDs only use 0-9 and A-F."
            }
            return "The service UUID is not a valid 128-bit UUID."
        }

        return nil
    }

    var suggestedZeroSubstitutionUUIDText: String? {
        let candidate = normalizedServiceUUIDText
            .uppercased()
            .replacingOccurrences(of: "O", with: "0")

        guard candidate != normalizedServiceUUIDText.uppercased(),
              UUID(uuidString: candidate) != nil else {
            return nil
        }

        return candidate
    }

    func useSuggestedZeroSubstitutionUUID() {
        guard let suggestedZeroSubstitutionUUIDText else {
            return
        }
        serviceUUIDText = suggestedZeroSubstitutionUUIDText
    }

    func scanAndConnect() {
        guard let serviceUUID = validatedServiceUUID else {
            connectionState = uuidValidationMessage ?? "Invalid service UUID"
            return
        }

        targetServiceUUID = serviceUUID
        fallbackTargetName = normalizedDeviceNameText

        guard centralManager.state == .poweredOn else {
            connectionState = "Waiting for Bluetooth"
            return
        }

        startScanning(for: serviceUUID)
    }

    func disconnect() {
        if isScanning {
            centralManager.stopScan()
            isScanning = false
        }

        if let peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }

        peripheral = nil
        recordLEDCharacteristic = nil
        isConnected = false
        subscribedCharacteristicCount = 0
        connectedDeviceName = "No gimbal"
        lastPacketHex = "None"
        lastCharacteristicUUID = "None"
        lastButton = "None"
        recordLEDState = "Unknown"
        connectionState = "Disconnected"
    }

    func setRecordLED(isOn: Bool) {
        let displayState = isOn ? "On" : "Off"

        guard let peripheral, let recordLEDCharacteristic else {
            recordLEDState = "\(displayState) pending"
            return
        }

        let data = Data([isOn ? 0x01 : 0x00])
        if recordLEDCharacteristic.properties.contains(.write) {
            peripheral.writeValue(data, for: recordLEDCharacteristic, type: .withResponse)
            recordLEDState = displayState
        } else if recordLEDCharacteristic.properties.contains(.writeWithoutResponse) {
            peripheral.writeValue(data, for: recordLEDCharacteristic, type: .withoutResponse)
            recordLEDState = displayState
        } else {
            recordLEDState = "Not writable"
        }
    }

    private var normalizedServiceUUIDText: String {
        serviceUUIDText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedDeviceNameText: String {
        let text = deviceNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "FM ONE" : text
    }

    private var validatedServiceUUID: CBUUID? {
        let text = normalizedServiceUUIDText
        guard UUID(uuidString: text) != nil else {
            return nil
        }
        return CBUUID(string: text)
    }

    private func startScanning(for serviceUUID: CBUUID) {
        if isScanning {
            centralManager.stopScan()
        }

        peripheral = nil
        recordLEDCharacteristic = nil
        isConnected = false
        subscribedCharacteristicCount = 0
        lastPacketHex = "None"
        lastCharacteristicUUID = "None"
        lastButton = "Waiting for button packets"
        recordLEDState = "Unknown"
        connectedDeviceName = "Scanning..."
        connectionState = "Scanning for FlowMotion service"
        isScanning = true

        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func handleButtonPacket(_ data: Data) {
        lastPacketHex = data.flowMotionHexString
        lastCharacteristicUUID = Self.buttonCharacteristicUUIDText

        guard let signal = BLEButtonPacketParser.parse(data) else {
            lastButton = "Unknown packet"
            return
        }

        switch signal {
        case .press(let button):
            lastButton = "\(button.title) \(button.advertisedHexCode)"
            interpreter.registerPress(button)
        case .release:
            lastButton = "Release"
            interpreter.registerRelease()
        }
    }
}

extension BLEGimbalController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .unknown:
            bluetoothState = "Bluetooth state unknown"
        case .resetting:
            bluetoothState = "Bluetooth resetting"
        case .unsupported:
            bluetoothState = "Bluetooth unsupported"
        case .unauthorized:
            bluetoothState = "Bluetooth permission needed"
        case .poweredOff:
            bluetoothState = "Bluetooth off"
        case .poweredOn:
            bluetoothState = "Bluetooth on"
            if let targetServiceUUID, !isConnected, !isScanning {
                startScanning(for: targetServiceUUID)
            }
        @unknown default:
            bluetoothState = "Bluetooth unavailable"
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "FlowMotion gimbal"
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let matchesService = targetServiceUUID.map { advertisedServices.contains($0) } ?? false
        let matchesName = name.localizedCaseInsensitiveContains(fallbackTargetName)

        guard matchesService || matchesName else {
            return
        }

        central.stopScan()
        isScanning = false
        self.peripheral = peripheral
        peripheral.delegate = self

        connectedDeviceName = name
        connectionState = "Connecting to \(name)"
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        connectionState = "Discovering services"

        if let targetServiceUUID {
            peripheral.discoverServices([targetServiceUUID])
        } else {
            peripheral.discoverServices(nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        connectionState = error?.localizedDescription ?? "Failed to connect"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        subscribedCharacteristicCount = 0
        recordLEDCharacteristic = nil
        lastButton = "None"
        recordLEDState = "Unknown"
        connectionState = error?.localizedDescription ?? "Disconnected"
        connectedDeviceName = "No gimbal"
    }
}

extension BLEGimbalController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            connectionState = "Service discovery failed: \(error.localizedDescription)"
            return
        }

        guard let services = peripheral.services, !services.isEmpty else {
            connectionState = "No services found"
            return
        }

        let matchingServices = services.filter { service in
            targetServiceUUID == nil || service.uuid == targetServiceUUID
        }

        guard !matchingServices.isEmpty else {
            connectionState = "Target service not found"
            return
        }

        for service in matchingServices {
            peripheral.discoverCharacteristics(nil, for: service)
        }

        connectionState = "Discovering characteristics"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            connectionState = "Characteristic discovery failed: \(error.localizedDescription)"
            return
        }

        guard let characteristics = service.characteristics else {
            connectionState = "No characteristics found"
            return
        }

        var notifyCount = 0
        var foundButtonCharacteristic = false
        var buttonCharacteristicCanNotify = false

        for characteristic in characteristics {
            let isButtonCharacteristic = characteristic.uuid == buttonCharacteristicUUID
            foundButtonCharacteristic = foundButtonCharacteristic || isButtonCharacteristic

            if characteristic.uuid == recordLEDCharacteristicUUID {
                recordLEDCharacteristic = characteristic
                recordLEDState = "Ready"
            }

            if isButtonCharacteristic,
               characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
                notifyCount += 1
                buttonCharacteristicCanNotify = buttonCharacteristicCanNotify || isButtonCharacteristic
            }
        }

        subscribedCharacteristicCount += notifyCount

        if foundButtonCharacteristic {
            connectionState = buttonCharacteristicCanNotify
                ? "Listening on B11C0007"
                : "Button characteristic is not notifiable"
        } else {
            connectionState = notifyCount > 0
                ? "Button characteristic B11C0007 not found"
                : "Connected, no notify characteristics"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            connectionState = "Read failed: \(error.localizedDescription)"
            return
        }

        guard let data = characteristic.value else {
            return
        }

        guard characteristic.uuid == buttonCharacteristicUUID else {
            return
        }

        handleButtonPacket(data)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            connectionState = "Notify failed: \(error.localizedDescription)"
            return
        }

        if characteristic.uuid == buttonCharacteristicUUID, characteristic.isNotifying {
            connectionState = "Listening on B11C0007"
        }
    }
}
