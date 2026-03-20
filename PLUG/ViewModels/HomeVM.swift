import Foundation
import Combine

@MainActor
final class HomeVM: ObservableObject {

    @Published var btcPrice: Double = 0
    @Published var blockHeight: Int = 0
    @Published var lastBlockTime: Int = 0
    @Published var feeEstimate: FeeEstimate?
    @Published var difficulty: DifficultyAdjustment?
    @Published var totalBalance: UInt64 = 0
    @Published var utxos: [UTXO] = []
    @Published var transactions: [Transaction] = []
    @Published var walletAddresses: [WalletAddress] = []
    @Published var alerts: [DashboardAlert] = []
    @Published var contractBalances: [String: UInt64] = [:]  // contract.id -> on-chain balance
    @Published var isLoading = false
    @Published var error: String?
    @Published var wsConnected = false

    var dustUtxos: [UTXO] { utxos.filter { $0.value < 546 } }
    var pendingTransactions: [Transaction] { transactions.filter { !$0.status.confirmed } }

    private var cancellables = Set<AnyCancellable>()
    private var lastBalanceRefresh: Date?

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
            let newHeight = try await heightTask
            if newHeight != blockHeight {
                lastBlockTime = Int(Date().timeIntervalSince1970)
            }
            blockHeight = newHeight
            feeEstimate = try await feesTask
            difficulty = try await diffTask

            updateAlerts()
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    /// Lightweight wallet fetch — derives addresses from xpub, fetches UTXOs + txs.
    /// Independent from WalletVM. No gap scan, just first 20 receiving + 20 change.
    func refreshBalance() async {
        let isTest = NetworkConfig.shared.isTestnet
        guard let xpubStr = KeychainStore.shared.loadXpub(isTestnet: isTest) else {
            #if DEBUG
            print("[HomeVM] No xpub in keychain — skipping balance refresh")
            #endif
            return
        }
        guard let xpub = ExtendedPublicKey.fromBase58(xpubStr) else {
            #if DEBUG
            print("[HomeVM] Failed to parse xpub: \(xpubStr.prefix(20))...")
            #endif
            return
        }

        // Skip if refreshed less than 30s ago to avoid 429 rate limits
        if let last = lastBalanceRefresh, Date().timeIntervalSince(last) < 30 {
            #if DEBUG
            print("[HomeVM] Skipping — last refresh \(Int(Date().timeIntervalSince(last)))s ago")
            #endif
            return
        }

        #if DEBUG
        print("[HomeVM] Deriving addresses from xpub...")
        #endif
        let receiving = AddressDerivation.deriveAddresses(xpub: xpub, change: 0, startIndex: 0, count: 20, isTestnet: isTest)
        let change = AddressDerivation.deriveAddresses(xpub: xpub, change: 1, startIndex: 0, count: 20, isTestnet: isTest)

        let allAddrs = receiving + change
        #if DEBUG
        print("[HomeVM] Derived \(allAddrs.count) addresses (\(receiving.count) receiving + \(change.count) change)")
        #endif

        if allAddrs.isEmpty {
            #if DEBUG
            print("[HomeVM] No addresses derived — aborting")
            #endif
            return
        }

        let walletAddrs = receiving.map { WalletAddress(index: $0.index, address: $0.address, publicKey: $0.publicKey.hex, isChange: false) }
            + change.map { WalletAddress(index: $0.index, address: $0.address, publicKey: $0.publicKey.hex, isChange: true) }

        // Fetch UTXOs first, then only fetch transactions for addresses that have UTXOs.
        // Shuffle address order to prevent timing-based correlation by the API server.
        #if DEBUG
        print("[HomeVM] Fetching UTXOs for \(allAddrs.count) addresses...")
        #endif
        var allUTXOs: [UTXO] = []
        var allTxs: [Transaction] = []
        let usingTor = plug_tor_is_running()
        let batchSize = usingTor ? 10 : 5

        // Phase 1: Fetch UTXOs only (lightweight)
        // Shuffle to break sequential query pattern (anti-correlation)
        let shuffledAddrs = allAddrs.shuffled()
        var addressesWithActivity: [String] = []
        for (i, batchStart) in stride(from: 0, to: shuffledAddrs.count, by: batchSize).enumerated() {
            if !usingTor && i > 0 { try? await Task.sleep(nanoseconds: 200_000_000) }
            let batchEnd = min(batchStart + batchSize, shuffledAddrs.count)
            let batch = Array(shuffledAddrs[batchStart..<batchEnd])

            await withTaskGroup(of: (String, [UTXO]).self) { group in
                for addr in batch {
                    group.addTask {
                        do {
                            let u = try await MempoolAPI.shared.getAddressUTXOs(address: addr.address)
                            return (addr.address, u)
                        } catch {
                            #if DEBUG
                            print("[HomeVM] API error for \(addr.address.prefix(12)): \(error.localizedDescription)")
                            #endif
                            return (addr.address, [])
                        }
                    }
                }
                for await (addr, utxos) in group {
                    allUTXOs.append(contentsOf: utxos)
                    if !utxos.isEmpty { addressesWithActivity.append(addr) }
                }
            }
        }

        // Phase 2: Fetch transactions only for addresses with UTXOs (skip empty)
        if !addressesWithActivity.isEmpty {
            #if DEBUG
            print("[HomeVM] Fetching txs for \(addressesWithActivity.count) active addresses")
            #endif
            for (i, batchStart) in stride(from: 0, to: addressesWithActivity.count, by: batchSize).enumerated() {
                if !usingTor && i > 0 { try? await Task.sleep(nanoseconds: 200_000_000) }
                let batchEnd = min(batchStart + batchSize, addressesWithActivity.count)
                let batch = Array(addressesWithActivity[batchStart..<batchEnd])

                await withTaskGroup(of: [Transaction].self) { group in
                    for addr in batch {
                        group.addTask {
                            (try? await MempoolAPI.shared.getAddressTransactions(address: addr)) ?? []
                        }
                    }
                    for await txs in group {
                        allTxs.append(contentsOf: txs)
                    }
                }
            }
        }

        // Merge new transactions with existing (preserves history for spent addresses)
        let activeAddrSet = Set(addressesWithActivity)
        var mergedTxs = transactions.filter { tx in
            !tx.vout.contains { activeAddrSet.contains($0.scriptpubkeyAddress ?? "") }
            && !tx.vin.contains { activeAddrSet.contains($0.prevout?.scriptpubkeyAddress ?? "") }
        }
        mergedTxs.append(contentsOf: allTxs)

        var seen = Set<String>()
        let dedupedTxs = mergedTxs.filter { seen.insert($0.txid).inserted }

        walletAddresses = walletAddrs
        utxos = allUTXOs
        transactions = dedupedTxs.sorted { ($0.status.blockTime ?? Int.max) > ($1.status.blockTime ?? Int.max) }
        totalBalance = allUTXOs.reduce(0) { $0 + $1.value }
        lastBalanceRefresh = Date()
        #if DEBUG
        print("[HomeVM] Balance: \(totalBalance) sats, \(allUTXOs.count) UTXOs, \(dedupedTxs.count) txs")
        #endif
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

    /// Clear all wallet data — called when Ledger disconnects
    func clearWalletData() {
        totalBalance = 0
        utxos = []
        transactions = []
        walletAddresses = []
        alerts = []
        contractBalances = [:]
        lastBalanceRefresh = nil
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
