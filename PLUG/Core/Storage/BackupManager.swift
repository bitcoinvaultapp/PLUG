import Foundation

// MARK: - Encrypted Backup Export / Import
// Password-protected backup using HMAC-SHA512 KDF + XOR stream cipher
// Format: salt(32) + hmac(32) + encrypted_payload

struct BackupManager {

    struct BackupPayload: Codable {
        let version: Int
        let timestamp: Date
        let network: String
        let contracts: [Contract]
        let txLabels: [String: String]
        let frozenUTXOs: [String]
        let xpub: String?
        let addressIndices: [String: UInt32]
    }

    private static let currentVersion = 1
    private static let saltLength = 32
    private static let hmacLength = 32  // truncated HMAC-SHA512
    private static let kdfIterations = 100_000

    // MARK: - Key Derivation (iterated HMAC-SHA512)

    static func deriveKey(password: String, salt: Data) -> Data {
        guard let passwordData = password.data(using: .utf8) else {
            return Data(repeating: 0, count: 64)
        }

        // PBKDF2-like: iterate HMAC-SHA512
        var result = Crypto.hmacSHA512(key: salt, data: passwordData)

        for _ in 1..<kdfIterations {
            result = Crypto.hmacSHA512(key: salt, data: result)
        }

        return result // 64 bytes: first 32 for encryption, last 32 for HMAC
    }

    // MARK: - XOR Stream Cipher

    /// Generates a keystream using HMAC-SHA512 in counter mode and XORs with data
    private static func xorCrypt(data: Data, key: Data) -> Data {
        let encKey = key.prefix(32)
        var output = Data(capacity: data.count)
        var counter: UInt64 = 0
        var offset = 0

        while offset < data.count {
            // Generate 64 bytes of keystream per block
            var counterData = Data(count: 8)
            counterData.withUnsafeMutableBytes { ptr in
                ptr.storeBytes(of: counter.littleEndian, as: UInt64.self)
            }

            let block = Crypto.hmacSHA512(key: encKey, data: counterData)
            let remaining = data.count - offset
            let blockSize = min(remaining, block.count)

            for i in 0..<blockSize {
                output.append(data[offset + i] ^ block[i])
            }

            offset += blockSize
            counter += 1
        }

        return output
    }

    // MARK: - HMAC Authentication

    private static func computeHMAC(data: Data, key: Data) -> Data {
        let hmacKey = key.suffix(32)
        let fullHMAC = Crypto.hmacSHA512(key: hmacKey, data: data)
        return fullHMAC.prefix(hmacLength) // truncate to 32 bytes
    }

    // MARK: - Export

    static func exportBackup(password: String) -> Data? {
        let isTestnet = NetworkConfig.shared.isTestnet
        let xpub = KeychainStore.shared.loadXpub(isTestnet: isTestnet)

        let payload = BackupPayload(
            version: currentVersion,
            timestamp: Date(),
            network: isTestnet ? "testnet" : "mainnet",
            contracts: ContractStore.shared.contracts,
            txLabels: TxLabelStore.shared.labels,
            frozenUTXOs: Array(FrozenUTXOStore.shared.frozenOutpoints),
            xpub: xpub,
            addressIndices: [:]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys

        guard let jsonData = try? encoder.encode(payload) else { return nil }

        // Generate random salt
        var salt = Data(count: saltLength)
        let status = salt.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, saltLength, ptr.baseAddress!)
        }
        guard status == errSecSuccess else { return nil }

        // Derive key
        let derivedKey = deriveKey(password: password, salt: salt)

        // Encrypt
        let encrypted = xorCrypt(data: jsonData, key: derivedKey)

        // Compute HMAC over salt + encrypted
        var authenticated = Data()
        authenticated.append(salt)
        authenticated.append(encrypted)
        let hmac = computeHMAC(data: authenticated, key: derivedKey)

        // Final format: salt(32) + hmac(32) + encrypted_payload
        var result = Data()
        result.append(salt)
        result.append(hmac)
        result.append(encrypted)

        return result
    }

    // MARK: - Import

    static func importBackup(data: Data, password: String) -> Bool {
        let headerSize = saltLength + hmacLength
        guard data.count > headerSize else { return false }

        // Parse components
        let salt = data.prefix(saltLength)
        let storedHMAC = data[saltLength..<headerSize]
        let encrypted = data.suffix(from: headerSize)

        // Derive key from password + salt
        let derivedKey = deriveKey(password: password, salt: salt)

        // Verify HMAC
        var authenticated = Data()
        authenticated.append(salt)
        authenticated.append(encrypted)
        let computedHMAC = computeHMAC(data: authenticated, key: derivedKey)

        guard constantTimeCompare(computedHMAC, Data(storedHMAC)) else {
            return false // Wrong password or corrupted data
        }

        // Decrypt
        let jsonData = xorCrypt(data: encrypted, key: derivedKey)

        // Decode
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let payload = try? decoder.decode(BackupPayload.self, from: jsonData) else {
            return false
        }

        // Restore data
        restorePayload(payload)
        return true
    }

    // MARK: - Restore

    private static func restorePayload(_ payload: BackupPayload) {
        // Restore contracts
        ContractStore.shared.clearAll()
        for contract in payload.contracts {
            ContractStore.shared.add(contract)
        }

        // Restore tx labels
        TxLabelStore.shared.clearAll()
        for (txid, label) in payload.txLabels {
            TxLabelStore.shared.setLabel(label, forTxid: txid)
        }

        // Restore frozen UTXOs
        FrozenUTXOStore.shared.clearAll()
        for outpoint in payload.frozenUTXOs {
            FrozenUTXOStore.shared.freeze(outpoint: outpoint)
        }

        // Restore xpub
        if let xpub = payload.xpub {
            let isTestnet = payload.network == "testnet"
            KeychainStore.shared.saveXpub(xpub, isTestnet: isTestnet)
        }
    }

    // MARK: - Constant-time comparison

    private static func constantTimeCompare(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for i in 0..<a.count {
            result |= a[i] ^ b[i]
        }
        return result == 0
    }
}
