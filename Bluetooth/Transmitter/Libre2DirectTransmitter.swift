//
//  Libre2DirectTransmitter.swift

import CoreBluetooth
import Foundation
import os.log
import UIKit

class Libre2DirectTransmitter: LibreTransmitterProxyProtocol {

    fileprivate lazy var logger = Logger(forType: Self.self)

    func reset() {
        rxBuffer.resetAllBytes()
    }

    class var manufacturerer: String {
        "Abbott"
    }

    class var smallImage: UIImage? {
        UIImage(named: "libresensor", in: Bundle.current, compatibleWith: nil)
    }

    class var shortTransmitterName: String {
        "libre2"
    }

    class var requiresDelayedReconnect: Bool {
        false
    }

    private let expectedBufferSize = 46
    static var requiresSetup = true
    static var requiresPhoneNFC: Bool = true

    static var writeCharacteristic: UUIDContainer? = "F001"// 0000f001-0000-1000-8000-00805f9b34fb"
    static var notifyCharacteristic: UUIDContainer? = "F002"// "0000f002-0000-1000-8000-00805f9b34fb"
    // static var serviceUUID: [UUIDContainer] = ["0000fde3-0000-1000-8000-00805f9b34fb"]
    static var serviceUUID: [UUIDContainer] = ["FDE3"]

    weak var delegate: LibreTransmitterDelegate?

    private var rxBuffer = Data()
    private var sensorData: SensorData?
    private var metadata: LibreTransmitterMetadata?

    class func canSupportPeripheral(_ peripheral: PeripheralProtocol) -> Bool {
        // name can be one of the following formats:
        // <description>: example
        //ABBOT<SerialNumber>: ABBOTT3MH015PCNC4
        // <MACADDRESS>: A4B7C9023F8D
        
        guard let name = peripheral.name else {
            return false
        }
        
        if name.lowercased().starts(with: "abbott") == true {
            print("Libre 2 detected using legacy name format as matcher")
            return true
        }
        
        print("Libre 2 detection using MAC address as matcher: \(UserDefaults.standard.preSelectedSensor?.macAddress?.lowercased()) vs \(name.lowercased())")
        if let sensor = UserDefaults.standard.preSelectedSensor, let macAddress = sensor.macAddress {
            return name.lowercased().contains(macAddress.lowercased())
        }
        
        
        return false
    }

    class func getDeviceDetailsFromAdvertisement(advertisementData: [String: Any]?) -> String? {
        nil
    }

    required init(delegate: LibreTransmitterDelegate, advertisementData: [String: Any]?) {
        self.delegate = delegate
        delegate.libreDeviceLogMessage(payload: "[LibreRU][BLE] stage=transmitter-created", type: .connection)
    }

    func requestData(writeCharacteristics: CBCharacteristic, peripheral: CBPeripheral) {
        // because of timing issues, we cannot use this method on libre2 eu sensors
    }

    func updateValueForNotifyCharacteristics(_ value: Data, peripheral: CBPeripheral, writeCharacteristic: CBCharacteristic?) {
        rxBuffer.append(value)

        logger.debug("[LibreRU][BLE] stage=notification fragmentBytes=\(value.count) accumulatedBytes=\(self.rxBuffer.count) expectedBytes=\(self.expectedBufferSize)")
        
        delegate?.libreDeviceLogMessage(payload: "libre2direct received value: \(value.toDebugString())", type: .receive)

        if rxBuffer.count == expectedBufferSize {
            delegate?.libreDeviceLogMessage(payload: "[LibreRU][BLE] stage=frame-assembled bytes=\(rxBuffer.count)", type: .receive)
            handleCompleteMessage()
        } else if rxBuffer.count > expectedBufferSize {
            logger.error("[LibreRU][BLE] stage=frame-assembled result=oversized bytes=\(self.rxBuffer.count) expectedBytes=\(self.expectedBufferSize)")
            delegate?.libreDeviceLogMessage(payload: "[LibreRU][BLE] stage=frame-assembled result=oversized bytes=\(rxBuffer.count) expectedBytes=\(expectedBufferSize)", type: .error)
            reset()
        }

    }

