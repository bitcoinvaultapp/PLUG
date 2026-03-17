import Foundation
import CoreBluetooth
import Combine

// MARK: - Ledger BLE Manager
// CoreBluetooth scan/connect/disconnect state machine

enum LedgerState: Equatable {
    case disconnected
    case scanning
    case connecting
    case connected
    case error(String)
}

final class LedgerManager: NSObject, ObservableObject {

    static let shared = LedgerManager()

    // Ledger Nano X BLE UUIDs
    static let serviceUUID = CBUUID(string: "13D63400-2C97-0004-0000-4C6564676572")
    static let writeCharUUID = CBUUID(string: "13D63400-2C97-0004-0002-4C6564676572")
    static let notifyCharUUID = CBUUID(string: "13D63400-2C97-0004-0001-4C6564676572")

    @Published var state: LedgerState = .disconnected
    @Published var discoveredDevices: [CBPeripheral] = []
    @Published var connectedDevice: CBPeripheral?

    /// Cached app version from last getAppAndVersion call
    var cachedAppVersion: (name: String, version: String)?

    private var centralManager: CBCentralManager!
    private var writeContinuation: CheckedContinuation<Void, Never>?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    private var responseFrames: [Data] = []
    private var responseContinuation: CheckedContinuation<Data, Error>?
    private var expectedResponseLength: Int?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Scanning

    func startScan() {
        guard centralManager.state == .poweredOn else {
            state = .error("Bluetooth not available")
            return
        }
        discoveredDevices.removeAll()
        state = .scanning
        centralManager.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)

