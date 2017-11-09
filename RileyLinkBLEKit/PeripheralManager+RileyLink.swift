//
//  PeripheralManager+RileyLink.swift
//  xDripG5
//
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import CoreBluetooth


protocol CBUUIDRawValue: RawRepresentable {}
extension CBUUIDRawValue where RawValue == String {
    var cbUUID: CBUUID {
        return CBUUID(string: rawValue)
    }
}


enum RileyLinkServiceUUID: String, CBUUIDRawValue {
    case main = "0235733B-99C5-4197-B856-69219C2A3845"
}

enum MainServiceCharacteristicUUID: String, CBUUIDRawValue {
    case data            = "C842E849-5028-42E2-867C-016ADADA9155"
    case responseCount   = "6E6C7910-B89E-43A5-A0FE-50C5E2B81F4A"
    case customName      = "D93B2AF0-1E28-11E4-8C21-0800200C9A66"
    case timerTick       = "6E6C7910-B89E-43A5-78AF-50C5E2B86F7E"
    case firmwareVersion = "30D99DC9-7C91-4295-A051-0A104D238CF2"
}


extension PeripheralManager.Configuration {
    static var rileyLink: PeripheralManager.Configuration {
        return PeripheralManager.Configuration(
            serviceCharacteristics: [
                RileyLinkServiceUUID.main.cbUUID: [
                    MainServiceCharacteristicUUID.data.cbUUID,
                    MainServiceCharacteristicUUID.responseCount.cbUUID,
                    MainServiceCharacteristicUUID.customName.cbUUID,
                    MainServiceCharacteristicUUID.timerTick.cbUUID,
                    MainServiceCharacteristicUUID.firmwareVersion.cbUUID
                ]
            ],
            notifyingCharacteristics: [
                RileyLinkServiceUUID.main.cbUUID: [
                    MainServiceCharacteristicUUID.responseCount.cbUUID
                    // TODO: Should timer tick default to on?
                ]
            ],
            valueUpdateMacros: [
                // When the responseCount changes, the data characteristic should be read.
                MainServiceCharacteristicUUID.responseCount.cbUUID: { (manager: PeripheralManager) in
                    guard let dataCharacteristic = manager.peripheral.getCharacteristicWithUUID(.data)
                    else {
                        return
                    }

                    manager.peripheral.readValue(for: dataCharacteristic)
                }
            ]
        )
    }
}


fileprivate extension CBPeripheral {
    func getCharacteristicWithUUID(_ uuid: MainServiceCharacteristicUUID, serviceUUID: RileyLinkServiceUUID = .main) -> CBCharacteristic? {
        guard let service = services?.itemWithUUID(serviceUUID.cbUUID) else {
            return nil
        }

        return service.characteristics?.itemWithUUID(uuid.cbUUID)
    }
}


extension CBCentralManager {
    func scanForPeripherals(withOptions options: [String: Any]? = nil) {
        scanForPeripherals(withServices: [RileyLinkServiceUUID.main.cbUUID], options: options)
    }
}


extension PeripheralManager {
    static let expectedMaxBLELatency: TimeInterval = 1.5

    var timerTickEnabled: Bool {
        return peripheral.getCharacteristicWithUUID(.timerTick)?.isNotifying ?? false
    }

    func setTimerTickEnabled(_ enabled: Bool, timeout: TimeInterval = expectedMaxBLELatency, completion: ((_ error: PeripheralManagerError?) -> Void)? = nil) {
        perform { (manager) in
            do {
                guard let characteristic = manager.peripheral.getCharacteristicWithUUID(.timerTick) else {
                    throw PeripheralManagerError.unknownCharacteristic
                }

                try manager.setNotifyValue(enabled, for: characteristic, timeout: timeout)
                completion?(nil)
            } catch let error as PeripheralManagerError {
                completion?(error)
            } catch {
                assertionFailure()
            }
        }
    }

    func startIdleListening(idleTimeout: TimeInterval, channel: UInt8, timeout: TimeInterval = expectedMaxBLELatency, completion: @escaping (_ error: PeripheralManagerError?) -> Void) {
        perform { (manager) in
            let command = GetPacket(listenChannel: channel, timeoutMS: UInt32(clamping: Int(idleTimeout.milliseconds)))

            do {
                _ = try manager.writeCommand(command, timeout: timeout, responseType: .none)
                completion(nil)
            } catch let error as PeripheralManagerError {
                completion(error)
            } catch {
                assertionFailure()
            }
        }
    }