    func didDiscoverWriteCharacteristics(_ peripheral: CBPeripheral, writeCharacteristics: CBCharacteristic) {

        logger.info("[LibreRU][BLE] stage=write-characteristic-discovered peripheral=\(peripheral.name ?? "unknown", privacy: .public) characteristic=\(writeCharacteristics.uuid.uuidString, privacy: .public)")

        guard let unlock = unlock() else {
            logger.error("[LibreRU][BLE] stage=unlock-payload result=failed")
            delegate?.libreDeviceLogMessage(payload: "[LibreRU][BLE] stage=unlock-payload result=failed", type: .error)
            return
        }

        logger.info("[LibreRU][BLE] stage=unlock-write bytes=\(unlock.count) payload=\(unlock.hexEncodedString().uppercased(), privacy: .public)")
        
        delegate?.libreDeviceLogMessage(payload: "[LibreRU][BLE] stage=unlock-write bytes=\(unlock.count) payload=\(unlock.hexEncodedString().uppercased())", type: .send)
        peripheral.writeValue(unlock, for: writeCharacteristics, type: .withResponse)

    }

    func didDiscoverNotificationCharacteristic(_ peripheral: CBPeripheral, notifyCharacteristic: CBCharacteristic) {

        logger.info("[LibreRU][BLE] stage=notify-characteristic-discovered peripheral=\(peripheral.name ?? "unknown", privacy: .public) characteristic=\(notifyCharacteristic.uuid.uuidString, privacy: .public)")
        delegate?.libreDeviceLogMessage(payload: "[LibreRU][BLE] stage=notify-subscribe characteristic=\(notifyCharacteristic.uuid.uuidString)", type: .send)
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
    }

    private func unlock() -> Data? {

        guard var sensor = UserDefaults.standard.preSelectedSensor else {
            logger.error("[LibreRU][BLE] stage=unlock-payload result=missing-sensor")
            return nil
        }

        guard sensor.uuid.count == 8, sensor.patchInfo.count >= 6 else {
            logger.error("[LibreRU][BLE] stage=unlock-payload result=invalid-identity uidBytes=\(sensor.uuid.count) patchInfoBytes=\(sensor.patchInfo.count)")
            return nil
        }

        sensor.unlockCount +=  1

        UserDefaults.standard.preSelectedSensor = sensor

        let sensorTypeDescription = SensorType.diagnosticDescription(patchInfo: sensor.patchInfo)
        let unlockMessage = "[LibreRU][BLE] stage=unlock-payload" +
            " uid=\(sensor.uuid.hexEncodedString().uppercased())" +
            " patchInfo=\(sensor.patchInfo.hexEncodedString().uppercased())" +
            " sensorType=\(sensorTypeDescription) unlockCount=\(sensor.unlockCount)"
        logger.info("\(unlockMessage, privacy: .public)")

        let unlockPayload = Libre2.streamingUnlockPayload(sensorUID: sensor.uuid, info: sensor.patchInfo, enableTime: 42, unlockCount: UInt16(sensor.unlockCount))
        return Data(unlockPayload)

    }

