import Foundation

// MARK: - Transaction Labels
// Maps txid -> user label (UserDefaults)

final class TxLabelStore: ObservableObject {

    static let shared = TxLabelStore()

    @Published private(set) var labels: [String: String] = [:]

    private let key = "tx_labels"

    init() {
        labels = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    func setLabel(_ label: String, forTxid txid: String) {
        labels[txid] = label
        persist()
    }

    func label(forTxid txid: String) -> String? {
        labels[txid]
    }

    func removeLabel(forTxid txid: String) {
        labels.removeValue(forKey: txid)
        persist()
    }

    func clearAll() {
        labels.removeAll()
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func persist() {
        UserDefaults.standard.set(labels, forKey: key)
    }
}
