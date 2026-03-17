import Foundation

// MARK: - Ledger Bitcoin App v2 Protocol (v2.0.6+)
// New CLA=0xE1, merkleized PSBT, multi-round client command flow

struct LedgerV2 {

    // MARK: - Constants

    static let CLA: UInt8 = 0xE1
    static let CLA_CONTINUE: UInt8 = 0xF8

    enum INS: UInt8 {
        case getPubkey = 0x00
        case registerWallet = 0x02
        case getWalletAddress = 0x03
        case signPSBT = 0x04
        case getMasterFingerprint = 0x05
        case signMessage = 0x10
    }

    enum FrameworkINS: UInt8 {
        case continueInterrupted = 0x01
    }

    enum ClientCommand: UInt8 {
        case yield = 0x10
        case getPreimage = 0x40
        case getMerkleLeafProof = 0x41
        case getMerkleLeafIndex = 0x42
        case getMoreElements = 0xA0
    }

    // Status words
    static let SW_OK: UInt16 = 0x9000
    static let SW_INTERRUPTED: UInt16 = 0xE000

    // MARK: - GET_EXTENDED_PUBKEY

    /// Build APDU for getting extended public key (v2 protocol)
    /// CLA=0xE1, INS=0x00
    /// Data: [display:1] [path_count:1] [path_element:4]...
    static func getExtendedPubkeyAPDU(path: [UInt32], display: Bool = false) -> LedgerProtocol.APDU {
        var data = Data()

        // Display flag
        data.append(display ? 0x01 : 0x00)

        // Number of path elements
        data.append(UInt8(path.count))

        // Each path element as 4 bytes big-endian
        for component in path {
            var be = component.bigEndian
            data.append(Data(bytes: &be, count: 4))
        }

        return LedgerProtocol.APDU(
            cla: CLA,
            ins: INS.getPubkey.rawValue,
            p1: 0x00,
            p2: 0x00,
            data: data
        )
    }

    /// Parse xpub response from v2 protocol
    /// Response is the xpub string in ASCII followed by 2-byte status word
    static func parseExtendedPubkeyResponse(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        // The response is the raw xpub string (no length prefix in v2)
        return String(data: data, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters)
    }

    // MARK: - GET_MASTER_FINGERPRINT

    static func getMasterFingerprintAPDU(protocolVersion: UInt8 = 0x01) -> LedgerProtocol.APDU {
        LedgerProtocol.APDU(
            cla: CLA,
            ins: INS.getMasterFingerprint.rawValue,
            p1: 0x00,
            p2: protocolVersion,
            data: Data()
        )
    }

    // MARK: - GET_APP_AND_VERSION (framework command)

    static func getAppAndVersionAPDU() -> LedgerProtocol.APDU {
        LedgerProtocol.APDU(
            cla: 0xB0,
            ins: 0x01,
            p1: 0x00,
            p2: 0x00,
            data: Data()
        )
    }

    /// Parse app name and version from response
    /// Format: [format_version] [name_len] [name] [version_len] [version] [flags_len] [flags]
    static func parseAppAndVersion(_ data: Data) -> (name: String, version: String)? {
        guard data.count >= 4 else { return nil }

        var offset = 1 // skip format version

        // Name
        guard offset < data.count else { return nil }
        let nameLen = Int(data[offset])
        offset += 1
        guard offset + nameLen <= data.count else { return nil }
        let name = String(data: Data(data[offset..<(offset + nameLen)]), encoding: .ascii) ?? ""
        offset += nameLen

        // Version
        guard offset < data.count else { return nil }
        let versionLen = Int(data[offset])
        offset += 1
        guard offset + versionLen <= data.count else { return nil }
        let version = String(data: Data(data[offset..<(offset + versionLen)]), encoding: .ascii) ?? ""

        return (name, version)
    }

    // MARK: - SIGN_PSBT (simplified for P2WPKH)
    // The full merkleized PSBT protocol is complex. For simple P2WPKH transactions,
    // we use a simplified approach that works with the default wallet policy.

