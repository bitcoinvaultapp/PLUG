import SwiftUI

// MARK: - HomeView

struct HomeView: View {
    @ObservedObject private var vm = HomeVM.shared
    @EnvironmentObject var walletVM: WalletVM
    @ObservedObject private var ledgerState = LedgerManager.shared
    @AppStorage("balance_unit") private var balanceUnit: String = BalanceUnit.btc.rawValue

    @State private var showLedgerFromCard = false
    @State private var tipIndex = Int.random(in: 0..<42)
    @State private var showReceiveFromHome = false
    @State private var showBackupFromHome = false
    @State private var copiedAddress = ""
    @State private var showBatchSend = false
    @State private var showBumpFee = false
    @State private var showConsolidate = false
    @State private var showCrowdfund = false

    private var hasWallet: Bool {
        KeychainStore.shared.loadXpub(isTestnet: NetworkConfig.shared.isTestnet) != nil
    }

    private var ledgerConnectedNoXpub: Bool {
        ledgerState.state == .connected && !hasWallet
    }

    private var nodeConfigured: Bool {
        TorConfig.shared.isNodeConfigured
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerBar

                    if !nodeConfigured {
                        // No personal node — guide the user
                        HomeSetupNodeCard()
                    } else if hasWallet {
                        // Full dashboard
                        HomeBalanceCard(
                            totalBalance: walletVM.totalBalance,
                            btcPrice: vm.btcPrice,
                            syncError: walletVM.error,
                            scanProgress: walletVM.scanProgress,
                            scanStatus: walletVM.scanStatus,
                            balanceUnit: $balanceUnit,
                            onRetry: { Task { await walletVM.refreshUTXOs() } }
                        )
                        HomeNetworkStatsCard(
                            blockHeight: vm.blockHeight,
                            lastBlockTime: vm.lastBlockTime,
                            feeEstimate: vm.feeEstimate,
                            btcPrice: vm.btcPrice,
                            activeContracts: vm.activeContracts,
                            utxos: walletVM.utxos,
                            dustUtxos: walletVM.utxos.filter { $0.value < 546 }
                        )
                        HomeStatusSection(
                            pendingTransactions: walletVM.transactions.filter { !$0.status.confirmed },
                            alerts: vm.alerts,
                            walletAddresses: walletVM.addresses,
                            transactions: walletVM.transactions,
                            utxos: walletVM.utxos
                        )
                        HomeDailyTipCard(tipIndex: tipIndex)
                        HomeQuickActionsSection(
                            utxos: walletVM.utxos,
                            walletAddresses: walletVM.addresses,
                            transactions: walletVM.transactions,
                            showBatchSend: $showBatchSend,
                            showBumpFee: $showBumpFee,
                            showConsolidate: $showConsolidate,
                            showCrowdfund: $showCrowdfund
                        )
                        // Recent Transactions
                        if !walletVM.transactions.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Recent Transactions")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)

                                ForEach(walletVM.transactions.prefix(5)) { tx in
                                    homeTransactionRow(tx)
                                }
                            }
                        }

