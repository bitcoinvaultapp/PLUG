import Foundation

// MARK: - BIP329 Wallet Label Export / Import
// JSONL format: one JSON object per line
// Spec: https://github.com/bitcoin/bips/blob/master/bip-0329.mediawiki

struct BIP329Labels {

    struct LabelRecord: Codable {
        let type: String   // "tx" or "addr"
        let ref: String    // txid or address
        let label: String
    }

    // MARK: - Export

    /// Exports all labels as JSONL (one JSON object per line)
    static func exportJSONL() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        var lines: [String] = []

        // Export transaction labels
        for (txid, label) in TxLabelStore.shared.labels {
            let record = LabelRecord(type: "tx", ref: txid, label: label)
            if let jsonData = try? encoder.encode(record),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                lines.append(jsonString)
            }
        }

        let joined = lines.joined(separator: "\n")
        return joined.data(using: .utf8) ?? Data()
    }

    // MARK: - Import

    /// Imports labels from JSONL data, returns count of labels imported
    static func importJSONL(_ data: Data) -> Int {
        guard let text = String(data: data, encoding: .utf8) else { return 0 }

        let decoder = JSONDecoder()
        var count = 0

        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8) else { continue }

            guard let record = try? decoder.decode(LabelRecord.self, from: lineData) else {
                continue
            }

            switch record.type {
            case "tx":
                TxLabelStore.shared.setLabel(record.label, forTxid: record.ref)
                count += 1
            case "addr":
                // Address labels stored as tx labels with addr: prefix key
                TxLabelStore.shared.setLabel(record.label, forTxid: "addr:\(record.ref)")
                count += 1
            default:
                continue
            }
        }

        return count
    }
}
