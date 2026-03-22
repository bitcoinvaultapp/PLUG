import Foundation

// MARK: - Contract ViewModel Protocol
// Shared state and logic for all contract type ViewModels.
// Eliminates duplication across Vault, Inheritance, HTLC, Channel, Pool VMs.

protocol ContractVM: ObservableObject {
    var contracts: [Contract] { get set }
    var currentBlockHeight: Int { get set }
    var isLoading: Bool { get set }
    var error: String? { get set }
    var fundedAmounts: [String: UInt64] { get set }
    var confirmations: [String: Int] { get set }

    /// Return filtered contracts for this type
    var filteredContracts: [Contract] { get }
}

extension ContractVM {

    var isTestnet: Bool { NetworkConfig.shared.isTestnet }

    /// Refresh contracts: fetch block height, update list, refresh balances.
    func refreshContracts() async {
        isLoading = true
        do {
            currentBlockHeight = try await MempoolAPI.shared.getBlockHeight()
            contracts = filteredContracts
            let result = await ContractSpendCoordinator.refreshBalances(
                contracts: contracts, blockHeight: currentBlockHeight
            )
            fundedAmounts = result.amounts
            confirmations = result.confirmations
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Get funded amount for a contract (0 if not yet fetched)
    func fundedAmount(for contract: Contract) -> UInt64 {
        fundedAmounts[contract.address] ?? 0
    }

    /// Progress toward target (0.0 to 1.0)
    func progress(for contract: Contract) -> Double {
        guard contract.amount > 0 else { return 0 }
        return min(1.0, Double(fundedAmount(for: contract)) / Double(contract.amount))
    }

    /// Check if a contract address already exists (duplicate prevention)
    func isDuplicateAddress(_ address: String) -> Bool {
        ContractStore.shared.contractsForNetwork(isTestnet: isTestnet)
            .contains { $0.address == address }
    }
}