                        HomeRemindersSection(utxos: walletVM.utxos)
                        HomeRecentAddressesSection(
                            walletAddresses: walletVM.addresses,
                            transactions: walletVM.transactions,
                            copiedAddress: $copiedAddress
                        )

                    } else if ledgerConnectedNoXpub {
                        // Ledger connected but no xpub — auto-fetch
                        HomeFetchingWalletCard()
                            .task {
                                do {
                                    let _ = try await LedgerManager.shared.getXpub(
                                        path: [84 | 0x80000000, 0 | 0x80000000, 0 | 0x80000000]
                                    )
                                    // xpub saved → hasWallet becomes true → view re-renders to dashboard
                                    await walletVM.loadWallet()
                                } catch {
                                    #if DEBUG
                                    print("[Home] Auto xpub fetch failed: \(error)")
                                    #endif
                                }
                            }
                    } else {
                        // No wallet, no Ledger — need to connect
                        HomeConnectLedgerCard(showLedgerFromCard: $showLedgerFromCard)
                        HomeNetworkStatsCard(
                            blockHeight: vm.blockHeight,
                            lastBlockTime: vm.lastBlockTime,
                            feeEstimate: vm.feeEstimate,
                            btcPrice: vm.btcPrice,
                            activeContracts: vm.activeContracts,
                            utxos: [],
                            dustUtxos: []
                        )
                        HomeDailyTipCard(tipIndex: tipIndex)
                    }
                }
                .padding()
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                await vm.refresh()
            }
            // Initialization handled by MainTabView.bootstrap()
        }
    }

    // MARK: - Header

    private func homeTransactionRow(_ tx: Transaction) -> some View {
        let myAddresses = Set(walletVM.addresses.map(\.address))
        let isSend = tx.vin.contains { input in
            input.prevout?.scriptpubkeyAddress.map { myAddresses.contains($0) } ?? false
        }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for output in tx.vout {
            if let addr = output.scriptpubkeyAddress, myAddresses.contains(addr) { received += output.value }
        }
        for input in tx.vin {
            if let addr = input.prevout?.scriptpubkeyAddress, myAddresses.contains(addr) { sent += input.prevout?.value ?? 0 }
        }
        let amount = sent > received ? sent - received : received - sent

        // Detect address type badge
        let txBadge = homeTxBadge(tx)

        return HStack(spacing: 10) {
            Image(systemName: isSend ? "arrow.up.right" : "arrow.down.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSend ? .orange : .green)
                .frame(width: 24, height: 24)
                .background((isSend ? Color.orange : Color.green).opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(String(tx.txid.prefix(10)) + "..." + String(tx.txid.suffix(4)))
                        .font(.system(size: 11, design: .monospaced))
                    if let badge = txBadge {
                        Text(badge.label)
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(badge.color)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(badge.color.opacity(0.12), in: Capsule())
                    }
                }
                if tx.status.confirmed {
                    if let blockTime = tx.status.blockTime {
                        Text(Date(timeIntervalSince1970: TimeInterval(blockTime)), style: .relative)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("Pending")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            Text("\(isSend ? "-" : "+")\(BalanceUnit.format(amount, btcPrice: vm.btcPrice))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(isSend ? .orange : .green)
        }
        .padding(.vertical, 4)
    }

    /// Detect badge for a transaction: contract type or address type
    private func homeTxBadge(_ tx: Transaction) -> (label: String, color: Color)? {
        let contracts = ContractStore.shared.contractsForNetwork(isTestnet: false)
        let contractAddrs = Dictionary(uniqueKeysWithValues: contracts.map { ($0.address, $0) })

        // Check if any output goes to a contract address
        for output in tx.vout {
            if let addr = output.scriptpubkeyAddress, let contract = contractAddrs[addr] {
                switch contract.type {
                case .vault: return ("CLTV", .orange)
                case .inheritance: return ("CSV", .purple)
                case .htlc: return ("HTLC", .teal)
                case .channel: return ("CHANNEL", .green)
                case .pool: return ("MULTI", .blue)
                }
            }
        }
        // Check inputs too (spending from contract)
        for input in tx.vin {
            if let addr = input.prevout?.scriptpubkeyAddress, let contract = contractAddrs[addr] {
                switch contract.type {
                case .vault: return ("CLTV", .orange)
                case .inheritance: return ("CSV", .purple)
                case .htlc: return ("HTLC", .teal)
                case .channel: return ("CHANNEL", .green)
                case .pool: return ("MULTI", .blue)
                }
            }
        }

        // Address type badge from the primary output
        let destOutput = tx.vout.first { output in
            let myAddrs = Set(walletVM.addresses.map(\.address))
            guard let addr = output.scriptpubkeyAddress else { return false }
            return !myAddrs.contains(addr)
        } ?? tx.vout.first

        if let addr = destOutput?.scriptpubkeyAddress {
            if addr.hasPrefix("bc1p") || addr.hasPrefix("tb1p") { return ("P2TR", .cyan) }
            if addr.count > 55 { return ("P2WSH", .indigo) }
        }

        return nil
    }

    private var headerBar: some View {
        PlugHeader(pageName: "Home")
    }
}

// =====================================================================
// MARK: - Connect Ledger Card
// =====================================================================

private struct HomeSetupNodeCard: View {
    @ObservedObject private var torConfig = TorConfig.shared
    @ObservedObject private var torManager = TorManager.shared
    @State private var onionInput = ""
    @State private var checkStatus: NodeCheckStatus = .idle

    enum NodeCheckStatus: Equatable {
        case idle, checking, reachable(Int), unreachable
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "server.rack")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            Text("Set up your node")
                .font(.system(size: 22, weight: .semibold))

            Text("PLUG requires your own Bitcoin node.\nDeploy Bitcoin Core + Electrs on a VPS\nand paste your .onion address below.")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                TextField("abc...xyz.onion", text: $onionInput)
                    .font(.system(size: 14, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color(.systemGray6).opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                    .onChange(of: onionInput) { _ in
                        torConfig.personalNodeOnion = onionInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        checkStatus = .idle
                    }

                HStack {
                    Button {
                        testConnection()
                    } label: {
                        HStack(spacing: 6) {
                            if case .checking = checkStatus {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 12))
                            }
                            Text("Test connection")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.btcOrange, in: Capsule())
                    }
                    .disabled(onionInput.isEmpty || !torManager.isRunning || checkStatus == .checking)

                    Spacer()

                    switch checkStatus {
                    case .reachable(let height):
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Block \(height)")
                                .foregroundStyle(.green)
                        }
                        .font(.system(size: 12, weight: .medium))
                    case .unreachable:
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text("Unreachable")
                                .foregroundStyle(.red)
                        }
                        .font(.system(size: 12, weight: .medium))
                    default:
                        EmptyView()
                    }
                }
            }

            Button {
                if let url = URL(string: "https://github.com/bitcoinvaultapp/PLUG#2-deploy-your-bitcoin-node") {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("How to deploy a node")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 400)
        .onAppear { onionInput = torConfig.personalNodeOnion }
    }

    private func testConnection() {
        checkStatus = .checking
        let host = torConfig.personalNodeOnion
        Task.detached(priority: .userInitiated) {
            guard let hostC = host.cString(using: .utf8),
                  let pathC = "/blocks/tip/height".cString(using: .utf8) else {
                await MainActor.run { checkStatus = .unreachable }
                return
            }
            guard let resultPtr = plug_tor_fetch(hostC, 80, pathC) else {
                await MainActor.run { checkStatus = .unreachable }
                return
            }
            let result = String(cString: resultPtr)
            plug_tor_free_string(resultPtr)

            if let height = Int(result.trimmingCharacters(in: .whitespacesAndNewlines)) {
                await MainActor.run { checkStatus = .reachable(height) }
            } else {
                await MainActor.run { checkStatus = .unreachable }
            }
        }
    }
}

