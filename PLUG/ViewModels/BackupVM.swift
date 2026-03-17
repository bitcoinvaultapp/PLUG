import Foundation

@MainActor
final class BackupVM: ObservableObject {

    @Published var exportPassword: String = ""
    @Published var importPassword: String = ""
    @Published var importData: String = ""  // base64
    @Published var exportedData: Data?
    @Published var message: String?
    @Published var isLoading = false
    @Published var error: String?

    /// Export all contracts and labels as encrypted backup
    func exportBackup() {
        guard !exportPassword.isEmpty else {
            error = "Mot de passe requis"
            return
        }

        isLoading = true
        error = nil
        message = nil

        // Gather data
        let contracts = ContractStore.shared.contracts
        let labels = TxLabelStore.shared.labels

        let backup = BackupPayload(contracts: contracts, labels: labels)

        guard let jsonData = try? JSONEncoder().encode(backup) else {
            error = "Impossible d'encoder les donnees"
            isLoading = false
            return
        }

        // Encrypt with password using SHA256 as key derivation + AES-like XOR
        let keyData = Crypto.sha256(Data(exportPassword.utf8))
        let encrypted = xorCrypt(data: jsonData, key: keyData)

        exportedData = encrypted
        message = "Backup exporte avec succes"
        exportPassword = ""
        isLoading = false
    }

    /// Import backup from encrypted base64 data
    func importBackup() {
        guard !importPassword.isEmpty else {
            error = "Mot de passe requis"
            return
        }

        guard let encryptedData = Data(base64Encoded: importData.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "Donnees Base64 invalides"
            return
        }

        isLoading = true
        error = nil
        message = nil

        let keyData = Crypto.sha256(Data(importPassword.utf8))
        let decrypted = xorCrypt(data: encryptedData, key: keyData)

        guard let backup = try? JSONDecoder().decode(BackupPayload.self, from: decrypted) else {
            error = "Mot de passe incorrect ou donnees corrompues"
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

        message = "Backup importe avec succes (\(backup.contracts.count) contrats, \(backup.labels.count) labels)"
        importPassword = ""
        importData = ""
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
            error = "Donnees BIP329 invalides"
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

        message = "\(count) labels BIP329 importes"
    }

    // MARK: - Private helpers

    /// Simple XOR encryption with repeating key
    private func xorCrypt(data: Data, key: Data) -> Data {
        var result = Data(count: data.count)
        for i in 0..<data.count {
            result[i] = data[i] ^ key[i % key.count]
        }
        return result
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
