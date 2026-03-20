import Foundation
import Combine
import SwiftUI

struct ContractNode: Identifiable {
    let id: String
    let contract: Contract
    var balance: UInt64
}

@MainActor
final class ContractBubbleVM: ObservableObject {
    @Published var nodes: [ContractNode] = []
    @Published var isLoading = false

    /// Load contracts of a specific type and fetch balances
    func loadContracts(type: ContractType) async {
        let contracts = ContractStore.shared.contractsForNetwork(isTestnet: NetworkConfig.shared.isTestnet)
            .filter { $0.type == type }
        guard !contracts.isEmpty else {
            nodes = []
            return
        }

        isLoading = true

        var balances: [String: UInt64] = [:]
        for contract in contracts {
            do {
                let utxos = try await MempoolAPI.shared.getAddressUTXOs(address: contract.address)
                balances[contract.id] = utxos.reduce(UInt64(0)) { $0 + $1.value }
            } catch {
                balances[contract.id] = 0
            }
        }

        nodes = contracts.map { contract in
            ContractNode(
                id: contract.id,
                contract: contract,
                balance: balances[contract.id] ?? 0
            )
        }

        isLoading = false
    }

}
