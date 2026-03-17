import Foundation

// MARK: - Frozen UTXO Store
// Set of outpoints "txid:vout" that are frozen (excluded from coin selection)
// Persisted in UserDefaults

final class FrozenUTXOStore: ObservableObject {

    static let shared = FrozenUTXOStore()

    @Published private(set) var frozenOutpoints: Set<String> = []

    private let key = "frozen_utxos"

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: key) ?? []
        frozenOutpoints = Set(stored)
    }

    func freeze(outpoint: String) {
        frozenOutpoints.insert(outpoint)
        persist()
    }

    func unfreeze(outpoint: String) {
        frozenOutpoints.remove(outpoint)
        persist()
    }

    func isFrozen(outpoint: String) -> Bool {
        frozenOutpoints.contains(outpoint)
    }

    func toggle(outpoint: String) {
        if isFrozen(outpoint: outpoint) {
            unfreeze(outpoint: outpoint)
        } else {
            freeze(outpoint: outpoint)
        }
    }

    func clearAll() {
        frozenOutpoints.removeAll()
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func persist() {
        UserDefaults.standard.set(Array(frozenOutpoints), forKey: key)
    }
}
