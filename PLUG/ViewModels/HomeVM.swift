import Foundation
import Combine

@MainActor
final class HomeVM: ObservableObject {

    @Published var btcPrice: Double = 0
    @Published var blockHeight: Int = 0
    @Published var feeEstimate: FeeEstimate?
    @Published var difficulty: DifficultyAdjustment?
    @Published var totalBalance: UInt64 = 0
    @Published var alerts: [DashboardAlert] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var wsConnected = false

    private var cancellables = Set<AnyCancellable>()

    var isTestnet: Bool { NetworkConfig.shared.isTestnet }

    // MARK: - Balance computations

    var walletBalance: UInt64 { totalBalance }

    var vaultsBalance: UInt64 {
        vaults.reduce(0) { $0 + $1.amount }
    }

    var inheritanceBalance: UInt64 {
        inheritances.reduce(0) { $0 + $1.amount }
    }

    var poolsBalance: UInt64 {
        pools.reduce(0) { $0 + $1.amount }
    }

    var grandTotal: UInt64 {
        walletBalance + vaultsBalance + inheritanceBalance + poolsBalance
    }

    var balanceBTC: Double {
        Double(grandTotal) / 100_000_000
    }

    var balanceUSD: Double {
        balanceBTC * btcPrice
    }

    /// Distribution percentages
    struct Distribution {
        let label: String
        let percent: Double
        let color: String // hex or name
    }

    var distributions: [Distribution] {
        let total = Double(max(grandTotal, 1))
        return [
            Distribution(label: "Wallet", percent: Double(walletBalance) / total * 100, color: "wallet"),
            Distribution(label: "Vaults", percent: Double(vaultsBalance) / total * 100, color: "vault"),
            Distribution(label: "Inheritance", percent: Double(inheritanceBalance) / total * 100, color: "inheritance"),
            Distribution(label: "Pools", percent: Double(poolsBalance) / total * 100, color: "pool"),
        ].filter { $0.percent > 0 }
    }

    // MARK: - Contracts

    var activeContracts: [Contract] {
        ContractStore.shared.contractsForNetwork(isTestnet: isTestnet)
    }

    var vaults: [Contract] {
        activeContracts.filter { $0.type == .vault }
    }

    var inheritances: [Contract] {
        activeContracts.filter { $0.type == .inheritance }
    }

    var pools: [Contract] {
        activeContracts.filter { $0.type == .pool }
    }

    var readyVaultsCount: Int {
        vaults.filter { vault in
            guard let lh = vault.lockBlockHeight else { return false }
            return blockHeight >= lh
        }.count
    }

    func vaultTimeRemaining(_ contract: Contract) -> String {
        guard let lockHeight = contract.lockBlockHeight else { return "" }
        let remaining = lockHeight - blockHeight
        if remaining <= 0 { return "Unlocked" }
        let hours = remaining * 10 / 60
        let days = hours / 24
        let h = hours % 24
        return "\(days)d \(h)h"
    }

    func isVaultUnlocked(_ contract: Contract) -> Bool {
        guard let lh = contract.lockBlockHeight else { return false }
        return blockHeight >= lh
    }

    func inheritanceWindow(_ contract: Contract) -> String {
        guard let csv = contract.csvBlocks else { return "" }
        let hours = csv * 10 / 60
        let days = hours / 24
        let h = hours % 24
        return "\(days)d \(h)h window"
    }

    // MARK: - Formatted numbers

    static func formatSats(_ sats: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: sats)) ?? "\(sats)"
    }

    static func formatPrice(_ price: Double) -> String {
        let whole = Int(price)
        let thousands = whole / 1000
        let remainder = whole % 1000
        if thousands > 0 {
            return "$\(thousands) \(String(format: "%03d", remainder))"
        }
        return "$\(whole)"
    }

    static func formatBlock(_ height: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        return formatter.string(from: NSNumber(value: height)) ?? "\(height)"
    }

    // MARK: - Refresh

    func refresh() async {
        isLoading = true
        error = nil

        do {
            async let priceTask = MempoolAPI.shared.getBTCPrice()
            async let heightTask = MempoolAPI.shared.getBlockHeight()
            async let feesTask = MempoolAPI.shared.getRecommendedFees()
            async let diffTask = MempoolAPI.shared.getDifficultyAdjustment()

            btcPrice = try await priceTask
            blockHeight = try await heightTask
            feeEstimate = try await feesTask
            difficulty = try await diffTask

            updateAlerts()
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    func updateBalance(_ balance: UInt64) {
        totalBalance = balance
    }

    private func updateAlerts() {
        var newAlerts: [DashboardAlert] = []
        for contract in vaults {
            if let lockHeight = contract.lockBlockHeight, blockHeight >= lockHeight {
                newAlerts.append(.vaultUnlocked(contractName: contract.name))
            }
        }
        alerts = newAlerts
    }

    func connectWebSocket() {
        WebSocketManager.shared.connect()

        WebSocketManager.shared.$latestBlockHeight
            .receive(on: DispatchQueue.main)
            .sink { [weak self] height in
                if height > 0 { self?.blockHeight = height; self?.updateAlerts() }
            }
            .store(in: &cancellables)

        WebSocketManager.shared.$btcPrice
            .receive(on: DispatchQueue.main)
            .sink { [weak self] price in
                if price > 0 { self?.btcPrice = price }
            }
            .store(in: &cancellables)

        WebSocketManager.shared.$isConnected
            .receive(on: DispatchQueue.main)
            .assign(to: &$wsConnected)
    }
}
