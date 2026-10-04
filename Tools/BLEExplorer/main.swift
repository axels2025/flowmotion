import CoreBluetooth
import Foundation

private struct Arguments {
    struct WriteRequest {
        let characteristicUUIDText: String
        let hexText: String
    }

    var targetName = "FM ONE - 2280"
    var serviceUUIDs = ["B11C0001-672A-8DAB-F442-A0DAB5063A98", "1812"]
    var scanSeconds: TimeInterval = 25
    var observeSeconds: TimeInterval = 180
    var verboseScan = false
    var writeCharacteristicUUIDText: String?
    var writeHexText: String?
    var writeRequests: [WriteRequest] = []
    var writeDelaySeconds: TimeInterval = 4
    var writeIntervalSeconds: TimeInterval = 10
    var continueOnWriteError = false
    var postWriteObserveSeconds: TimeInterval = 20

    init(_ arguments: [String]) {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--name" where index + 1 < arguments.count:
                targetName = arguments[index + 1]
                index += 2
            case "--service" where index + 1 < arguments.count:
                serviceUUIDs = [arguments[index + 1]]
                index += 2
            case "--scan-seconds" where index + 1 < arguments.count:
                scanSeconds = TimeInterval(arguments[index + 1]) ?? scanSeconds
                index += 2
            case "--observe-seconds" where index + 1 < arguments.count:
                observeSeconds = TimeInterval(arguments[index + 1]) ?? observeSeconds
                index += 2
            case "--verbose-scan":
                verboseScan = true
                index += 1
            case "--write" where index + 2 < arguments.count:
                writeCharacteristicUUIDText = arguments[index + 1]
                writeHexText = arguments[index + 2]
                writeRequests.append(WriteRequest(
                    characteristicUUIDText: arguments[index + 1],
                    hexText: arguments[index + 2]
                ))
                index += 3
            case "--write-characteristic" where index + 1 < arguments.count:
                writeCharacteristicUUIDText = arguments[index + 1]
                index += 2
            case "--write-hex" where index + 1 < arguments.count:
                writeHexText = arguments[index + 1]
                index += 2
            case "--write-delay" where index + 1 < arguments.count:
                writeDelaySeconds = TimeInterval(arguments[index + 1]) ?? writeDelaySeconds
                index += 2
            case "--write-interval" where index + 1 < arguments.count:
                writeIntervalSeconds = TimeInterval(arguments[index + 1]) ?? writeIntervalSeconds
                index += 2
            case "--continue-on-write-error":
                continueOnWriteError = true
                index += 1
            case "--post-write-observe-seconds" where index + 1 < arguments.count:
                postWriteObserveSeconds = TimeInterval(arguments[index + 1]) ?? postWriteObserveSeconds
                index += 2
            default:
                index += 1
            }
        }
    }

    var writeCharacteristicUUID: CBUUID? {
        guard let writeCharacteristicUUIDText else {
            return nil
        }
        return CBUUID(string: writeCharacteristicUUIDText)
    }

    var writeData: Data? {
        guard let writeHexText else {
            return nil
        }
        return Data(flowMotionHexString: writeHexText)
    }

    var plannedWrites: [(uuid: CBUUID, data: Data)] {
        var writes = writeRequests.compactMap { request -> (uuid: CBUUID, data: Data)? in
            guard let data = Data(flowMotionHexString: request.hexText) else {
                return nil
            }
            return (CBUUID(string: request.characteristicUUIDText), data)
        }

        if writes.isEmpty,
           let writeCharacteristicUUID,
           let writeData {
            writes.append((writeCharacteristicUUID, writeData))
        }

        return writes
    }
}

