import Foundation

// MARK: - Ledger APDU Protocol
// APDU encoding, BLE framing, and response parsing

struct LedgerProtocol {

    // MARK: - APDU structure

    struct APDU {
        let cla: UInt8
        let ins: UInt8
        let p1: UInt8
        let p2: UInt8
        let data: Data

        var encoded: Data {
            var apdu = Data()
            apdu.append(cla)
            apdu.append(ins)
            apdu.append(p1)
            apdu.append(p2)
            // Always include Lc byte — Ledger Bitcoin app requires it even when 0
            apdu.append(UInt8(data.count))
            if !data.isEmpty {
                apdu.append(data)
            }
            return apdu
        }
    }

    // MARK: - Bitcoin app commands

    enum BitcoinCommand: UInt8 {
        case getWalletPublicKey = 0x40
        case signTransaction = 0x04
        case getAppVersion = 0x01
    }

    static let bitcoinCLA: UInt8 = 0xE0

    /// Build APDU to get extended public key for a derivation path
    /// Path format: "m/84'/0'/0'" -> [0x80000054, 0x80000000, 0x80000000]
    static func getXpubAPDU(path: [UInt32], displayOnDevice: Bool = false) -> APDU {
        var data = Data()

        // Number of path components
        data.append(UInt8(path.count))

        // Each component as 4 bytes big-endian
        for component in path {
            var be = component.bigEndian
            data.append(Data(bytes: &be, count: 4))
        }

        return APDU(
            cla: bitcoinCLA,
            ins: BitcoinCommand.getWalletPublicKey.rawValue,
            p1: displayOnDevice ? 0x01 : 0x00,
            p2: 0x02, // Native SegWit (bech32)
            data: data
        )
    }

    /// Parse xpub response from Ledger
    /// Response format: pubkey_length(1) + pubkey(65) + address_length(1) + address(var) + chaincode(32)
    static func parseXpubResponse(_ data: Data) -> (publicKey: Data, chainCode: Data, address: String)? {
        guard data.count >= 2 else { return nil }

        var offset = 0

        // Public key
        let pubkeyLen = Int(data[offset])
        offset += 1
        guard offset + pubkeyLen <= data.count else { return nil }
        let pubkey = Data(data[offset..<(offset + pubkeyLen)])
        offset += pubkeyLen

        // Address
        let addrLen = Int(data[offset])
        offset += 1
        guard offset + addrLen <= data.count else { return nil }
        let address = String(data: Data(data[offset..<(offset + addrLen)]), encoding: .ascii) ?? ""
        offset += addrLen

        // Chain code
        guard offset + 32 <= data.count else { return nil }
        let chainCode = Data(data[offset..<(offset + 32)])

        return (publicKey: pubkey, chainCode: chainCode, address: address)
    }

    /// Compress a 65-byte uncompressed public key to 33-byte compressed
    static func compressPublicKey(_ uncompressed: Data) -> Data? {
        guard uncompressed.count == 65, uncompressed[0] == 0x04 else {
            // Already compressed?
            if uncompressed.count == 33 && (uncompressed[0] == 0x02 || uncompressed[0] == 0x03) {
                return uncompressed
            }
            return nil
        }

        let x = Data(uncompressed[1..<33])
        let y = Data(uncompressed[33..<65])

        // If y is even, prefix 0x02; if odd, prefix 0x03
        let prefix: UInt8 = (y.last! & 1) == 0 ? 0x02 : 0x03
        var compressed = Data([prefix])
        compressed.append(x)

        return compressed
    }

    // MARK: - BLE Framing
    // Ledger BLE frame format (no channel ID for BLE transport):
    // First chunk:  [tag:1=0x05] [seq:2] [total_length:2] [data...]
    // Other chunks: [tag:1=0x05] [seq:2] [data...]

    static let bleTag: UInt8 = 0x05
    // Ledger Nano X BLE write buffer — reduced to avoid crashes on large writes.
    // Official spec says 156 but some firmware versions can't handle it.
    static let bleMTU = 64