    func setCustomName(_ name: String, timeout: TimeInterval = expectedMaxBLELatency, completion: ((_ error: PeripheralManagerError?) -> Void)? = nil) {
        guard let value = name.data(using: .utf8) else {
            completion?(PeripheralManagerError.invalidInput(name))
            return
        }

        perform { (manager) in
            do {
                guard let characteristic = manager.peripheral.getCharacteristicWithUUID(.customName) else {
                    throw PeripheralManagerError.unknownCharacteristic
                }

                try manager.writeValue(value, for: characteristic, type: .withResponse, timeout: timeout)
                completion?(nil)
            } catch let error as PeripheralManagerError {
                completion?(error)
            } catch {
                assertionFailure()
            }
        }
    }
}


// MARK: - Synchronous commands
extension PeripheralManager {
    enum ResponseType {
        case single
        case buffered
        case none
    }

    func writeCommand(_ command: Command, timeout: TimeInterval, responseType: ResponseType) throws -> Data {
        guard let characteristic = peripheral.getCharacteristicWithUUID(.data) else {
            throw PeripheralManagerError.unknownCharacteristic
        }

        var value = command.data

        // Data commands are encoded with their length as the first byte
        guard value.count <= 220 else {
            throw PeripheralManagerError.writeSizeLimitExceeded(maxLength: 220)
        }

        value.insert(UInt8(value.count), at: 0)

        switch (command, responseType) {
        case (let command as RespondingCommand, .single):
            return try writeCommand(value,
                for: characteristic, timeout: timeout, awaitingUpdateWithMinimumLength: command.expectedResponseLength)
        case (let command as RespondingCommand, .buffered):
            return try writeCommand(value,
                for: characteristic,
                timeout: timeout,
                awaitingUpdateWithMinimumLength: command.expectedResponseLength,
                endOfResponseMarker: 0x00
            )
        default:
            try writeValue(value, for: characteristic, type: .withResponse, timeout: timeout)
            return Data()
        }
    }

    func readRadioFirmwareVersion(timeout: TimeInterval, responseType: ResponseType) throws -> String {
        let data = try writeCommand(GetVersion(), timeout: timeout, responseType: responseType)

        guard let version = String(bytes: data, encoding: .utf8) else {
            throw PeripheralManagerError.invalidResponse(data)
        }

        return version
    }

    func readBluetoothFirmwareVersion(timeout: TimeInterval) throws -> String {
        guard let characteristic = peripheral.getCharacteristicWithUUID(.firmwareVersion) else {
            throw PeripheralManagerError.unknownCharacteristic
        }

        guard let data = try readValue(for: characteristic, timeout: timeout) else {
            // TODO: This is an "unknown value" issue, not a timeout
            throw PeripheralManagerError.timeout
        }

        guard let version = String(bytes: data, encoding: .utf8) else {
            throw PeripheralManagerError.invalidResponse(data)
        }

        return version
    }
}


// MARK: - Lower-level helper operations
extension PeripheralManager {
    func writeCommand(_ value: Data,
        for characteristic: CBCharacteristic,
        type: CBCharacteristicWriteType = .withResponse,
        timeout: TimeInterval,
        awaitingUpdateWithMinimumLength minimumLength: Int) throws -> Data
    {
        try runCommand(timeout: timeout) {
            if case .withResponse = type {
                addCondition(.write(characteristic: characteristic))
            }

            if characteristic.isNotifying {
                addCondition(.valueUpdate(characteristic: characteristic, matching: { value in
                    // TODO: Look for RileyLinkResponseError. Ignore .commandInterrupted, but match .rxTimeout and .zeroData for quicker error handling?

                    guard let value = value, value.count >= minimumLength else {
                        return false
                    }

                    return true
                }))
            }

            peripheral.writeValue(value, for: characteristic, type: type)
        }

        guard let value = characteristic.value else {
            // TODO: This is an "unknown value" issue, not a timeout
            throw PeripheralManagerError.timeout
        }

        return value
    }

    func writeCommand(_ value: Data,
        for characteristic: CBCharacteristic,
        type: CBCharacteristicWriteType = .withResponse,
        timeout: TimeInterval,
        awaitingUpdateWithMinimumLength minimumLength: Int,
        endOfResponseMarker: UInt8) throws -> Data
    {
        var buffer = Data()

        try runCommand(timeout: timeout) {
            if case .withResponse = type {
                addCondition(.write(characteristic: characteristic))
            }

            addCondition(.valueUpdate(characteristic: characteristic, matching: { value in
                // TODO: Look for RileyLinkResponseError. Ignore .commandInterrupted, but match .rxTimeout and .zeroData for quicker error handling?

                guard let value = value, (buffer.count + value.count) >= minimumLength else {
                    return false
                }

                buffer.append(value)

                if let end = buffer.index(of: endOfResponseMarker) {
                    buffer = buffer.prefix(upTo: end)
                    return true
                } else {
                    return false
                }
            }))

            peripheral.writeValue(value, for: characteristic, type: type)
        }

        return buffer
    }
}
