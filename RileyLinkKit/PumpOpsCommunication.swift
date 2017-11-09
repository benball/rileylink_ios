//
//  PumpOpsCommunication.swift
//  RileyLink
//
//  Created by Jaim Zuber on 3/2/17.
//  Copyright © 2017 Pete Schwamb. All rights reserved.
//

import Foundation
import MinimedKit
import RileyLinkBLEKit

private let standardPumpResponseWindow: UInt32 = 180

protocol PumpMessageSender {
    func writeCommand(_ command: Command, timeout: TimeInterval) throws -> Data

    func updateRegister(_ address: CC111XRegister, value: UInt8) throws

    func setBaseFrequency(_ frequency: Measurement<UnitFrequency>) throws

    func sendAndListen(_ msg: PumpMessage, timeoutMS: UInt32, repeatCount: UInt8, msBetweenPackets: UInt8, retryCount: UInt8) throws -> PumpMessage
}

extension CommandSession: PumpMessageSender { }

extension PumpMessageSender {
    /// - Throws:
    ///     - PumpCommsError.crosstalk
    ///     - PumpCommsError.noResponse
    ///     - PumpCommsError.peripheralError
    ///     - PumpCommsError.unknownResponse
    func sendAndListen(_ msg: PumpMessage, timeoutMS: UInt32 = standardPumpResponseWindow, retryCount: UInt8 = 3) throws -> PumpMessage {
        return try sendAndListen(msg, timeoutMS: timeoutMS, repeatCount: 0, msBetweenPackets: 0, retryCount: retryCount)
    }
}

extension PumpMessageSender {
    /// - Throws: PumpCommsError.peripheralError
    func send(_ msg: PumpMessage) throws {
        let command = SendPacket(
            outgoing: MinimedPacket(outgoingData: msg.txData).encodedData(),
            sendChannel: 0,
            repeatCount: 0,
            delayBetweenPacketsMS: 0
        )

        do {
            _ = try writeCommand(command, timeout: 0)
        } catch let error as LocalizedError {
            throw PumpCommsError.peripheralError(error)
        }
    }

    /// - Throws:
    ///     - PumpCommsError.crosstalk
    ///     - PumpCommsError.noResponse
    ///     - PumpCommsError.peripheralError
    ///     - PumpCommsError.unknownResponse
    func sendAndListen(_ msg: PumpMessage, timeoutMS: UInt32, repeatCount: UInt8, msBetweenPackets: UInt8, retryCount: UInt8) throws -> PumpMessage {
        let rfPacket = try sendAndListenForPacket(msg, timeoutMS: timeoutMS, repeatCount: repeatCount, msBetweenPackets: msBetweenPackets, retryCount: retryCount)

        guard let packet = MinimedPacket(encodedData: rfPacket.data) else {
            // TODO: Change error to better reflect that this is an encoding or CRC error
            throw PumpCommsError.unknownResponse(rx: rfPacket.data.hexadecimalString, during: msg)
        }

        guard let message = PumpMessage(rxData: packet.data) else {
            // Unknown packet type or message type
            throw PumpCommsError.unknownResponse(rx: packet.data.hexadecimalString, during: msg)
        }

        guard message.address == msg.address else {
            throw PumpCommsError.crosstalk(message, during: msg)
        }

        return message
    }

    /// - Throws:
    ///     - PumpCommsError.noResponse
    ///     - PumpCommsError.peripheralError
    func sendAndListenForPacket(_ msg: PumpMessage, timeoutMS: UInt32 = standardPumpResponseWindow, repeatCount: UInt8 = 0, msBetweenPackets: UInt8 = 0, retryCount: UInt8 = 3) throws -> RFPacket {
        let command = SendAndListen(
            outgoing: MinimedPacket(outgoingData: msg.txData).encodedData(),
            sendChannel: 0,
            repeatCount: repeatCount,
            delayBetweenPacketsMS: msBetweenPackets,
            listenChannel: 0,
            timeoutMS: timeoutMS,
            retryCount: retryCount
        )

        let minTimeBetweenPackets: TimeInterval = .milliseconds(12) // At least 12 ms between packets for radio to stop/start
        let timeBetweenPackets: TimeInterval = max(minTimeBetweenPackets, .milliseconds(Double(msBetweenPackets)))

        // 16384 = bitrate, 8 = bits per byte, 6/4 = 4b6 encoding
        let singlePacketSendTime: TimeInterval = (Double(msg.txData.count * 8) * 6 / 4 / 16_384.0)
        let totalRepeatSendTime = (singlePacketSendTime + timeBetweenPackets) * Double(repeatCount)
        let totalTimeout = (totalRepeatSendTime + .milliseconds(Double(timeoutMS))) * Double(retryCount + 1)

        guard let rfPacket = try writeCommandExpectingPacket(command, timeout: totalTimeout) else {
            throw PumpCommsError.noResponse(during: msg)
        }

        return rfPacket
    }

    /// - Throws: PumpCommsError.peripheralError
    func writeCommandExpectingPacket(_ command: Command, timeout: TimeInterval) throws -> RFPacket? {
        let response: Data

        do {
            response = try writeCommand(command, timeout: timeout)
        } catch let error as LocalizedError {
            throw PumpCommsError.peripheralError(error)
        }

        return RFPacket(rfspyResponse: response)

        // TODO: Record general RSSI values?
    }
}