    /// Split an APDU into BLE frames
    static func frameForBLE(_ apdu: Data, mtu: Int = bleMTU) -> [Data] {
        var frames: [Data] = []
        var remaining = apdu
        var sequenceIndex: UInt16 = 0

        // First frame: tag(1) + seq(2) + length(2) + data
        let firstHeaderSize = 5
        let firstDataSize = min(remaining.count, mtu - firstHeaderSize)

        var firstFrame = Data()
        firstFrame.append(bleTag)
        firstFrame.append(contentsOf: withUnsafeBytes(of: sequenceIndex.bigEndian) { Array($0) })
        let totalLen = UInt16(apdu.count)
        firstFrame.append(contentsOf: withUnsafeBytes(of: totalLen.bigEndian) { Array($0) })
        firstFrame.append(remaining.prefix(firstDataSize))
        remaining = Data(remaining.dropFirst(firstDataSize))
        frames.append(firstFrame)
        sequenceIndex += 1

        // Subsequent frames: tag(1) + seq(2) + data
        let nextHeaderSize = 3
        while !remaining.isEmpty {
            var frame = Data()
            frame.append(bleTag)
            frame.append(contentsOf: withUnsafeBytes(of: sequenceIndex.bigEndian) { Array($0) })

            let chunkSize = min(remaining.count, mtu - nextHeaderSize)
            frame.append(remaining.prefix(chunkSize))
            remaining = Data(remaining.dropFirst(chunkSize))
            frames.append(frame)
            sequenceIndex += 1
        }

        return frames
    }

    /// Result of reassembling BLE frames
    enum ReassembleResult {
        case success(Data)       // 0x9000 — payload without status word
        case interrupted(Data)   // 0xE000 — client command payload
        case error(UInt16)       // Error status word
        case malformed           // Could not parse frames
    }

    /// Reassemble BLE frames into a single APDU response
    /// Frame format: [tag:1=0x05] [seq:2] [length:2 (first only)] [data...]
    static func reassembleBLEFrames(_ frames: [Data]) -> ReassembleResult {
        guard !frames.isEmpty else { return .malformed }

        // First frame: tag(1) + seq(2) + length(2) + data = header 5 bytes
        let first = frames[0]
        guard first.count >= 5 else { return .malformed }

        let totalLength = Int(UInt16(first[3]) << 8 | UInt16(first[4]))
        var result = Data(first[5...])

        // Subsequent frames: tag(1) + seq(2) + data = header 3 bytes
        for i in 1..<frames.count {
            let frame = frames[i]
            guard frame.count >= 3 else { continue }
            result.append(Data(frame[3...]))
        }

        // Trim to expected length
        guard result.count >= totalLength else { return .malformed }
        result = Data(result.prefix(totalLength))

        #if DEBUG
        print("[Ledger] Reassembled \(totalLength) bytes from \(frames.count) frames")
        #endif

        // Check status word (last 2 bytes)
        guard result.count >= 2 else { return .malformed }
        let sw = UInt16(result[result.count - 2]) << 8 | UInt16(result[result.count - 1])

        #if DEBUG
        print("[Ledger] Status word: 0x\(String(format: "%04X", sw))")
        #endif

        // Remove status word from data
        let payload = Data(result.prefix(result.count - 2))

        // 0x9000 = success, 0xE000 = interrupted (client command)
        if sw == 0x9000 {
            return .success(payload)
        } else if sw == 0xE000 {
            #if DEBUG
            print("[Ledger] Device requests client command")
            #endif
            return .interrupted(payload)
        } else {
            #if DEBUG
            print("[Ledger] Error status: 0x\(String(format: "%04X", sw))")
            #endif
            return .error(sw)
        }
    }

    // MARK: - Derivation path parsing

    /// Parse "m/84'/0'/0'" to [0x80000054, 0x80000000, 0x80000000]
    static func parsePath(_ path: String) -> [UInt32]? {
        let components = path
            .replacingOccurrences(of: "m/", with: "")
            .split(separator: "/")

        var result: [UInt32] = []
        for component in components {
            let str = String(component)
            if str.hasSuffix("'") || str.hasSuffix("h") {
                guard let num = UInt32(str.dropLast()) else { return nil }
                result.append(num | 0x80000000) // Hardened
            } else {
                guard let num = UInt32(str) else { return nil }
                result.append(num)
            }
        }

        return result
    }

    /// Default derivation path for BIP84 (native segwit)
    static func defaultPath(isTestnet: Bool) -> [UInt32] {
        let coinType: UInt32 = isTestnet ? 1 : 0
        return [
            84 | 0x80000000,     // purpose (hardened)
            coinType | 0x80000000, // coin type (hardened)
            0 | 0x80000000       // account (hardened)
        ]
    }
}