private struct HomeFetchingWalletCard: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .controlSize(.regular)
            Text("Fetching wallet...")
                .font(.system(size: 17, weight: .medium))
            Text("Reading xpub from your Ledger")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

private struct HomeConnectLedgerCard: View {
    @Binding var showLedgerFromCard: Bool

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            Text("Connect your Ledger")
                .font(.system(size: 22, weight: .semibold))

            Text("Pair via Bluetooth to get started")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)

            Button {
                showLedgerFromCard = true
            } label: {
                Text("Connect")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 10)
                    .background(Color.btcOrange, in: Capsule())
            }
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .sheet(isPresented: $showLedgerFromCard) {
            NavigationStack {
                LedgerView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showLedgerFromCard = false }
                        }
                    }
            }
        }
    }
}

// =====================================================================
// MARK: - Balance Card
// =====================================================================

private struct HomeBalanceCard: View {
    let totalBalance: UInt64
    let btcPrice: Double
    let syncError: String?
    let scanProgress: Double
    let scanStatus: String?
    @Binding var balanceUnit: String
    var onRetry: () -> Void

    private var currentUnit: BalanceUnit {
        BalanceUnit(rawValue: balanceUnit) ?? .btc
    }

    private func formatBalance(_ sats: UInt64) -> (value: String, unit: String) {
        BalanceUnit.formatSplit(sats, btcPrice: btcPrice)
    }