    // previously captured trend values, limit to the last 20-ish minutes
    // we have some leniency here by having up to 30 data elements
    private var bufferedTrends =  LimitedQueue<Measurement>(limit: 30)
    private var lastSensorUUID : [UInt8]?
    func handleCompleteMessage() {
        guard rxBuffer.count >= expectedBufferSize else {
            logger.error("[LibreRU][BLE] stage=frame-validation result=short bytes=\(self.rxBuffer.count) expectedBytes=\(self.expectedBufferSize)")
            reset()
            return
        }

        guard let sensor = UserDefaults.standard.preSelectedSensor else {
            logger.error("[LibreRU][BLE] stage=frame-validation result=missing-sensor")
            reset()
            return
        }

        do {
            let decryptStartMessage = "[LibreRU][BLE] stage=decrypt result=started" +
                " encryptedBytes=\(self.rxBuffer.count)" +
                " uid=\(sensor.uuid.hexEncodedString().uppercased())" +
                " sensorType=\(SensorType.diagnosticDescription(patchInfo: sensor.patchInfo))"
            logger.info("\(decryptStartMessage, privacy: .public)")
            let decryptedBLE = Data(try Libre2.decryptBLE(id: [UInt8](sensor.uuid), data: [UInt8](rxBuffer)))
            var sensorUpdate = Libre2.parseBLEData(decryptedBLE)
            let decryptSuccessMessage = "[LibreRU][BLE] stage=decrypt result=success" +
                " decryptedBytes=\(decryptedBLE.count) age=\(sensorUpdate.age)" +
                " trendCount=\(sensorUpdate.trend.count) historyCount=\(sensorUpdate.history.count)" +
                " crcVerified=\(sensorUpdate.crcVerified)"
            logger.info("\(decryptSuccessMessage, privacy: .public)")
 

            guard sensorUpdate.crcVerified else {
                logger.error("[LibreRU][BLE] stage=crc result=failed")
                delegate?.libreDeviceLogMessage(payload: "[LibreRU][BLE] stage=crc result=failed", type: .error)
                delegate?.libreSensorDidUpdate(with: .checksumValidationError)
                reset()
                return
            }
            

            metadata = LibreTransmitterMetadata(hardware: nil, firmware: nil, battery: 100,
                                                name: Self.shortTransmitterName,
                                                macAddress: sensor.macAddress,
                                                patchInfo: sensor.patchInfo,
                                                uid: [UInt8](sensor.uuid))

            // When end user has changed sensor we cannot trust the current(new) calibrationdata
            // to apply for both old and new sensor.
            // Since we don't support multiple sets of calibration datas we chooce to remove
            // all buffered calibration data
            if let currentSensorUUID = metadata?.uid {
                if let lastSensorUUID,
                    lastSensorUUID != currentSensorUUID {
                    bufferedTrends.removeAll()

                }
                lastSensorUUID = currentSensorUUID
            }

            // todo: reset when sensor changes, but we currently don't need this
            // due to requirement of deleting cgmmanager when changing sensors
            if let latestGlucose = sensorUpdate.trend.last,
               let oldestGlucose = sensorUpdate.trend.first {
                // ensures captured trends are recent enough
                // but also older than the trends sent by sensor this time around
                let latestGlucoseDate = latestGlucose.date - TimeInterval(minutes: 20)
                let oldestGlucoseDate = oldestGlucose.date

                let filtered = bufferedTrends.array.filter {
                    $0.date > latestGlucoseDate &&
                    $0.date < oldestGlucoseDate
                }.removingDuplicates(byKey: { $0.idValue})

                // Could refactor this to be more performant, but decided not to
                // This is more explicit and easier to grasp than doing above and below
                // in one operation
                for trend in sensorUpdate.trend {
                    if !bufferedTrends.array.contains(where: { $0.date > trend.date}) {
                        bufferedTrends.enqueue(trend)
                    }

                }

                logger.debug("sensor updated with trends: \((sensorUpdate.trend.count)): \(sensorUpdate.trend)")

                if !filtered.isEmpty {
                    logger.debug("Adding previously captured trends \((filtered.count)): \(filtered)")
                    sensorUpdate.trend += filtered
                }
            }

            delegate?.libreSensorDidUpdate(with: sensorUpdate, and: metadata!)
            delegate?.libreDeviceLogMessage(payload: "[LibreRU][BLE] stage=reading-forwarded diagnosticMode=display-only age=\(sensorUpdate.age) trendCount=\(sensorUpdate.trend.count)", type: .receive)

        } catch {
            logger.error("[LibreRU][BLE] stage=decrypt result=failed error=\(error.localizedDescription, privacy: .public)")
            delegate?.libreDeviceLogMessage(payload: "[LibreRU][BLE] stage=decrypt result=failed error=\(error.localizedDescription)", type: .error)
        }

        reset()

    }

}
