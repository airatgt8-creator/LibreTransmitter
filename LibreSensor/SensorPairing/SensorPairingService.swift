//
//  SensorPairingService.swift
//  LibreDirect
//
//  Created by Reimar Metzen on 06.07.21.
//

import Foundation
import Combine
import CoreNFC
import OSLog

public enum PairingError: Error {
    case noTagInfo
    case noSensorData
    case wrongSensorType
    case decryptionError
    case noPatchInfo
    case nfcNotSupported
}

extension PairingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noTagInfo:
            return LocalizedString("Could not get tag info", comment: "error description for PairingError.noTagInfo")
        case .noSensorData:
            return LocalizedString("Could not get sensor data", comment: "error description for PairingError.noSensorData")
        case .wrongSensorType:
            return LocalizedString("Wrong sensor type detected", comment: "error description for PairingError.wrongSensorType")
        case .decryptionError:
            return LocalizedString("Could not decrypt sensor contents", comment: "error description for PairingError.decryptionError")
        case .noPatchInfo:
            return LocalizedString("Could not get patch info", comment: "error description for PairingError.noPatchInfo")
        case .nfcNotSupported:
            return LocalizedString("Phone NFC not supported!", comment: "error description for PairingError.nfcNotSupported")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .nfcNotSupported:
            return LocalizedString("Your phone or app is not enabled for NFC communications, which is needed to pair to libre2 sensors", comment: "Recovery suggestion for PairingError.nfcNotSupported")
        default:
            return nil
        }
    }
}

public class SensorPairingService: NSObject, NFCTagReaderSessionDelegate, SensorPairingProtocol {
    private var session: NFCTagReaderSession?
    private var readingsSubject = PassthroughSubject<SensorPairingInfo, Never>()
    private var errorSubject  = PassthroughSubject<Error, Never>()

    private let nfcQueue = DispatchQueue(label: "libre-direct.nfc-queue")
    private let accessQueue = DispatchQueue(label: "libre-direct.nfc-access-queue")
    private let logger = Logger(forType: SensorPairingService.self)

    private let unlockCode: UInt32 = 42 // 42

    public var onCancel: (() -> Void)?

    public func pairSensor() throws {
        if !Features.phoneNFCAvailable {
            logger.error("[LibreRU][NFC] stage=availability result=unavailable")
            throw PairingError.nfcNotSupported
        }
        logger.info("[LibreRU][NFC] stage=session-requested phoneNFCAvailable=\(Features.phoneNFCAvailable)")

        if NFCTagReaderSession.readingAvailable {
            accessQueue.async {
                self.session = NFCTagReaderSession(pollingOption: .iso15693, delegate: self, queue: self.nfcQueue)
                self.session?.alertMessage = LocalizedString("Hold the top of your iPhone near the sensor to pair", comment: "")
                self.session?.begin()
            }
        }
    }

    public var publisher: AnyPublisher<SensorPairingInfo, Never> {
        readingsSubject.eraseToAnyPublisher()
    }
    
    public var errorPublisher: AnyPublisher<Error, Never> {
        errorSubject.eraseToAnyPublisher()
    }
    