    var body: some View {
        let display = formatBalance(totalBalance)

        VStack(spacing: 8) {
            Text("Total Balance")
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                balanceUnit = currentUnit.next.rawValue
            } label: {
                VStack(spacing: 2) {
                    Text(display.value)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                    Text(display.unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            // Scan progress bar
            if let status = scanStatus, scanProgress > 0 && scanProgress < 1 {
                VStack(spacing: 6) {
                    ProgressView(value: scanProgress)
                        .tint(.orange)
                        .scaleEffect(y: 0.6, anchor: .center)
                        .padding(.horizontal, 40)

                    Text(status)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: scanProgress)
            }

            if let syncErr = syncError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Text(syncErr)
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.8))
                    Spacer()
                    Button {
                        onRetry()
                    } label: {
                        Text("Retry")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

// =====================================================================
// MARK: - Network Stats Card
// =====================================================================

private struct HomeNetworkStatsCard: View {
    let blockHeight: Int
    let lastBlockTime: Int
    let feeEstimate: FeeEstimate?
    let btcPrice: Double
    let activeContracts: [Contract]
    let utxos: [UTXO]
    let dustUtxos: [UTXO]

    var body: some View {
        VStack(spacing: 10) {
            // Block height + live timer
            BlockTimerRow(blockHeight: blockHeight, lastBlockTime: lastBlockTime)

            // Fees — 3 tiers in one line
            if let fee = feeEstimate {
                HStack(spacing: 8) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("Fee")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    HStack(spacing: 0) {
                        feeChipInline("\(fee.fastestFee)", color: .red)
                        Text(" · ")
                            .font(.system(size: 9))
                            .foregroundStyle(.quaternary)
                        feeChipInline("\(fee.halfHourFee)", color: .orange)
                        Text(" · ")
                            .font(.system(size: 9))
                            .foregroundStyle(.quaternary)
                        feeChipInline("\(fee.economyFee)", color: .green)
                    }
                    Text("sat/vB")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
            }

            // BTC price
            if btcPrice > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "dollarsign.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("BTC")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(String(format: "$%,.0f", btcPrice))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                }
            }

            // Next halving
            if blockHeight > 0 {
                let nextHalving = ((blockHeight / 210_000) + 1) * 210_000
                let remaining = nextHalving - blockHeight
                let estimatedDays = remaining * 10 / 60 / 24
                let years = estimatedDays / 365
                let months = (estimatedDays % 365) / 30

                HStack(spacing: 8) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("Halving")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(BalanceUnit.formatSats(UInt64(remaining))) blocks")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(years > 0 ? "~\(years)y \(months)m" : "~\(months)m")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.quaternary)
                }
            }

            // Fee insight
            if let fee = feeEstimate {
                let level = fee.fastestFee
                HStack(spacing: 8) {
                    Circle()
                        .fill(level < 10 ? Color.green : level < 50 ? Color.orange : Color.red)
                        .frame(width: 6, height: 6)
                    Text(level < 10 ? "Good time to send" : level < 50 ? "Moderate fees" : "Network busy")
                        .font(.system(size: 11))
                        .foregroundStyle(level < 10 ? .green : level < 50 ? .orange : .red)
                    Spacer()
                }
            }

            // Contract activity
            if !activeContracts.isEmpty {
                let counts = contractCounts
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(counts)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            // UTXO health
            if !utxos.isEmpty {
                let dustCount = dustUtxos.count
                HStack(spacing: 8) {
                    Image(systemName: "circle.grid.3x3.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("\(utxos.count) UTXOs")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if dustCount > 0 {
                        Text("· \(dustCount) dust")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: Helpers

    private var contractCounts: String {
        var parts: [String] = []
        let vaults = activeContracts.filter { $0.type == .vault }.count
        let inherits = activeContracts.filter { $0.type == .inheritance }.count
        let htlcs = activeContracts.filter { $0.type == .htlc }.count
        let channels = activeContracts.filter { $0.type == .channel }.count
        let pools = activeContracts.filter { $0.type == .pool }.count
        if vaults > 0 { parts.append("\(vaults) CLTV") }
        if inherits > 0 { parts.append("\(inherits) CSV") }
        if htlcs > 0 { parts.append("\(htlcs) HTLC") }
        if channels > 0 { parts.append("\(channels) P2MS") }
        if pools > 0 { parts.append("\(pools) MULTI") }
        return parts.joined(separator: " · ")
    }

    private func feeChipInline(_ value: String, color: Color) -> some View {
        Text(value)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
    }
}

// =====================================================================
// MARK: - Status Section
// =====================================================================

private struct HomeStatusSection: View {
    let pendingTransactions: [Transaction]
    let alerts: [DashboardAlert]
    let walletAddresses: [WalletAddress]
    let transactions: [Transaction]
    let utxos: [UTXO]

    var body: some View {
        let pendingCount = pendingTransactions.count
        let exposed = exposedAddressFunds

        let unlockedVaults = alerts.filter {
            if case .vaultUnlocked = $0 { return true }; return false
        }
        let inheritanceAlerts = alerts.filter {
            if case .inheritanceApproaching = $0 { return true }; return false
        }

        VStack(spacing: 0) {
            // Exposed addresses
            if exposed.count > 0 {
                if exposed.count == 1 {
                    statusRow(icon: "exclamationmark.shield.fill", iconColor: .red,
                              title: "1 address exposed", subtitle: "Public key on-chain · move funds")
                } else {
                    statusGroup(
                        icon: "exclamationmark.shield.fill", iconColor: .red,
                        title: "\(exposed.count) addresses exposed",
                        subtitle: "Public key on-chain · move funds",
                        details: exposedAddressDetails
                    )
                }
                Divider().padding(.leading, 40).opacity(0.2)
            }

            // Unlocked vaults
            if !unlockedVaults.isEmpty {
                if unlockedVaults.count == 1, case .vaultUnlocked(_, let name) = unlockedVaults[0] {
                    statusRow(icon: "lock.open.fill", iconColor: .green,
                              title: "Vault \"\(name)\" unlocked", subtitle: "Ready to spend")
                } else {
                    statusGroup(
                        icon: "lock.open.fill", iconColor: .green,
                        title: "\(unlockedVaults.count) vaults unlocked",
                        subtitle: "Ready to spend",
                        details: unlockedVaults.map { alert in
                            if case .vaultUnlocked(_, let name) = alert { return name }
                            return ""
                        }
                    )
                }
                Divider().padding(.leading, 40).opacity(0.2)
            }

            // Inheritance approaching
            if !inheritanceAlerts.isEmpty {
                if inheritanceAlerts.count == 1, case .inheritanceApproaching(_, let name, let blocks) = inheritanceAlerts[0] {
                    statusRow(icon: "clock.badge.exclamationmark.fill", iconColor: .orange,
                              title: "Inheritance \"\(name)\"", subtitle: "\(blocks) blocks remaining")
                } else {
                    statusGroup(
                        icon: "clock.badge.exclamationmark.fill", iconColor: .orange,
                        title: "\(inheritanceAlerts.count) inheritances approaching",
                        subtitle: "Action needed",
                        details: inheritanceAlerts.map { alert in
                            if case .inheritanceApproaching(_, let name, let blocks) = alert {
                                return "\(name) · \(blocks) blocks"
                            }
                            return ""
                        }
                    )
                }
                Divider().padding(.leading, 40).opacity(0.2)
            }

            // Pending transactions — tap to view on mempool.space
            if pendingCount > 0 {
                if let firstPending = pendingTransactions.first {
                    Button {
                        if let url = URL(string: "https://mempool.space/tx/\(firstPending.txid)") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        statusRow(icon: "clock.fill", iconColor: .orange,
                                  title: "\(pendingCount) tx pending", subtitle: "Tap to view on mempool.space")
                    }
                    .buttonStyle(.plain)
                }
                Divider().padding(.leading, 40).opacity(0.2)
            }
        }
    }

    // MARK: Status Helpers

    private func statusGroup(icon: String, iconColor: Color, title: String, subtitle: String, details: [String]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(details, id: \.self) { detail in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(iconColor.opacity(0.5))
                            .frame(width: 4, height: 4)
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 32)
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(iconColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .tint(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var exposedAddressDetails: [String] {
        let knownAddresses = Set(walletAddresses.map { $0.address })
        var spentFrom = Set<String>()
        for tx in transactions {
            for input in tx.vin {
                if let addr = input.prevout?.scriptpubkeyAddress, knownAddresses.contains(addr) {
                    spentFrom.insert(addr)
                }
            }
        }
        return spentFrom.compactMap { addr in
            let bal = utxos.filter { $0.address == addr }.reduce(UInt64(0)) { $0 + $1.value }
            guard bal > 0 else { return nil }
            return String(addr.prefix(10)) + "..." + String(addr.suffix(4))
        }
    }

    private var exposedAddressFunds: (count: Int, totalSats: UInt64) {
        let knownAddresses = Set(walletAddresses.map { $0.address })

        var spentFrom = Set<String>()
        for tx in transactions {
            for input in tx.vin {
                if let addr = input.prevout?.scriptpubkeyAddress, knownAddresses.contains(addr) {
                    spentFrom.insert(addr)
                }
            }
        }

        var count = 0
        var total: UInt64 = 0
        for addr in spentFrom {
            let balance = utxos.filter { $0.address == addr }.reduce(UInt64(0)) { $0 + $1.value }
            if balance > 0 {
                count += 1
                total += balance
            }
        }

        return (count, total)
    }

    private func statusRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(iconColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.gray)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.gray.opacity(0.7))
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// =====================================================================
// MARK: - Daily Bitcoin Tip
// =====================================================================

private struct HomeDailyTipCard: View {
    let tipIndex: Int

    private static let tips: [(String, String, Color)] = [
        ("lock.fill", "Never reuse a Bitcoin address. Each should be used only once for privacy.", .green),
        ("key.fill", "Your seed phrase is the master key. Store it offline in physical form, never digitally.", .orange),
        ("eye.slash.fill", "Use coin control to avoid mixing KYC and non-KYC UTXOs in the same transaction.", .purple),
        ("checkmark.shield.fill", "Always verify the receive address on your Ledger screen before sending.", .blue),
        ("clock.fill", "Wait for 6 confirmations before considering a large payment final.", .orange),
        ("antenna.radiowaves.left.and.right", "Use Tor to hide your IP when querying the blockchain.", .teal),
        ("exclamationmark.triangle.fill", "Dust outputs (< 546 sats) cost more in fees to spend than they're worth.", .yellow),
        ("arrow.triangle.2.circlepath", "CoinJoin mixes your transaction with others. No trust required.", .purple),
        ("bitcoinsign.circle.fill", "Bitcoin's supply is capped at 21 million. No one can inflate it.", .orange),
        ("doc.text.fill", "Label your transactions. Future you will thank present you.", .blue),
        ("person.2.fill", "Multisig requires M-of-N signatures. No single point of failure.", .teal),
        ("timer", "OP_CHECKLOCKTIMEVERIFY locks funds until a specific block height.", .orange),
        ("wallet.pass", "A wallet holds keys, not coins. Your bitcoins live on the blockchain.", .cyan),
        ("arrow.left.arrow.right", "HD wallets generate unlimited addresses from a single seed phrase.", .blue),
        ("sum", "Fees = Inputs - Outputs. Forgot change? You tipped the miner the difference.", .red),
        ("arrow.merge", "Consolidate small UTXOs when fees are low to save on future costs.", .green),
        ("hourglass", "Locktime schedules transactions and protects against fee-sniping attacks.", .teal),
        ("curlybraces", "Bitcoin Script has no loops by design. This prevents denial-of-service attacks.", .purple),
        ("seal.fill", "Taproot combines key-path and script-path spending for better privacy.", .mint),
        ("signature", "Digital signatures prove authorization without revealing your private key.", .blue),
        ("checkmark.rectangle", "Schnorr signatures are smaller and faster than legacy ECDSA.", .green),
        ("shield.lefthalf.filled", "Hardware wallets isolate signing from online threats like malware.", .red),
        ("arrow.triangle.swap", "RBF (Replace-by-Fee) lets you bump fees on stuck transactions.", .purple),
        ("chart.line.uptrend.xyaxis", "Miners prioritize transactions with the best fee-per-vbyte ratio.", .orange),
        ("timer", "Low fees? Send on weekends or early mornings for cheaper transactions.", .teal),
        ("exclamationmark.circle", "Overpaying fees is permanent. Always check the fee rate before sending.", .red),
        ("arrow.up.arrow.down", "CPFP lets receivers fee-bump unconfirmed transactions they receive.", .green),
        ("network", "Bitcoin is peer-to-peer. No servers, no central authority, no single point of failure.", .blue),
        ("globe", "Nodes connect to random peers to resist censorship and sybil attacks.", .cyan),
        ("lock.shield", "Tor SOCKS5 proxy hides your IP from the API for better privacy.", .purple),
        ("cube.fill", "6+ confirmations make transaction reversals astronomically expensive.", .blue),
        ("square.stack.3d.up.fill", "Testnet is for testing. Always verify on testnet before using mainnet.", .orange),
        ("lock.fill", "Cold storage (offline signing) is the safest technique for large holdings.", .red),
        ("gear", "Block rewards halve every 210,000 blocks. Eventually only fees incentivize miners.", .orange),
        ("key.horizontal", "Store multisig keys in separate locations controlled by different people.", .purple),
        ("dollarsign.circle.fill", "Your keys, your coins. No seed phrase = no recovery. Unlike banks.", .red),
        ("person.2", "Share recovery details with a trusted person for inheritance planning.", .mint),
        ("exclamationmark.shield.fill", "Keys on always-online devices can be stolen. Use hardware wallets.", .red),
        ("lock.square.stack.fill", "Keep < 5% as mobile pocket change. The rest in cold storage.", .orange),
        ("arrow.turn.up.left", "Back up scripts too, not just keys. Complex contracts need witness data to spend.", .orange),
        ("checkmark.diamond", "Test your backups. If you secure too well, you might lock yourself out.", .yellow),
        ("person.3.fill", "For large amounts, use multisig held by different people in different locations.", .green),
    ]

    var body: some View {
        let tip = Self.tips[tipIndex % Self.tips.count]

        VStack(alignment: .leading, spacing: 8) {
            Text("TIP")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.quaternary)

            HStack(spacing: 10) {
                Image(systemName: tip.0)
                    .font(.system(size: 14))
                    .foregroundStyle(tip.2)
                    .frame(width: 20)
                Text(tip.1)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

// =====================================================================
// MARK: - Quick Actions Section
// =====================================================================

private struct HomeQuickActionsSection: View {
    let utxos: [UTXO]
    let walletAddresses: [WalletAddress]
    let transactions: [Transaction]
    @Binding var showBatchSend: Bool
    @Binding var showBumpFee: Bool
    @Binding var showConsolidate: Bool
    @Binding var showCrowdfund: Bool

    var body: some View {
        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ]

        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.15)

            Text("TOOLS")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.quaternary)

            LazyVGrid(columns: columns, spacing: 10) {
                toolCard(icon: "arrow.left.arrow.right", iconColor: .green, title: "Batch Send", subtitle: "Multi-recipient") {
                    showBatchSend = true
                }

                toolCard(icon: "bolt.fill", iconColor: .yellow, title: "Bump Fee", subtitle: "RBF speed-up") {
                    showBumpFee = true
                }

                NavigationLink {
                    UTXOManagerPage(utxos: utxos, walletAddresses: walletAddresses, transactions: transactions)
                } label: {
                    toolCardLabel(icon: "square.grid.2x2.fill", iconColor: .purple, title: "UTXOs", subtitle: "Freeze & manage")
                }

                toolCard(icon: "arrow.triangle.merge", iconColor: .orange, title: "Consolidate", subtitle: "Merge UTXOs") {
                    showConsolidate = true
                }

                NavigationLink {
                    OpReturnView()
                } label: {
                    toolCardLabel(icon: "curlybraces", iconColor: .green, title: "OP_RETURN", subtitle: "On-chain data")
                }

                toolCard(icon: "person.3.fill", iconColor: .teal, title: "Crowdfund", subtitle: "ANYONECANPAY") {
                    showCrowdfund = true
                }
            }
        }
        .sheet(isPresented: $showBatchSend) { comingSoonSheet("Batch Send") }
        .sheet(isPresented: $showBumpFee) { comingSoonSheet("Bump Fee") }
        .sheet(isPresented: $showConsolidate) { comingSoonSheet("Consolidate") }
        .sheet(isPresented: $showCrowdfund) { comingSoonSheet("Crowdfund") }
    }

    // MARK: Quick Action Helpers

    private func toolCard(icon: String, iconColor: Color, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            action()
        } label: {
            toolCardLabel(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle)
        }
        .buttonStyle(WalletButtonStyle(color: iconColor))
    }

    private func toolCardLabel(icon: String, iconColor: Color, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 34, height: 34)
                .background(iconColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))

            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.systemGray6).opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(.systemGray4).opacity(0.15), lineWidth: 0.5)
        )
    }

    private func comingSoonSheet(_ title: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "hammer.fill")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
            Text("Coming soon")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .presentationDetents([.medium])
    }
}

// =====================================================================
// MARK: - Reminders Section
// =====================================================================

private struct HomeRemindersSection: View {
    let utxos: [UTXO]
    @ObservedObject private var contractStore = ContractStore.shared
    @ObservedObject private var frozenStore = FrozenUTXOStore.shared

    var body: some View {
        let frozenUtxos = utxos.filter { FrozenUTXOStore.shared.isFrozen(outpoint: $0.outpoint) }
        let frozenCount = frozenUtxos.count
        let frozenSats = frozenUtxos.reduce(UInt64(0)) { $0 + $1.value }
        let contracts = ContractStore.shared.contractsForNetwork(isTestnet: NetworkConfig.shared.isTestnet)
        let lastBackup = UserDefaults.standard.object(forKey: "last_backup_date") as? Date
        let needsBackup = !contracts.isEmpty && (lastBackup == nil || Date().timeIntervalSince(lastBackup!) > 7 * 24 * 3600)

        Group {
            if needsBackup || frozenCount > 0 || UserDefaults.standard.string(forKey: "last_read_chapter") != nil {
                VStack(spacing: 0) {
                    // Backup alert
                    if needsBackup {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                            Text("\(contracts.count) contract\(contracts.count > 1 ? "s" : "") need backup")
                                .font(.system(size: 11))
                                .foregroundStyle(.red.opacity(0.8))
                            Spacer()
                            NavigationLink {
                                BackupView()
                            } label: {
                                Text("Backup")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .overlay(Capsule().strokeBorder(Color.orange.opacity(0.3), lineWidth: 1))
                            }
                        }
                        .padding(.vertical, 6)
                    }

                    // Frozen UTXOs
                    if frozenCount > 0 {
                        HStack(spacing: 8) {
                            Image(systemName: "snowflake")
                                .font(.system(size: 12))
                                .foregroundStyle(.cyan)
                            Text("\(frozenCount) UTXO\(frozenCount > 1 ? "s" : "") frozen")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text("· \(BalanceUnit.format(frozenSats))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }

                    // Learn shortcut
                    if let lastChapter = UserDefaults.standard.string(forKey: "last_read_chapter") {
                        HStack(spacing: 8) {
                            Image(systemName: "book.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.blue)
                            Text("Continue: \(lastChapter)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.quaternary)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }
}

// =====================================================================
// MARK: - Recent Addresses Section
// =====================================================================

private struct HomeRecentAddressesSection: View {
    let walletAddresses: [WalletAddress]
    let transactions: [Transaction]
    @Binding var copiedAddress: String

    var body: some View {
        let recent = recentSentAddresses

        Group {
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RECENT")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.quaternary)

                    ForEach(recent, id: \.address) { item in
                        Button {
                            UIPasteboard.general.string = item.address
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            copiedAddress = item.address
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedAddress = "" }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: copiedAddress == item.address ? "checkmark" : "arrow.up.right")
                                    .font(.system(size: 9))
                                    .foregroundStyle(copiedAddress == item.address ? Color.green : Color.gray)
                                    .frame(width: 14)
                                Text(String(item.address.prefix(12)) + "..." + String(item.address.suffix(4)))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(item.date, style: .relative)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.quaternary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private var recentSentAddresses: [(address: String, date: Date)] {
        let knownAddresses = Set(walletAddresses.map { $0.address })
        var seen = Set<String>()
        var results: [(address: String, date: Date)] = []

        for tx in transactions {
            let fromUs = tx.vin.contains { input in
                if let addr = input.prevout?.scriptpubkeyAddress { return knownAddresses.contains(addr) }
                return false
            }
            guard fromUs else { continue }

            for output in tx.vout {
                if let addr = output.scriptpubkeyAddress, !knownAddresses.contains(addr), !seen.contains(addr) {
                    seen.insert(addr)
                    let date = tx.status.blockTime.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
                    results.append((address: addr, date: date))
                }
            }

            if results.count >= 5 { break }
        }

        return results
    }
}

// =====================================================================
// MARK: - Receive Sheet (from Home quick action)
// =====================================================================

struct ReceiveSheetFromHome: View {
    @State private var address: String = ""
    @State private var copied = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            if !address.isEmpty {
                // QR
                if let qr = generateQR(from: address) {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 180, height: 180)
                        .colorInvert()
                }

                // Address
                Text(address)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal)

                // Copy
                Button {
                    UIPasteboard.general.string = address
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    HStack {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy Address")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(copied ? .white : .green)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(copied ? Color.green : Color.green.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                ProgressView()
                Text("Deriving address...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .navigationTitle("Receive")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { deriveAddress() }
    }

    private func deriveAddress() {
        let isTest = NetworkConfig.shared.isTestnet
        guard let xpubStr = KeychainStore.shared.loadXpub(isTestnet: isTest),
              let xpub = ExtendedPublicKey.fromBase58(xpubStr) else { return }
        let addrs = AddressDerivation.deriveAddresses(xpub: xpub, change: 0, startIndex: 0, count: 1, isTestnet: isTest)
        address = addrs.first?.address ?? ""
    }

    private func generateQR(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// =====================================================================
// MARK: - Block Timer Row (live seconds counter)
// =====================================================================

struct BlockTimerRow: View {
    let blockHeight: Int
    let lastBlockTime: Int
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let elapsed = lastBlockTime > 0 ? Int(now.timeIntervalSince1970) - lastBlockTime : 0
        let mins = elapsed / 60
        let secs = elapsed % 60
        let isLate = elapsed > 1200

        HStack(spacing: 8) {
            Circle()
                .fill(isLate ? Color.orange : Color.green)
                .frame(width: 6, height: 6)
            Text("Block")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Text("\(blockHeight)")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
            if elapsed > 0 {
                Text("\(mins)m \(String(format: "%02d", secs))s")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isLate ? Color.orange : Color.gray)
            }
        }
        .onReceive(timer) { now = $0 }
    }
}

// =====================================================================
// MARK: - Bitcoin Plug Logo (vector, no background, 3D)
// =====================================================================

struct BitcoinPlugLogo: View {
    var body: some View {
        ZStack {
            // Shadow
            BitcoinBShape()
                .fill(Color(red: 0.55, green: 0.32, blue: 0.03))
                .offset(x: 0.6, y: 1.0)
            // Body gradient
            BitcoinBShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.75, blue: 0.28),
                            Color(red: 0.969, green: 0.576, blue: 0.102),
                            Color(red: 0.78, green: 0.42, blue: 0.04)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            // Highlight
            BitcoinBShape()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.3), Color.clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
        }
    }
}

/// The B shape with two vertical prongs -- drawn as a Path
struct BitcoinBShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var p = Path()

        // Two vertical prongs on top
        let prongW = w * 0.09
        let prongH = h * 0.12

        // Left prong
        p.addRect(CGRect(x: w * 0.30, y: 0, width: prongW, height: prongH))
        // Right prong
        p.addRect(CGRect(x: w * 0.55, y: 0, width: prongW, height: prongH))

        // Two vertical prongs on bottom
        p.addRect(CGRect(x: w * 0.30, y: h - prongH, width: prongW, height: prongH))
        p.addRect(CGRect(x: w * 0.55, y: h - prongH, width: prongW, height: prongH))

        // Vertical bar (left side of B)
        let barX = w * 0.18
        let barW = w * 0.14
        let barTop = h * 0.10
        let barBot = h * 0.90
        p.addRect(CGRect(x: barX, y: barTop, width: barW, height: barBot - barTop))

        // Upper bump of B
        let upperTop = h * 0.10
        let upperBot = h * 0.48
        let upperRight = w * 0.78

        p.move(to: CGPoint(x: barX + barW, y: upperTop))
        p.addLine(to: CGPoint(x: w * 0.62, y: upperTop))
        p.addQuadCurve(
            to: CGPoint(x: w * 0.62, y: upperBot),
            control: CGPoint(x: upperRight, y: (upperTop + upperBot) / 2)
        )
        p.addLine(to: CGPoint(x: barX + barW, y: upperBot))
        p.closeSubpath()

        // Lower bump of B (wider)
        let lowerTop = h * 0.52
        let lowerBot = h * 0.90
        let lowerRight = w * 0.85

        p.move(to: CGPoint(x: barX + barW, y: lowerTop))
        p.addLine(to: CGPoint(x: w * 0.65, y: lowerTop))
        p.addQuadCurve(
            to: CGPoint(x: w * 0.65, y: lowerBot),
            control: CGPoint(x: lowerRight, y: (lowerTop + lowerBot) / 2)
        )
        p.addLine(to: CGPoint(x: barX + barW, y: lowerBot))
        p.closeSubpath()

        // Horizontal bars
        let hBarH = h * 0.06
        p.addRect(CGRect(x: barX, y: upperTop, width: w * 0.50, height: hBarH))
        p.addRect(CGRect(x: barX, y: upperBot - hBarH / 2, width: w * 0.48, height: hBarH))
        p.addRect(CGRect(x: barX, y: lowerBot - hBarH, width: w * 0.52, height: hBarH))

        return p
    }
}
