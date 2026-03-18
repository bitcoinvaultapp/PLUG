import Foundation
import CryptoKit
import CommonCrypto

@MainActor
final class BackupVM: ObservableObject {

    @Published var exportPassword: String = ""
    @Published var importPassword: String = ""
    @Published var importData: String = ""  // base64
    @Published var exportedData: Data?
    @Published var message: String?
    @Published var isLoading = false
    @Published var error: String?

    /// Export all contracts and labels as encrypted backup.
    /// Uses PBKDF2 key derivation + AES-256-GCM authenticated encryption.
    func exportBackup() {
        guard !exportPassword.isEmpty else {
            error = "Password required"
            return
        }

        isLoading = true
        error = nil
        message = nil

        let contracts = ContractStore.shared.contracts
        let labels = TxLabelStore.shared.labels
        let backup = BackupPayload(contracts: contracts, labels: labels)

        guard let jsonData = try? JSONEncoder().encode(backup) else {
            error = "Unable to encode data"
            isLoading = false
            return
        }

        do {
            let encrypted = try encryptAESGCM(plaintext: jsonData, password: exportPassword)
            exportedData = encrypted
            message = "Backup exported successfully"
            exportPassword = ""
        } catch {
            self.error = "Encryption failed: \(error.localizedDescription)"
        }

        isLoading = false
    }

    /// Import backup from encrypted base64 data.
    func importBackup() {
        guard !importPassword.isEmpty else {
            error = "Password required"
            return
        }

        guard let encryptedData = Data(base64Encoded: importData.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "Invalid Base64 data"
            return
        }

        isLoading = true
        error = nil
        message = nil

        do {
            let decrypted = try decryptAESGCM(ciphertext: encryptedData, password: importPassword)

            guard let backup = try? JSONDecoder().decode(BackupPayload.self, from: decrypted) else {
                error = "Incorrect password or corrupted data"
                isLoading = false
                return
            }

            // Restore contracts
            for contract in backup.contracts {
                if ContractStore.shared.contract(byId: contract.id) == nil {
                    ContractStore.shared.add(contract)
                }
            }

            // Restore labels
            for (txid, label) in backup.labels {
                TxLabelStore.shared.setLabel(label, forTxid: txid)
            }

            message = "Backup imported successfully (\(backup.contracts.count) contracts, \(backup.labels.count) labels)"
            importPassword = ""
            importData = ""
        } catch {
            self.error = "Incorrect password or corrupted data"
        }

        isLoading = false
    }

    /// Export labels in BIP329 format (JSON lines)
    func exportBIP329() -> Data {
        let labels = TxLabelStore.shared.labels
        var lines: [String] = []
        for (txid, label) in labels {
            let entry = BIP329Entry(type: "tx", ref: txid, label: label)
            if let data = try? JSONEncoder().encode(entry),
               let line = String(data: data, encoding: .utf8) {
                lines.append(line)
            }
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// Import labels from BIP329 format
    func importBIP329(data: Data) {
        guard let text = String(data: data, encoding: .utf8) else {
            error = "Invalid BIP329 data"
            return
        }

        var count = 0
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(BIP329Entry.self, from: lineData) else {
                continue
            }
            if entry.type == "tx" {
                TxLabelStore.shared.setLabel(entry.label, forTxid: entry.ref)
                count += 1
            }
        }

        message = "\(count) BIP329 labels imported"
    }

    // MARK: - AES-256-GCM + PBKDF2

    /// Encrypted format: version(1) + salt(32) + nonce(12) + ciphertext + tag(16)
    private static let encryptionVersion: UInt8 = 0x01
    private static let pbkdf2Rounds: UInt32 = 600_000
    private static let saltLength = 32

    /// Derive a 256-bit key from password using PBKDF2-HMAC-SHA256
    private func deriveKey(password: String, salt: Data) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derivedKey = Data(count: 32)

        derivedKey.withUnsafeMutableBytes { derivedKeyPtr in
            salt.withUnsafeBytes { saltPtr in
                passwordData.withUnsafeBytes { passwordPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.baseAddress!.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        Self.pbkdf2Rounds,
                        derivedKeyPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }

        return SymmetricKey(data: derivedKey)
    }

    /// Encrypt with AES-256-GCM + PBKDF2 key derivation
    private func encryptAESGCM(plaintext: Data, password: String) throws -> Data {
        // Generate random salt
        var salt = Data(count: Self.saltLength)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, Self.saltLength, $0.baseAddress!) }

        // Derive key
        let key = deriveKey(password: password, salt: salt)

        // Encrypt
        let sealedBox = try AES.GCM.seal(plaintext, using: key)

        // Pack: version + salt + nonce + ciphertext + tag
        var packed = Data()
        packed.append(Self.encryptionVersion)
        packed.append(salt)
        packed.append(contentsOf: sealedBox.nonce)
        packed.append(sealedBox.ciphertext)
        packed.append(sealedBox.tag)

        return packed
    }

    /// Decrypt AES-256-GCM with PBKDF2 key derivation
    private func decryptAESGCM(ciphertext: Data, password: String) throws -> Data {
        // Minimum size: version(1) + salt(32) + nonce(12) + tag(16) = 61
        guard ciphertext.count >= 61 else {
            throw BackupError.invalidFormat
        }

        let version = ciphertext[0]
        guard version == Self.encryptionVersion else {
            throw BackupError.unsupportedVersion
        }

        let salt = ciphertext[1..<33]
        let nonce = try AES.GCM.Nonce(data: ciphertext[33..<45])
        let encrypted = ciphertext[45..<(ciphertext.count - 16)]
        let tag = ciphertext[(ciphertext.count - 16)...]

        let key = deriveKey(password: password, salt: Data(salt))

        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: encrypted, tag: tag)
        return try AES.GCM.open(sealedBox, using: key)
    }

    enum BackupError: LocalizedError {
        case invalidFormat
        case unsupportedVersion

        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "Invalid backup format"
            case .unsupportedVersion: return "Unsupported backup version"
            }
        }
    }
}

// MARK: - Backup data structures

private struct BackupPayload: Codable {
    let contracts: [Contract]
    let labels: [String: String]
}

private struct BIP329Entry: Codable {
    let type: String
    let ref: String
    let label: String
}
