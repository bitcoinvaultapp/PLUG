import Foundation
import Combine

// MARK: - Contract Store
// CRUD for all contract types (tirelires, heritages, cagnottes)
// Persisted in Keychain

final class ContractStore: ObservableObject {

    static let shared = ContractStore()

    @Published var contracts: [Contract] = []

    private let keychainKey = "contracts_v1"

    init() {
        load()
    }

    // MARK: - CRUD

    func add(_ contract: Contract) {
        contracts.append(contract)
        persist()
    }

    func update(_ contract: Contract) {
        if let index = contracts.firstIndex(where: { $0.id == contract.id }) {
            contracts[index] = contract
            persist()
        }
    }

    func delete(id: String) {
        contracts.removeAll { $0.id == id }
        persist()
    }

    func contract(byId id: String) -> Contract? {
        contracts.first { $0.id == id }
    }

    // MARK: - Filtered access

    var tirelires: [Contract] {
        contracts.filter { $0.type == .tirelire }
    }

    var heritages: [Contract] {
        contracts.filter { $0.type == .heritage }
    }

    var cagnottes: [Contract] {
        contracts.filter { $0.type == .cagnotte }
    }

    var htlcs: [Contract] {
        contracts.filter { $0.type == .htlc }
    }

    var channels: [Contract] {
        contracts.filter { $0.type == .channel }
    }

    func contractsForNetwork(isTestnet: Bool) -> [Contract] {
        contracts.filter { $0.isTestnet == isTestnet }
    }

    // MARK: - Persistence

    private func persist() {
        KeychainStore.shared.saveCodable(contracts, forKey: keychainKey)
    }

    private func load() {
        if let loaded = KeychainStore.shared.loadCodable(forKey: keychainKey, type: [Contract].self) {
            contracts = loaded
        }
    }

    func clearAll() {
        contracts.removeAll()
        KeychainStore.shared.delete(forKey: keychainKey)
    }
}