    /// Build the initial SIGN_PSBT APDU
    /// For default wallet policy (no registration needed), wallet_id and hmac are zeros
    static func signPSBTAPDU(
        globalMapCommitment: Data,     // 32 bytes - merkle root of global map
        inputCount: Int,
        inputMapCommitment: Data,      // 32 bytes - merkle root of input maps
        outputCount: Int,
        outputMapCommitment: Data,     // 32 bytes - merkle root of output maps
        walletPolicy: Data             // serialized wallet policy
    ) -> LedgerProtocol.APDU {
        var data = Data()

        // Global map commitment (32 bytes)
        data.append(globalMapCommitment)

        // Input count (varint)
        data.append(VarInt.encode(UInt64(inputCount)))

        // Input map commitment (32 bytes)
        data.append(inputMapCommitment)

        // Output count (varint)
        data.append(VarInt.encode(UInt64(outputCount)))

        // Output map commitment (32 bytes)
        data.append(outputMapCommitment)

        // Wallet policy (for default wallet: all zeros)
        // wallet_id (32 bytes) + wallet_hmac (32 bytes)
        data.append(Data(repeating: 0, count: 64))

        return LedgerProtocol.APDU(
            cla: CLA,
            ins: INS.signPSBT.rawValue,
            p1: 0x00,
            p2: 0x00,
            data: data
        )
    }

    // MARK: - Continue Interrupted APDU

    /// Build continuation APDU after processing a client command
    static func continueAPDU(responseData: Data) -> LedgerProtocol.APDU {
        LedgerProtocol.APDU(
            cla: CLA_CONTINUE,
            ins: FrameworkINS.continueInterrupted.rawValue,
            p1: 0x00,
            p2: 0x00,
            data: responseData
        )
    }

    // MARK: - Merkle Tree helpers

    /// Compute SHA256 hash of a key-value pair for merkle tree
    static func hashKeyValue(key: Data, value: Data) -> Data {
        var buf = Data()
        buf.append(VarInt.encode(UInt64(key.count)))
        buf.append(key)
        buf.append(VarInt.encode(UInt64(value.count)))
        buf.append(value)
        return Crypto.sha256(buf)
    }

    /// Build a merkle tree from leaf hashes, return root
    static func merkleRoot(leaves: [Data]) -> Data {
        guard !leaves.isEmpty else {
            return Data(repeating: 0, count: 32)
        }
        if leaves.count == 1 {
            return leaves[0]
        }

        var level = leaves
        while level.count > 1 {
            var nextLevel: [Data] = []
            for i in stride(from: 0, to: level.count, by: 2) {
                if i + 1 < level.count {
                    // Hash pair: sort lexicographically then hash
                    let left = level[i]
                    let right = level[i + 1]
                    let combined = left < right
                        ? left + right
                        : right + left
                    nextLevel.append(Crypto.sha256(combined))
                } else {
                    // Odd element: promote
                    nextLevel.append(level[i])
                }
            }
            level = nextLevel
        }

        return level[0]
    }

    /// Get merkle proof for a leaf at given index
    static func merkleProof(leaves: [Data], index: Int) -> [Data] {
        guard leaves.count > 1 && index < leaves.count else { return [] }

        var proof: [Data] = []
        var level = leaves
        var idx = index

        while level.count > 1 {
            let siblingIdx = idx % 2 == 0 ? idx + 1 : idx - 1
            if siblingIdx < level.count {
                proof.append(level[siblingIdx])
            }

            var nextLevel: [Data] = []
            for i in stride(from: 0, to: level.count, by: 2) {
                if i + 1 < level.count {
                    let left = level[i]
                    let right = level[i + 1]
                    let combined = left < right ? left + right : right + left
                    nextLevel.append(Crypto.sha256(combined))
                } else {
                    nextLevel.append(level[i])
                }
            }
            level = nextLevel
            idx = idx / 2
        }

        return proof
    }

    // MARK: - Data comparison for merkle sorting

    private static func dataLessThan(_ a: Data, _ b: Data) -> Bool {
        let minLen = min(a.count, b.count)
        for i in 0..<minLen {
            if a[i] != b[i] { return a[i] < b[i] }
        }
        return a.count < b.count
    }
}

// MARK: - Extend Data for comparison
extension Data: @retroactive Comparable {
    public static func < (lhs: Data, rhs: Data) -> Bool {
        lhs.lexicographicallyPrecedes(rhs)
    }
}