        // Stop scanning after 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.state == .scanning {
                self?.stopScan()
            }
        }
    }

    func stopScan() {
        centralManager.stopScan()
        if case .scanning = state {
            state = .disconnected
        }
    }

    // MARK: - Connection

    func connect(to peripheral: CBPeripheral) {
        stopScan()
        state = .connecting
        connectedDevice = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        if let device = connectedDevice {
            centralManager.cancelPeripheralConnection(device)
        }
        cleanup()
    }

    private func cleanup() {
        writeCharacteristic = nil
        notifyCharacteristic = nil
        connectedDevice = nil
        state = .disconnected
        cachedAppVersion = nil
    }

    // MARK: - Communication

    /// Sequence counter to discard stale responses from timed-out APDUs
    private var apduSequence: UInt = 0
    private var currentApduSequence: UInt = 0

    /// Send APDU and wait for response. Timeout is configurable for signing commands
    /// that require user confirmation on the Ledger screen.
    func sendAPDU(_ apdu: LedgerProtocol.APDU, timeout: TimeInterval = 30) async throws -> Data {
        guard state == .connected,
              let writeChar = writeCharacteristic,
              let peripheral = connectedDevice else {
            throw LedgerError.notConnected
        }

        // Frame APDU for BLE — always use Ledger's max frame size (156 bytes)
        // iOS may report MTU=512 but the Ledger Nano X BLE characteristic only handles ~155 bytes per write
        let encoded = apdu.encoded
        print("[Ledger] Sending APDU: CLA=\(String(format: "%02X", apdu.cla)) INS=\(String(format: "%02X", apdu.ins)) P1=\(String(format: "%02X", apdu.p1)) P2=\(String(format: "%02X", apdu.p2)) data=\(apdu.data.hex) (\(encoded.count) bytes)")
        let frames = LedgerProtocol.frameForBLE(encoded)
        print("[Ledger] Framed into \(frames.count) BLE packets")

        // Cancel any previous pending continuation
        if let prev = responseContinuation {
            prev.resume(throwing: LedgerError.timeout)
            responseContinuation = nil
        }

        // Reset ALL response state — prevents stale data from timed-out APDUs
        responseFrames.removeAll()
        expectedResponseLength = nil
        apduSequence += 1
        let mySequence = apduSequence

        // Write type: use withResponse since Ledger Nano X only supports .write (not .writeWithoutResponse)
        let writeType: CBCharacteristicWriteType = .withResponse

        return try await withCheckedThrowingContinuation { continuation in
            self.responseContinuation = continuation
            self.currentApduSequence = mySequence

            // Send frames with delays between them (non-blocking)
            let interFrameDelay = 0.05 // 50ms between BLE frames
            for (i, frame) in frames.enumerated() {
                let delay = Double(i) * interFrameDelay
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard self?.responseContinuation != nil else { return } // Already resolved
                    print("[Ledger] Sending frame \(i)/\(frames.count): \(frame.count) bytes")
                    peripheral.writeValue(frame, for: writeChar, type: writeType)
                    if i == frames.count - 1 {
                        print("[Ledger] All \(frames.count) frames sent")
                    }
                }
            }

            // Timeout — start AFTER all frames should be sent
            let frameDelay = Double(frames.count - 1) * interFrameDelay
            DispatchQueue.main.asyncAfter(deadline: .now() + frameDelay + timeout) { [weak self] in
                guard let self = self else { return }
                if self.responseContinuation != nil && self.currentApduSequence == mySequence {
                    print("[Ledger] Timeout — no response after \(Int(timeout))s")
                    self.responseContinuation?.resume(throwing: LedgerError.timeout)
                    self.responseContinuation = nil
                    self.responseFrames.removeAll()
                    self.expectedResponseLength = nil
                }
            }
        }
    }

    /// Get extended public key from Ledger (tries v2 protocol first, falls back to v1)
    func getXpub(path: [UInt32], display: Bool = false) async throws -> (xpub: String, publicKey: Data) {

        // Check which app is running on the Ledger
        do {
            let (appName, appVersion) = try await getAppAndVersion()
            print("[Ledger] App detected: \(appName) v\(appVersion)")

            // Must be "Bitcoin" or "Bitcoin Test" app
            let validApps = ["Bitcoin", "Bitcoin Test", "Bitcoin Test Legacy", "Bitcoin Legacy"]
            if !validApps.contains(appName) {
                throw LedgerError.wrongApp(appName)
            }
        } catch let error as LedgerError {
            if case .wrongApp = error {
                throw error
            }
            // getAppAndVersion itself might fail with wrongApp — that's fine, rethrow
            if case .statusError = error {
                print("[Ledger] Could not detect app (status error), will try commands directly")
            } else {
                print("[Ledger] Could not detect app: \(error), will try commands directly")
            }
        }

        // First: get xpub at m/84'/0'/0' (MAINNET path) WITHOUT display
        // The Ledger mainnet app only accepts coin_type=0 as standard with display=0
        // Path m/84'/1'/0' (testnet) is NOT standard for mainnet app → error with display=0
        let mainnetPath: [UInt32] = [84 | 0x80000000, 0 | 0x80000000, 0 | 0x80000000]
        var xpubNoDisplay: String?
        do {
            let noDisplayAPDU = LedgerV2.getExtendedPubkeyAPDU(path: mainnetPath, display: false)
            let noDisplayResp = try await sendAPDU(noDisplayAPDU)
            xpubNoDisplay = LedgerV2.parseExtendedPubkeyResponse(noDisplayResp)
            if let x = xpubNoDisplay {
                print("[Ledger] Got xpub without display: \(x.prefix(20))...")

                // Try GET_MASTER_FINGERPRINT (INS=0x05) — available on firmware >= 2.1.0
                do {
                    let realFP = try await getMasterFingerprint()
                    print("[Ledger] Real master fingerprint saved: \(realFP.hex)")
                } catch {
                    // Fallback: save parent fingerprint from xpub (wrong but best effort for old firmware)
                    print("[Ledger] GET_MASTER_FINGERPRINT failed (\(error)), falling back to parent fingerprint")
                    if let epk = ExtendedPublicKey.fromBase58(x) {
                        KeychainStore.shared.save(epk.fingerprint, forKey: KeychainStore.KeychainKey.ledgerMasterFingerprint.rawValue)
                        print("[Ledger] Parent fingerprint saved (fallback): \(epk.fingerprint.hex)")
                    }
                }
            }
        } catch {
            print("[Ledger] No-display xpub/fingerprint failed: \(error)")
        }

        // Always fetch master fingerprint — works on both Bitcoin and Bitcoin Test apps
        if KeychainStore.shared.load(forKey: KeychainStore.KeychainKey.ledgerMasterFingerprint.rawValue) == nil || xpubNoDisplay == nil {
            do {
                let realFP = try await getMasterFingerprint()
                print("[Ledger] Master fingerprint: \(realFP.hex)")
            } catch {
                print("[Ledger] GET_MASTER_FINGERPRINT failed: \(error)")
            }
        }

        // Save mainnet xpub for Ledger signing (not as wallet xpub)
        if let mainnetXpub = xpubNoDisplay {
            KeychainStore.shared.saveString(mainnetXpub, forKey: KeychainStore.KeychainKey.ledgerOriginalXpub.rawValue)
        }

        let isTestnet = NetworkConfig.shared.isTestnet

        // Try v2 protocol with requested path
        do {
            let xpubString = try await getXpubV2(path: path, display: display)
            guard let epk = ExtendedPublicKey.fromBase58(xpubString) else {
                throw LedgerError.invalidResponse
            }

            let coinType: UInt32 = xpubString.hasPrefix("tpub") ? 1 : 0

            // Save signing xpub if mainnet path wasn't available (Bitcoin Test app)
            if xpubNoDisplay == nil {
                KeychainStore.shared.saveString(xpubString, forKey: KeychainStore.KeychainKey.ledgerOriginalXpub.rawValue)
            }

            // Save coin_type and wallet xpub (overwrites if changed)
            KeychainStore.shared.saveString("\(coinType)", forKey: KeychainStore.KeychainKey.ledgerCoinType.rawValue)
            KeychainStore.shared.saveXpub(xpubString, isTestnet: isTestnet)

            return (xpubString, epk.key)
        } catch {
            print("[Ledger] v2 path failed: \(error)")
        }

        // Fallback: re-encode mainnet xpub as tpub for testnet (coin_type=0)
        if isTestnet, let mainnetXpub = xpubNoDisplay,
           let epk = ExtendedPublicKey.fromBase58(mainnetXpub) {
            let tpubString = epk.toBase58(isTestnet: true)
            KeychainStore.shared.saveString("0", forKey: KeychainStore.KeychainKey.ledgerCoinType.rawValue)
            KeychainStore.shared.saveXpub(tpubString, isTestnet: true)
            return (tpubString, epk.key)
        }

        // Try 4: v1 protocol as last resort
        do {
            let apdu = LedgerProtocol.getXpubAPDU(path: path, displayOnDevice: display)
            let response = try await sendAPDU(apdu)

            guard let parsed = LedgerProtocol.parseXpubResponse(response) else {
                throw LedgerError.invalidResponse
            }

            guard let compressedKey = LedgerProtocol.compressPublicKey(parsed.publicKey) else {
                throw LedgerError.invalidResponse
            }

            let fingerprint = Data([0x00, 0x00, 0x00, 0x00])
            let epk = ExtendedPublicKey(
                key: compressedKey,
                chainCode: parsed.chainCode,
                depth: UInt8(path.count),
                fingerprint: fingerprint,
                childIndex: path.last ?? 0
            )

            let result = epk.toBase58(isTestnet: isTestnet)
            KeychainStore.shared.saveXpub(result, isTestnet: isTestnet)
            return (result, compressedKey)
        } catch {
            print("[Ledger] v1 also failed: \(error)")
            throw LedgerError.invalidResponse
        }
    }

    // MARK: - V2 Protocol

    /// Get xpub using Ledger Bitcoin App v2 protocol (CLA=0xE1, INS=0x00)
    private func getXpubV2(path: [UInt32], display: Bool) async throws -> String {
        let apdu = LedgerV2.getExtendedPubkeyAPDU(path: path, display: display)
        print("[Ledger] Sending v2 GET_PUBKEY: CLA=E1 INS=00 path=\(path)")
        let response = try await sendAPDU(apdu)
        print("[Ledger] v2 response: \(response.count) bytes")

        guard let xpub = LedgerV2.parseExtendedPubkeyResponse(response) else {
            throw LedgerError.invalidResponse
        }

        return xpub
    }

    /// Get app name and version from Ledger (caches result)
    func getAppAndVersion() async throws -> (name: String, version: String) {
        if let cached = cachedAppVersion {
            print("[Ledger] Using cached app version: \(cached.name) v\(cached.version)")
            return cached
        }
        let apdu = LedgerV2.getAppAndVersionAPDU()
        let response = try await sendAPDU(apdu)
        guard let result = LedgerV2.parseAppAndVersion(response) else {
            throw LedgerError.invalidResponse
        }
        cachedAppVersion = result
        return result
    }

    /// Get master fingerprint via INS=0x05 (available on firmware >= 2.1.0)
    func getMasterFingerprint() async throws -> Data {
        let apdu = LedgerV2.getMasterFingerprintAPDU()
        print("[Ledger] Requesting master fingerprint (INS=0x05)...")
        let response = try await sendAPDU(apdu)
        guard response.count >= 4 else {
            throw LedgerError.invalidResponse
        }
        let fp = Data(response.prefix(4))
        print("[Ledger] Master fingerprint: \(fp.hex)")
        KeychainStore.shared.save(fp, forKey: KeychainStore.KeychainKey.ledgerMasterFingerprint.rawValue)
        return fp
    }

    // MARK: - Errors

    enum LedgerError: LocalizedError {
        case notConnected
        case timeout
        case invalidResponse
        case bleNotAvailable
        case userRejected
        case wrongApp(String)  // Bitcoin app not open
        case statusError(UInt16)  // Raw status word from device

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Ledger not connected"
            case .timeout: return "Communication timeout"
            case .invalidResponse: return "Invalid response from Ledger"
            case .bleNotAvailable: return "Bluetooth not available"
            case .userRejected: return "Rejected on Ledger"
            case .wrongApp(let current):
                if current.isEmpty {
                    return "Open the Bitcoin app on your Ledger"
                }
                return "Wrong app: \"\(current)\" — open the Bitcoin app on your Ledger"
            case .statusError(let sw):
                return "Ledger error: 0x\(String(format: "%04X", sw))"
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension LedgerManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            break
        case .poweredOff:
            state = .error("Bluetooth disabled")
        case .unauthorized:
            state = .error("Bluetooth not authorized")
        case .unsupported:
            state = .error("Bluetooth not supported")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if !discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredDevices.append(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[Ledger] BLE CONNECTED to \(peripheral.name ?? "unknown")")
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .error("Connection failed: \(error?.localizedDescription ?? "unknown")")
        cleanup()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[Ledger] BLE DISCONNECTED! error: \(error?.localizedDescription ?? "none")")
        cleanup()
    }
}