private final class BLEExplorer: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let arguments: Arguments
    private var central: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var serviceForCharacteristic: [CBUUID: CBUUID] = [:]
    private var notifyCharacteristicCount = 0
    private var discoveredCharacteristicCount = 0
    private var connectTimer: Timer?
    private var strongestCandidates: [String: Int] = [:]
    private var shouldExit = false
    private let hidServiceUUID = CBUUID(string: "1812")
    private var characteristicsByUUID: [CBUUID: CBCharacteristic] = [:]
    private var didScheduleWrite = false
    private var queuedWrites: [(uuid: CBUUID, data: Data)] = []
    private var nextWriteIndex = 0

    init(arguments: Arguments) {
        self.arguments = arguments
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("central state: \(stateDescription(central.state))")

        guard central.state == .poweredOn else {
            if central.state == .unauthorized || central.state == .unsupported || central.state == .poweredOff {
                exitLater(code: 2)
            }
            return
        }

        let serviceUUIDs = arguments.serviceUUIDs.map { CBUUID(string: $0) }
        for peripheral in central.retrieveConnectedPeripherals(withServices: serviceUUIDs) {
            let name = peripheral.name ?? peripheral.identifier.uuidString
            log("retrieveConnected candidate name='\(name)' id=\(peripheral.identifier.uuidString)")
            if name.localizedCaseInsensitiveContains(arguments.targetName) {
                log("matched already-connected target \(name); discovering")
                targetPeripheral = peripheral
                peripheral.delegate = self
                peripheral.discoverServices(nil)
                return
            }
        }

        log("scanning for name containing: \(arguments.targetName)")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )

        Timer.scheduledTimer(withTimeInterval: arguments.scanSeconds, repeats: false) { [weak self] _ in
            guard let self, self.targetPeripheral == nil else {
                return
            }
            self.log("scan timeout without finding \(self.arguments.targetName)")
            self.logCandidateSummary()
            self.central.stopScan()
            self.exitLater(code: 3)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? "(unnamed)"
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool
        let connectableText = connectable.map { $0 ? "yes" : "no" } ?? "unknown"
        let serviceText = serviceUUIDs.map(\.uuidString).joined(separator: ", ")
        let candidateKey = "\(name)|\(serviceText)|\(connectableText)"
        strongestCandidates[candidateKey] = max(strongestCandidates[candidateKey] ?? Int.min, RSSI.intValue)

        let matchesTargetName = name.localizedCaseInsensitiveContains(arguments.targetName)
        if arguments.verboseScan || matchesTargetName {
            log("discover name='\(name)' rssi=\(RSSI) connectable=\(connectableText) services=[\(serviceText)]")
        }

        guard matchesTargetName else {
            return
        }

        if connectable == false {
            log("matched target \(name), but this advertisement is not connectable; continuing scan")
            return
        }

        log("matched target \(name); connecting")
        targetPeripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral)
        connectTimer?.invalidate()
        connectTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            guard let self, let targetPeripheral = self.targetPeripheral else {
                return
            }
            self.log("connect timeout for \(targetPeripheral.name ?? targetPeripheral.identifier.uuidString)")
            self.central.cancelPeripheralConnection(targetPeripheral)
            self.exitLater(code: 7)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectTimer?.invalidate()
        connectTimer = nil
        log("connected: \(peripheral.name ?? peripheral.identifier.uuidString)")
        log("discovering all services")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectTimer?.invalidate()
        connectTimer = nil
        log("failed to connect: \(error?.localizedDescription ?? "unknown error")")
        exitLater(code: 4)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("disconnected: \(error?.localizedDescription ?? "no error")")
        if !shouldExit {
            exitLater(code: 5)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("service discovery error: \(error.localizedDescription)")
            exitLater(code: 6)
            return
        }

        let services = peripheral.services ?? []
        if services.isEmpty {
            log("no services discovered")
        }

        let hasHIDService = services.contains { $0.uuid == hidServiceUUID }
        if hasHIDService {
            log("HID probe: standard HID service 1812 is present")
        } else {
            log("HID probe: standard HID service 1812 was not discovered in this mode")
        }

        for service in services {
            log("service \(service.uuid.uuidString)\(knownServiceSuffix(for: service.uuid))")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log("characteristic discovery error for \(service.uuid.uuidString): \(error.localizedDescription)")
            return
        }

        let characteristics = service.characteristics ?? []
        if characteristics.isEmpty {
            log("service \(service.uuid.uuidString) has no characteristics")
        }

        for characteristic in characteristics {
            discoveredCharacteristicCount += 1
            serviceForCharacteristic[characteristic.uuid] = service.uuid
            characteristicsByUUID[characteristic.uuid] = characteristic

            let properties = propertiesDescription(characteristic.properties)
            log("characteristic service=\(service.uuid.uuidString)\(knownServiceSuffix(for: service.uuid)) uuid=\(characteristic.uuid.uuidString) properties=\(properties)")

            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }

            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                notifyCharacteristicCount += 1
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }

        log("discovered characteristics=\(discoveredCharacteristicCount) notifiable=\(notifyCharacteristicCount)")
        schedulePlannedWriteIfPossible(on: peripheral)

        Timer.scheduledTimer(withTimeInterval: arguments.observeSeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.log("observe timeout; exiting")
            self.shouldExit = true
            if let targetPeripheral = self.targetPeripheral {
                self.central.cancelPeripheralConnection(targetPeripheral)
            }
            self.exitLater(code: 0)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("notify state error char=\(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        log("notify \(characteristic.isNotifying ? "ON" : "OFF") char=\(characteristic.uuid.uuidString)")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("value error char=\(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }

        let serviceUUID = serviceForCharacteristic[characteristic.uuid]?.uuidString ?? "unknown"
        let data = characteristic.value ?? Data()
        let ascii = String(data: data, encoding: .utf8)?
            .filter { !$0.isNewline && $0 != "\t" }
            ?? ""
        log("value service=\(serviceUUID) char=\(characteristic.uuid.uuidString) len=\(data.count) hex=\(data.hexString) ascii='\(ascii)'")
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("write result char=\(characteristic.uuid.uuidString) error='\(error.localizedDescription)'")
        } else {
            log("write result char=\(characteristic.uuid.uuidString) ok")
        }

        nextWriteIndex += 1
        let code: Int32 = error == nil || arguments.continueOnWriteError ? 0 : 8
        scheduleNextWriteOrExit(on: peripheral, code: code)
    }

    private func schedulePlannedWriteIfPossible(on peripheral: CBPeripheral) {
        guard !didScheduleWrite,
              !arguments.plannedWrites.isEmpty else {
            return
        }

        for plannedWrite in arguments.plannedWrites {
            guard characteristicsByUUID[plannedWrite.uuid] != nil else {
                return
            }
        }

        queuedWrites = arguments.plannedWrites
        guard let firstWrite = queuedWrites.first,
              let characteristic = characteristicsByUUID[firstWrite.uuid] else {
            return
        }

        didScheduleWrite = true
        let properties = propertiesDescription(characteristic.properties)
        log("planned write sequence count=\(queuedWrites.count); first target char=\(characteristic.uuid.uuidString) properties=\(properties); writing in \(arguments.writeDelaySeconds)s")
        for (index, write) in queuedWrites.enumerated() {
            log("planned write #\(index + 1) char=\(write.uuid.uuidString) len=\(write.data.count) hex=\(write.data.hexString)")
        }

        Timer.scheduledTimer(withTimeInterval: arguments.writeDelaySeconds, repeats: false) { [weak self] _ in
            self?.performNextPlannedWrite(on: peripheral)
        }
    }

    private func performNextPlannedWrite(on peripheral: CBPeripheral) {
        guard nextWriteIndex < queuedWrites.count else {
            return
        }

        let write = queuedWrites[nextWriteIndex]
        guard let characteristic = characteristicsByUUID[write.uuid] else {
            log("planned write target disappeared char=\(write.uuid.uuidString)")
            exitLater(code: 9)
            return
        }

        let data = write.data
        let writeNumber = nextWriteIndex + 1
        if characteristic.properties.contains(.write) {
            log("writing #\(writeNumber)/\(queuedWrites.count) WITH response char=\(characteristic.uuid.uuidString) hex=\(data.hexString)")
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        } else if characteristic.properties.contains(.writeWithoutResponse) {
            log("writing #\(writeNumber)/\(queuedWrites.count) WITHOUT response char=\(characteristic.uuid.uuidString) hex=\(data.hexString)")
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            nextWriteIndex += 1
            scheduleNextWriteOrExit(on: peripheral, code: 0)
        } else {
            log("planned write target is not writable")
            exitLater(code: 9)
        }
    }

    private func scheduleNextWriteOrExit(on peripheral: CBPeripheral, code: Int32) {
        guard code == 0 else {
            schedulePostWriteExit(on: peripheral, code: code)
            return
        }

        if nextWriteIndex < queuedWrites.count {
            log("waiting \(arguments.writeIntervalSeconds)s before next write")
            Timer.scheduledTimer(withTimeInterval: arguments.writeIntervalSeconds, repeats: false) { [weak self] _ in
                self?.performNextPlannedWrite(on: peripheral)
            }
        } else {
            schedulePostWriteExit(on: peripheral, code: code)
        }
    }

    private func schedulePostWriteExit(on peripheral: CBPeripheral, code: Int32) {
        Timer.scheduledTimer(withTimeInterval: arguments.postWriteObserveSeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.log("post-write observe timeout; exiting")
            self.shouldExit = true
            self.central.cancelPeripheralConnection(peripheral)
            self.exitLater(code: code)
        }
    }

    private func exitLater(code: Int32) {
        shouldExit = true
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
            exit(code)
        }
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] \(message)")
        fflush(stdout)
    }

    private func logCandidateSummary() {
        let sortedCandidates = strongestCandidates
            .map { key, rssi in (key, rssi) }
            .sorted { left, right in left.1 > right.1 }
            .prefix(12)

        log("strongest scan candidates:")
        for (key, rssi) in sortedCandidates {
            let parts = key.split(separator: "|", omittingEmptySubsequences: false)
            let name = parts.indices.contains(0) ? String(parts[0]) : ""
            let services = parts.indices.contains(1) ? String(parts[1]) : ""
            let connectable = parts.indices.contains(2) ? String(parts[2]) : ""
            log("candidate name='\(name)' bestRSSI=\(rssi) connectable=\(connectable) services=[\(services)]")
        }
    }

    private func stateDescription(_ state: CBManagerState) -> String {
        switch state {
        case .unknown:
            return "unknown"
        case .resetting:
            return "resetting"
        case .unsupported:
            return "unsupported"
        case .unauthorized:
            return "unauthorized"
        case .poweredOff:
            return "poweredOff"
        case .poweredOn:
            return "poweredOn"
        @unknown default:
            return "unrecognized"
        }
    }

    private func propertiesDescription(_ properties: CBCharacteristicProperties) -> String {
        var names: [String] = []
        if properties.contains(.broadcast) { names.append("broadcast") }
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { names.append("authenticatedSignedWrites") }
        if properties.contains(.extendedProperties) { names.append("extendedProperties") }
        if properties.contains(.notifyEncryptionRequired) { names.append("notifyEncryptionRequired") }
        if properties.contains(.indicateEncryptionRequired) { names.append("indicateEncryptionRequired") }
        return names.isEmpty ? "none" : names.joined(separator: "|")
    }

    private func knownServiceSuffix(for uuid: CBUUID) -> String {
        switch uuid.uuidString.uppercased() {
        case "180A":
            return " (Device Information)"
        case "180F":
            return " (Battery)"
        case "1812":
            return " (Human Interface Device)"
        case "B11C0001-672A-8DAB-F442-A0DAB5063A98":
            return " (FlowMotion buttons)"
        case "B11C0100-672A-8DAB-F442-A0DAB5063A98":
            return " (FlowMotion private)"
        default:
            return ""
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    init?(flowMotionHexString string: String) {
        let cleaned = string
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        let parts = cleaned
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)

        let tokens: [String]
        if parts.count == 1, let first = parts.first, first.count > 2 {
            guard first.count.isMultiple(of: 2) else {
                return nil
            }
            tokens = stride(from: 0, to: first.count, by: 2).map { index in
                let start = first.index(first.startIndex, offsetBy: index)
                let end = first.index(start, offsetBy: 2)
                return String(first[start..<end])
            }
        } else {
            tokens = parts
        }

        var bytes: [UInt8] = []
        for token in tokens {
            guard let byte = UInt8(token, radix: 16) else {
                return nil
            }
            bytes.append(byte)
        }

        self.init(bytes)
    }
}

private let explorer = BLEExplorer(arguments: Arguments(CommandLine.arguments))
withExtendedLifetime(explorer) {
    RunLoop.main.run()
}
