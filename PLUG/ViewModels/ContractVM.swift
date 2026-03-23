import Foundation

// MARK: - Contract ViewModel Protocol
// Shared state and logic for all contract type ViewModels.
// All conforming types must be @MainActor.

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

    /// Refresh contracts: show list immediately, fetch balances in background.
    @MainActor
    func refreshContracts() async {
        contracts = filteredContracts
        isLoading = true

        do {
            currentBlockHeight = try await MempoolAPI.shared.getBlockHeight()
        } catch {
            #if DEBUG
            print("[ContractVM] Block height fetch failed: \(error.localizedDescription)")
            #endif
        }

        if !contracts.isEmpty {
            let result = await ContractSpendCoordinator.refreshBalances(
                contracts: contracts, blockHeight: currentBlockHeight
            )
            fundedAmounts = result.amounts
            confirmations = result.confirmations
        }

        isLoading = false
    }

    func fundedAmount(for contract: Contract) -> UInt64 {
        fundedAmounts[contract.address] ?? 0
    }

    func progress(for contract: Contract) -> Double {
        guard contract.amount > 0 else { return 0 }
        return min(1.0, Double(fundedAmount(for: contract)) / Double(contract.amount))
    }

    func isDuplicateAddress(_ address: String) -> Bool {
        ContractStore.shared.contractsForNetwork(isTestnet: isTestnet)
            .contains { $0.address == address }
    }
}