// MARK: - CBPeripheralDelegate

extension LedgerManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            if service.uuid == Self.serviceUUID {
                peripheral.discoverCharacteristics([Self.writeCharUUID, Self.notifyCharUUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }

        for char in characteristics {
            if char.uuid == Self.writeCharUUID {
                writeCharacteristic = char
                print("[Ledger] Write characteristic found — properties: \(char.properties.rawValue) (write=\(char.properties.contains(.write)), writeNoResp=\(char.properties.contains(.writeWithoutResponse)))")
            } else if char.uuid == Self.notifyCharUUID {
                notifyCharacteristic = char
                peripheral.setNotifyValue(true, for: char)
                print("[Ledger] Notify characteristic found — properties: \(char.properties.rawValue)")
            }
        }

        if writeCharacteristic != nil && notifyCharacteristic != nil {
            state = .connected
            print("[Ledger] BLE fully ready (write + notify characteristics found)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("[Ledger] BLE write error: \(error)")
        }
        // Resume write continuation if waiting
        if let cont = writeContinuation {
            writeContinuation = nil
            cont.resume()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("[Ledger] BLE notify error: \(error)")
        }
        guard characteristic.uuid == Self.notifyCharUUID,
              let data = characteristic.value else { return }

        print("[Ledger] Received frame: \(data.count) bytes - \(data.prefix(10).hex)...")
        responseFrames.append(data)

        // Check if we have enough data
        // First frame: tag(1) + seq(2) + length(2) + data = 5 byte header
        // The length field includes the status word (2 bytes)
        if responseFrames.count == 1 && data.count >= 5 {
            expectedResponseLength = Int(UInt16(data[3]) << 8 | UInt16(data[4]))
            print("[Ledger] Expecting \(expectedResponseLength!) bytes of APDU response")
        }

        // Check if response is complete
        if let expected = expectedResponseLength {
            // Calculate total data received (minus headers)
            var totalData = 0
            for (i, frame) in responseFrames.enumerated() {
                let headerSize = i == 0 ? 5 : 3
                totalData += frame.count - headerSize
            }
            print("[Ledger] Accumulated \(totalData)/\(expected) bytes")

            if totalData >= expected {
                let result = LedgerProtocol.reassembleBLEFrames(responseFrames)
                switch result {
                case .success(let payload):
                    responseContinuation?.resume(returning: payload)
                case .interrupted(let payload):
                    responseContinuation?.resume(returning: payload)
                case .error(let sw):
                    // 0x6Exx = CLA not supported, 0x6Dxx = INS not supported
                    // Both indicate wrong app or dashboard
                    if sw & 0xFF00 == 0x6E00 || sw & 0xFF00 == 0x6D00 {
                        responseContinuation?.resume(throwing: LedgerError.wrongApp(""))
                    } else if sw == 0x6985 {
                        responseContinuation?.resume(throwing: LedgerError.userRejected)
                    } else {
                        responseContinuation?.resume(throwing: LedgerError.statusError(sw))
                    }
                case .malformed:
                    responseContinuation?.resume(throwing: LedgerError.invalidResponse)
                }
                responseContinuation = nil
                responseFrames.removeAll()
                expectedResponseLength = nil
            }
        }
    }
}