    private func sendError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.errorSubject.send(error)
        }
    }

    private func sendUpdate(_ info: SensorPairingInfo) {
        DispatchQueue.main.async { [weak self] in
            self?.readingsSubject.send(info)
        }
    }

    public func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        logger.info("[LibreRU][NFC] stage=session-active")
    }

    public func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        logger.info("[LibreRU][NFC] stage=session-invalidated error=\(error.localizedDescription, privacy: .public)")
        if let error = error as? NFCReaderError, error.code != .readerSessionInvalidationErrorUserCanceled {
            session.invalidate(errorMessage: "Connection failure: \(error.localizedDescription)")
            self.sendError(error)
        }

        self.onCancel?()
    }

    public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        logger.info("[LibreRU][NFC] stage=tag-detected count=\(tags.count)")
        guard let firstTag = tags.first else {
            logger.error("[LibreRU][NFC] stage=tag-detected result=no-tags")
            return
        }
        guard case .iso15693(let tag) = firstTag else {
            logger.error("[LibreRU][NFC] stage=tag-detected result=unsupported-tag")
            return
        }

        session.connect(to: firstTag) { error in
            if let error {
                self.logger.error("[LibreRU][NFC] stage=connect result=failed error=\(error.localizedDescription, privacy: .public)")
                session.invalidate(errorMessage: PairingError.noTagInfo.localizedDescription)
                self.sendError(PairingError.noTagInfo)
                return
            }

            self.logger.info("[LibreRU][NFC] stage=connect result=success")

            tag.getSystemInfo(requestFlags: [.address, .highDataRate]) { result in
                switch result {
                case .failure(let error):
                    self.logger.error("[LibreRU][NFC] stage=system-info result=failed error=\(error.localizedDescription, privacy: .public)")
                    session.invalidate(errorMessage: PairingError.noTagInfo.localizedDescription)
                    self.sendError(PairingError.noTagInfo)
                    return
                case .success:
                    self.logger.info("[LibreRU][NFC] stage=system-info result=success")
                    tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA1, customRequestParameters: Data()) { response, error in
                        if let error {
                            self.logger.error("[LibreRU][NFC] stage=patch-info result=failed error=\(error.localizedDescription, privacy: .public)")
                            session.invalidate(errorMessage: PairingError.noPatchInfo.localizedDescription)
                            self.sendError(PairingError.noPatchInfo)
                            return
                        }

                        let sensorUID = Data(tag.identifier.reversed())
                        let patchInfo = response
                        let patchHex = patchInfo.hexEncodedString().uppercased()
                        let uidHex = sensorUID.hexEncodedString().uppercased()
                        let sensorTypeDescription = SensorType.diagnosticDescription(patchInfo: patchInfo)

                        let identityMessage = "[LibreRU][NFC] stage=patch-info result=success" +
                            " uid=\(uidHex) uidBytes=\(sensorUID.count)" +
                            " patchInfo=\(patchHex) patchInfoBytes=\(patchInfo.count)" +
                            " sensorType=\(sensorTypeDescription)"
                        self.logger.info("\(identityMessage, privacy: .public)")

                        // The crypto helpers index bytes 4 and 5. Reject short responses before
                        // constructing either the NFC enable command or the later BLE unlock.
                        guard sensorUID.count == 8, patchInfo.count >= 6 else {
                            self.logger.error("[LibreRU][NFC] stage=identity-validation result=failed uidBytes=\(sensorUID.count) patchInfoBytes=\(patchInfo.count)")
                            session.invalidate(errorMessage: PairingError.noPatchInfo.localizedDescription)
                            self.sendError(PairingError.noPatchInfo)
                            return
                        }

                        // Core NFC operations must be serialized. The previous implementation
                        // launched all 15 reads at once and assembled FRAM when the final request
                        // happened to return, which could produce an incomplete frame.
                        self.readFRAMSequentially(tag: tag) { result in
                            switch result {
                            case .failure(let error):
                                let nsError = error as NSError
                                self.logger.error("[LibreRU][NFC] stage=fram-read result=failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code) errorUserInfo=\(String(describing: nsError.userInfo), privacy: .public)")
                                session.invalidate(errorMessage: PairingError.noSensorData.localizedDescription)
                                self.sendError(PairingError.noSensorData)
                            case .success(let fram):
                                self.logger.info("[LibreRU][NFC] stage=fram-read result=success bytes=\(fram.count)")
                                self.enableStreamingAndFinish(
                                    tag: tag,
                                    session: session,
                                    sensorUID: sensorUID,
                                    patchInfo: patchInfo,
                                    fram: fram
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func readFRAMSequentially(
        tag: NFCISO15693Tag,
        nextBlock: Int = 0,
        blockCount: Int = 43,
        requestBlockCount: Int = 3,
        buffer: Data = Data(),
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard nextBlock < blockCount else {
            completion(.success(buffer))
            return
        }

        let lastBlock = min(nextBlock + requestBlockCount - 1, blockCount - 1)
        logger.debug("[LibreRU][NFC] stage=fram-read requestBlocks=\(nextBlock)-\(lastBlock) accumulatedBytes=\(buffer.count)")

        tag.readMultipleBlocks(
            requestFlags: [.highDataRate, .address],
            blockRange: NSRange(UInt8(nextBlock) ... UInt8(lastBlock))
        ) { blockArray, error in
            if let error {
                let nsError = error as NSError
                self.logger.error("[LibreRU][NFC] stage=fram-read mode=multi-block result=failed blockRange=\(nextBlock)-\(lastBlock) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code) errorUserInfo=\(String(describing: nsError.userInfo), privacy: .public)")
                self.logger.info("[LibreRU][NFC] stage=fram-read fallback=single-block blockRange=0-\(blockCount - 1)")
                self.readFRAMSingleBlocksSequentially(
                    tag: tag,
                    blockCount: blockCount,
                    completion: completion
                )
                return
            }

            let expectedBlocks = lastBlock - nextBlock + 1
            guard blockArray.count == expectedBlocks else {
                completion(.failure(PairingStageError.unexpectedBlockCount(expected: expectedBlocks, actual: blockArray.count)))
                return
            }

            var nextBuffer = buffer
            blockArray.forEach { nextBuffer.append($0) }
            self.readFRAMSequentially(
                tag: tag,
                nextBlock: lastBlock + 1,
                blockCount: blockCount,
                requestBlockCount: requestBlockCount,
                buffer: nextBuffer,
                completion: completion
            )
        }
    }

    private func readFRAMSingleBlocksSequentially(
        tag: NFCISO15693Tag,
        nextBlock: Int = 0,
        blockCount: Int = 43,
        buffer: Data = Data(),
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard nextBlock < blockCount else {
            logger.info("[LibreRU][NFC] stage=fram-read mode=single-block result=success bytes=\(buffer.count)")
            completion(.success(buffer))
            return
        }

        tag.readSingleBlock(
            requestFlags: .highDataRate,
            blockNumber: UInt8(nextBlock)
        ) { block, error in
            if let error {
                let nsError = error as NSError
                self.logger.error("[LibreRU][NFC] stage=fram-read mode=single-block result=failed block=\(nextBlock) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code) errorUserInfo=\(String(describing: nsError.userInfo), privacy: .public)")
                completion(.failure(error))
                return
            }

            var nextBuffer = buffer
            nextBuffer.append(block)
            self.readFRAMSingleBlocksSequentially(
                tag: tag,
                nextBlock: nextBlock + 1,
                blockCount: blockCount,
                buffer: nextBuffer,
                completion: completion
            )
        }
    }

    private func enableStreamingAndFinish(
        tag: NFCISO15693Tag,
        session: NFCTagReaderSession,
        sensorUID: Data,
        patchInfo: Data,
        fram: Data
    ) {
        let sensorType = SensorType(patchInfo: patchInfo)
        let sensorTypeDescription = SensorType.diagnosticDescription(patchInfo: patchInfo)

        guard sensorUID.count == 8, patchInfo.count >= 6, fram.count == 344 else {
            logger.error("[LibreRU][NFC] stage=payload-validation result=failed uidBytes=\(sensorUID.count) patchInfoBytes=\(patchInfo.count) framBytes=\(fram.count)")
            session.invalidate(errorMessage: PairingError.noSensorData.localizedDescription)
            sendError(PairingError.noSensorData)
            return
        }

        guard sensorType == .libre2 else {
            logger.error("[LibreRU][NFC] stage=sensor-type-validation result=unsupported sensorType=\(sensorTypeDescription, privacy: .public)")
            session.invalidate(errorMessage: PairingError.wrongSensorType.localizedDescription)
            sendError(PairingError.wrongSensorType)
            return
        }

        let subCommand: Subcommand = .enableStreaming
        let command = nfcCommand(subCommand, unlockCode: unlockCode, patchInfo: patchInfo, sensorUID: sensorUID)
        logger.info("[LibreRU][NFC] stage=enable-streaming requestCode=0x\(String(format: "%02X", command.code), privacy: .public) parameters=\(command.parameters.hexEncodedString().uppercased(), privacy: .public)")

        tag.customCommand(
            requestFlags: .highDataRate,
            customCommandCode: Int(command.code),
            customRequestParameters: command.parameters
        ) { response, error in
            if let error {
                self.logger.error("[LibreRU][NFC] stage=enable-streaming result=failed responseBytes=\(response.count) error=\(error.localizedDescription, privacy: .public)")
            } else {
                self.logger.info("[LibreRU][NFC] stage=enable-streaming result=response responseBytes=\(response.count) response=\(response.hexEncodedString().uppercased(), privacy: .public)")
            }

            let streamingEnabled = error == nil && response.count == 6
            let macAddress = streamingEnabled ? Data(response.reversed()).hexEncodedString().uppercased() : nil

            guard streamingEnabled else {
                self.logger.error("[LibreRU][NFC] stage=enable-streaming result=invalid-response expectedBytes=6 actualBytes=\(response.count)")
                session.invalidate(errorMessage: PairingError.noSensorData.localizedDescription)
                self.sendError(PairingError.noSensorData)
                return
            }

            do {
                self.logger.info("[LibreRU][NFC] stage=fram-decrypt result=started sensorType=\(sensorTypeDescription, privacy: .public)")
                let decryptedBytes = try Libre2.decryptFRAM(
                    type: sensorType,
                    id: [UInt8](sensorUID),
                    info: patchInfo,
                    data: [UInt8](fram)
                )
                self.logger.info("[LibreRU][NFC] stage=fram-decrypt result=success decryptedBytes=\(decryptedBytes.count) macAddress=\(macAddress ?? "none", privacy: .public)")
                self.sendUpdate(SensorPairingInfo(
                    uuid: sensorUID,
                    patchInfo: patchInfo,
                    fram: Data(decryptedBytes),
                    streamingEnabled: true,
                    macAddress: macAddress
                ))
                session.invalidate()
            } catch {
                self.logger.error("[LibreRU][NFC] stage=fram-decrypt result=failed error=\(error.localizedDescription, privacy: .public)")
                session.invalidate(errorMessage: PairingError.decryptionError.localizedDescription)
                self.sendError(PairingError.decryptionError)
            }
        }
    }

    private func readRaw(_ address: UInt16, _ bytes: Int, buffer: Data = Data(), tag: NFCISO15693Tag, handler: @escaping (UInt16, Data, Error?) -> Void) {
        
        var buffer = buffer
        let addressToRead = address + UInt16(buffer.count)

        var remainingBytes = bytes
        let bytesToRead = remainingBytes > 24 ? 24 : bytes

        var remainingWords = bytes / 2
        if bytes % 2 == 1 || (bytes % 2 == 0 && addressToRead % 2 == 1) { remainingWords += 1 }
        let wordsToRead = UInt8(remainingWords > 12 ? 12 : remainingWords) // real limit is 15

        // this is for libre 2 only, ignoring other libre types
        let readRawCommand = NFCCommand(code: 0xB3, parameters: Data([UInt8(addressToRead & 0x00FF), UInt8(addressToRead >> 8), wordsToRead]))

        tag.customCommand(requestFlags: .highDataRate, customCommandCode: Int(readRawCommand.code), customRequestParameters: readRawCommand.parameters) { response, error in
            var data = response

            if error != nil {
                remainingBytes = 0
            } else {
                if addressToRead % 2 == 1 { data = data.subdata(in: 1 ..< data.count) }
                if data.count - Int(bytesToRead) == 1 { data = data.subdata(in: 0 ..< data.count - 1) }
            }

            buffer += data
            remainingBytes -= data.count

            if remainingBytes == 0 {
                handler(address, buffer, error)
            } else {
                self.readRaw(address, remainingBytes, buffer: buffer, tag: tag) { address, data, error in handler(address, data, error) }
            }
        }
    }

    private func writeRaw(_ address: UInt16, _ data: Data, tag: NFCISO15693Tag, handler: @escaping (UInt16, Data, Error?) -> Void) {
        let backdoor = "deadbeef".utf8

        tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA4, customRequestParameters: Data(backdoor)) {
            _, error in

            let addressToRead = (address / 8) * 8
            let startOffset = Int(address % 8)
            let endAddressToRead = ((Int(address) + data.count - 1) / 8) * 8 + 7
            let blocksToRead = (endAddressToRead - Int(addressToRead)) / 8 + 1

            self.readRaw(addressToRead, blocksToRead * 8, tag: tag) { _, readData, error in
                if error != nil {
                    handler(address, data, error)
                    return
                }

                var bytesToWrite = readData
                bytesToWrite.replaceSubrange(startOffset ..< startOffset + data.count, with: data)

                let startBlock = Int(addressToRead / 8)
                let blocks = bytesToWrite.count / 8

                if address < 0xF860 { // lower than FRAM blocks
                    for i in 0 ..< blocks {
                        let blockToWrite = bytesToWrite[i * 8 ... i * 8 + 7]

                        // FIXME: doesn't work as the custom commands C1 or A5 for other chips
                        tag.extendedWriteSingleBlock(requestFlags: .highDataRate, blockNumber: startBlock + i, dataBlock: blockToWrite) { error in
                            if error != nil {
                                if i != blocks - 1 { return }
                            }

                            if i == blocks - 1 {
                                tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA2, customRequestParameters: Data(backdoor)) { _, error in
                                    handler(address, data, error)
                                }
                            }
                        }
                    }

                } else { // address >= 0xF860: write to FRAM blocks
                    let requestBlocks = 2 // 3 doesn't work
                    let requests = Int(ceil(Double(blocks) / Double(requestBlocks)))
                    let remainder = blocks % requestBlocks
                    var blocksToWrite = [Data](repeating: Data(), count: blocks)

                    for i in 0 ..< blocks {
                        blocksToWrite[i] = Data(bytesToWrite[i * 8 ... i * 8 + 7])
                    }

                    for i in 0 ..< requests {
                        let startIndex = startBlock - 0xF860 / 8 + i * requestBlocks
                        let endIndex = startIndex + (i == requests - 1 ? (remainder == 0 ? requestBlocks : remainder) : requestBlocks) - (requestBlocks > 1 ? 1 : 0)
                        let blockRange = NSRange(UInt8(startIndex) ... UInt8(endIndex))

                        var dataBlocks = [Data]()
                        for j in startIndex ... endIndex { dataBlocks.append(blocksToWrite[j - startIndex]) }

                        // TODO: write to 16-bit addresses as the custom cummand C4 for other chips
                        tag.writeMultipleBlocks(requestFlags: [.highDataRate, .address], blockRange: blockRange, dataBlocks: dataBlocks) { error in // TEST
                            if error != nil {
                                if i != requests - 1 { return }
                            }

                            if i == requests - 1 {
                                // Lock
                                tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA2, customRequestParameters: Data(backdoor)) {
                                    _, error in

                                    handler(address, data, error)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func nfcCommand(_ code: Subcommand, unlockCode: UInt32, patchInfo: Data, sensorUID: Data) -> NFCCommand {
        var b: [UInt8] = []
        var y: UInt16

        if code == .enableStreaming {
            // Enables Bluetooth on Libre 2. Returns peripheral MAC address to connect to.
            // unlockCode could be any 32 bit value. The unlockCode and sensor Uid / patchInfo
            // will have also to be provided to the login function when connecting to peripheral.
            b = [UInt8(unlockCode & 0xFF), UInt8((unlockCode >> 8) & 0xFF), UInt8((unlockCode >> 16) & 0xFF), UInt8((unlockCode >> 24) & 0xFF)]
            y = UInt16(patchInfo[4...5]) ^ UInt16(b[1], b[0])
        } else {
            y = 0x1b6a
        }

        let d = Libre2.usefulFunction(id: [UInt8](sensorUID), x: UInt16(code.rawValue), y: y)

        var parameters = Data([code.rawValue])

        if code == .enableStreaming {
            parameters += b
        }

        parameters += d

        return NFCCommand(code: 0xA1, parameters: parameters)
    }
}

extension UInt16 {
    init(_ high: UInt8, _ low: UInt8) {
        self = UInt16(high) << 8 + UInt16(low)
    }

    init(_ data: Data) {
        self = UInt16(data[data.startIndex + 1]) << 8 + UInt16(data[data.startIndex])
    }
}

private struct NFCCommand {
    let code: UInt8
    let parameters: Data
}

private enum PairingStageError: LocalizedError {
    case unexpectedBlockCount(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .unexpectedBlockCount(let expected, let actual):
            return "Expected \(expected) NFC blocks but received \(actual)"
        }
    }
}

private enum Subcommand: UInt8, CustomStringConvertible {
    case activate = 0x1b
    case enableStreaming = 0x1e
    case unknown0x1a = 0x1a
    case unknown0x1c = 0x1c
    case unknown0x1d = 0x1d
    case unknown0x1f = 0x1f

    var description: String {
        switch self {
        case .activate: return "activate"
        case .enableStreaming: return "enable BLE streaming"
        default: return "[unknown: 0x\(String(format: "%x", rawValue))]"
        }
    }
}
