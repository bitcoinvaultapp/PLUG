import Foundation
import Combine

@MainActor
final class HomeVM: ObservableObject {

    static let shared = HomeVM()

    @Published var btcPrice: Double = 0
    @Published var blockHeight: Int = 0
    @Published var lastBlockTime: Int = 0
    @Published var feeEstimate: FeeEstimate?
    @Published var difficulty: DifficultyAdjustment?
    @Published var alerts: [DashboardAlert] = []
    @Published var contractBalances: [String: UInt64] = [:]
    @Published var isLoading = false
    @Published var error: String?
    @Published var wsConnected = false

    private var cancellables = Set<AnyCancellable>()

    var isTestnet: Bool { NetworkConfig.shared.isTestnet }

    init() {
        // Re-publish when ContractStore changes so computed properties (activeContracts, vaults, etc.) update
        ContractStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
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

        // Fetch independently — one failure doesn't block the others
        do { btcPrice = try await MempoolAPI.shared.getBTCPrice() }
        catch {
            #if DEBUG
            print("[HomeVM] Price fetch failed: \(error.localizedDescription)")
            #endif
        }

        do {
            let newHeight = try await MempoolAPI.shared.getBlockHeight()
            if newHeight != blockHeight { lastBlockTime = Int(Date().timeIntervalSince1970) }
            blockHeight = newHeight
        } catch {
            #if DEBUG
            print("[HomeVM] Block height fetch failed: \(error.localizedDescription)")
            #endif
        }

        do { feeEstimate = try await MempoolAPI.shared.getRecommendedFees() }
        catch {
            #if DEBUG
            print("[HomeVM] Fee fetch failed: \(error.localizedDescription)")
            #endif
        }

        do { difficulty = try await MempoolAPI.shared.getDifficultyAdjustment() }
        catch {
            #if DEBUG
            print("[HomeVM] Difficulty fetch failed: \(error.localizedDescription)")
            #endif
        }

        updateAlerts()
        isLoading = false
    }

    private func updateAlerts() {
        var newAlerts: [DashboardAlert] = []
        for contract in vaults {
            if let lockHeight = contract.lockBlockHeight, blockHeight >= lockHeight {
                newAlerts.append(.vaultUnlocked(contractId: contract.id, contractName: contract.name))
            }
        }
        alerts = newAlerts
    }

    /// Fetch on-chain balance for each contract address
    func refreshContractBalances() async {
        let contracts = activeContracts
        guard !contracts.isEmpty else { return }

        var balances: [String: UInt64] = [:]
        for contract in contracts {
            do {
                let utxos = try await MempoolAPI.shared.getAddressUTXOs(address: contract.address)
                let balance = utxos.reduce(UInt64(0)) { $0 + $1.value }
                balances[contract.id] = balance
            } catch {
                balances[contract.id] = 0
            }
        }
        contractBalances = balances
    }

    func connectWebSocket() {
        WebSocketManager.shared.connect()

        WebSocketManager.shared.$latestBlockHeight
            .receive(on: DispatchQueue.main)
            .sink { [weak self] height in
                if height > 0 {
                    if height != self?.blockHeight {
                        self?.lastBlockTime = Int(Date().timeIntervalSince1970)
                    }
                    self?.blockHeight = height
                    self?.updateAlerts()
                }
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
