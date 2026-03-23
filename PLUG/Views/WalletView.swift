import SwiftUI
import CoreImage.CIFilterBuiltins

struct WalletView: View {
    @EnvironmentObject var vm: WalletVM
    @ObservedObject private var ledger = LedgerManager.shared
    @ObservedObject private var contractStore = ContractStore.shared
    @State private var showSend = false
    @State private var showReceive = false
    @State private var showCoinJoin = false
    @State private var showSwap = false
    @State private var navigateToSwap = false

    @AppStorage("balance_unit") private var balanceUnit: String = BalanceUnit.btc.rawValue

    private var currentUnit: BalanceUnit {
        BalanceUnit(rawValue: balanceUnit) ?? .btc
    }

    private var formattedBalance: String {
        switch currentUnit {
        case .btc:
            let btc = Double(vm.totalBalance) / 100_000_000
            return String(format: "%.8f", btc)
        case .sats:
            return BalanceUnit.formatSats(vm.totalBalance)
        case .usd:
            let btc = Double(vm.totalBalance) / 100_000_000
            let usd = btc * vm.btcPrice
            return vm.btcPrice > 0 ? String(format: "%.2f", usd) : "--"
        }
    }

    private var balanceUnitLabel: String {
        switch currentUnit {
        case .sats: return "sats"
        case .btc: return "BTC"
        case .usd: return "USD"
        }
    }

    private func formatAmount(_ sats: UInt64) -> String {
        BalanceUnit.format(sats, btcPrice: vm.btcPrice)
    }
    @State private var selectedTx: Transaction?
    @State private var labelText: String = ""

    private var isConnected: Bool { ledger.state == .connected }

    var body: some View {
        NavigationStack {
            Group {
                if !vm.hasWallet {
                    noWalletView
                } else {
                    walletContent
                }
            }
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                await vm.refreshMetadata()
            }
            .task { await vm.loadWallet() }
            .navigationDestination(isPresented: $showSend) { sendPage }
            .navigationDestination(isPresented: $showReceive) { receivePage }
            .navigationDestination(isPresented: $showCoinJoin) {
                CoinJoinView().environmentObject(vm)
            }
            .navigationDestination(isPresented: $navigateToSwap) {
                AtomicSwapView()
            }
        }
    }

    // MARK: - No wallet

    @State private var showLedger = false

    private var noWalletView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "wave.3.right")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            VStack(spacing: 6) {
                Text("Connect your Ledger")
                    .font(.system(size: 18, weight: .semibold))
                Text("Pair via Bluetooth to view your wallet.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Button {
                showLedger = true
            } label: {
                Text("Connect")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: 200)
                    .padding(.vertical, 12)
                    .background(Color.btcOrange, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showLedger) {
            NavigationStack {
                LedgerView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showLedger = false }
                        }
                    }
            }
        }
    }

    // MARK: - Wallet content

    private typealias AddrItem = (address: WalletAddress, balance: UInt64, utxoCount: Int, status: WalletAddress.Status)

    private var allReceivingAddresses: [AddrItem] {
        let receiving = vm.addresses.filter { !$0.isChange }
        return receiving.compactMap { addr in
            let addrUtxos = vm.utxos.filter { $0.address == addr.address }
            let status = vm.addressStatus(for: addr.address)
            guard status != .fresh else { return nil }
            let balance = addrUtxos.reduce(0 as UInt64) { $0 + $1.value }
            return (address: addr, balance: balance, utxoCount: addrUtxos.count, status: status)
        }
        .sorted { $0.address.index < $1.address.index }
    }

    /// Active receiving (funded only)
    private var activeAddresses: [AddrItem] {
        allReceivingAddresses.filter { $0.status == .funded }
    }

    /// Archived receiving (used/retired)
    private var archivedAddresses: [AddrItem] {
        allReceivingAddresses.filter { $0.status == .used }
    }

    private var allChangeAddresses: [AddrItem] {
        let change = vm.addresses.filter { $0.isChange }
        return change.compactMap { addr in
            let addrUtxos = vm.utxos.filter { $0.address == addr.address }
            let status = vm.addressStatus(for: addr.address)
            guard status != .fresh else { return nil }
            let balance = addrUtxos.reduce(0 as UInt64) { $0 + $1.value }
            return (address: addr, balance: balance, utxoCount: addrUtxos.count, status: status)
        }
        .sorted { $0.address.index < $1.address.index }
    }

    /// Active change (funded only)
    private var activeChangeAddresses: [AddrItem] {
        allChangeAddresses.filter { $0.status == .funded }
    }

    /// Archived change (used/retired)
    private var archivedChangeAddresses: [AddrItem] {
        allChangeAddresses.filter { $0.status == .used }
    }

    @State private var selectedAddress: WalletAddress?

    private var walletContent: some View {
        List {
            PlugHeader(pageName: "Wallet")
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            // Balance
            Section {
                VStack(spacing: 12) {
                    // Tappable balance
                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        balanceUnit = currentUnit.next.rawValue
                    } label: {
                        VStack(spacing: 2) {
                            Text(formattedBalance)
                                .font(.system(size: 34, weight: .bold, design: .monospaced))
                                .foregroundStyle(.primary)
                            HStack(spacing: 3) {
                                Text(balanceUnitLabel)
                                    .font(.system(size: 11, weight: .medium))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 7, weight: .semibold))
                            }
                            .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    if vm.unconfirmedBalance > 0 {
                        HStack(spacing: 10) {
                            Label("\(vm.confirmedBalance)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Label("\(vm.unconfirmedBalance)", systemImage: "clock.fill")
                                .foregroundStyle(.orange)
                        }
                        .font(.system(size: 11, design: .monospaced))
                    }

                    if let syncErr = vm.error {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                            Text(syncErr)
                                .font(.system(size: 11))
                                .foregroundStyle(.red.opacity(0.8))
                            Spacer()
                            Button {
                                Task { await vm.refreshUTXOs() }
                            } label: {
                                Text("Retry")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Scan progress bar
                    if let status = vm.scanStatus, vm.scanProgress > 0 && vm.scanProgress < 1 {
                        VStack(spacing: 6) {
                            ProgressView(value: vm.scanProgress)
                                .tint(.orange)
                                .scaleEffect(y: 0.6, anchor: .center)
                                .padding(.horizontal, 20)

                            Text(status)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.3), value: vm.scanProgress)
                    }

                    // Current receive address
                    if !vm.currentReceiveAddress.isEmpty {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 5, height: 5)
                            Text("#\(vm.currentReceiveIndex)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.btcOrange)
                            Text(String(vm.currentReceiveAddress.prefix(10)) + "..." + String(vm.currentReceiveAddress.suffix(6)))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.quaternary)
                        }
                    }

                    // Action buttons
                    Divider().opacity(0.3).padding(.bottom, 12)
                    HStack(spacing: 0) {
                        // Actions
                        walletActionButton(
                            title: "Send",
                            icon: "arrow.up",
                            color: Color.btcOrange,
                            iconSize: 20
                        ) { showSend = true }

                        walletActionButton(
                            title: "Receive",
                            icon: "arrow.down",
                            color: .green,
                            iconSize: 20
                        ) { showReceive = true }

                        // Divider vertical
                        Rectangle()
                            .fill(.secondary.opacity(0.15))
                            .frame(width: 1, height: 50)

                        // Marketplace
                        walletActionButton(
                            title: "Mix",
                            icon: "arrow.triangle.2.circlepath",
                            color: .purple,
                            iconSize: 18,
                            badge: "P2P"
                        ) { showCoinJoin = true }

                        walletActionButton(
                            title: "Swap",
                            icon: "arrow.triangle.swap",
                            color: .cyan,
                            iconSize: 18,
                            badge: "P2P"
                        ) { navigateToSwap = true }
                    }
                    Divider().opacity(0.3).padding(.top, 12)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)

            // Network fees removed — available in Home tab

            // UTXO health alerts
            if !vm.dustUtxos.isEmpty || vm.unconfirmedCount > 5 {
                Section("Alerts") {
                    if !vm.dustUtxos.isEmpty {
                        Label("\(vm.dustUtxos.count) dust UTXO\(vm.dustUtxos.count == 1 ? "" : "s") (< 546 sats) — uneconomical to spend",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if vm.unconfirmedCount > 5 {
                        Label("Transaction pinning risk — \(vm.unconfirmedCount) unconfirmed UTXOs",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            // Addresses (active receiving + active change + archive)
            WalletAddressesSection(
                activeAddresses: activeAddresses,
                activeChangeAddresses: activeChangeAddresses,
                archivedAddresses: archivedAddresses,
                archivedChangeAddresses: archivedChangeAddresses,
                formatAmount: formatAmount,
                selectedAddress: $selectedAddress
            )

            // UTXOs
            WalletUTXOsSection(
                utxos: filteredUtxos,
                formatAmount: formatAmount
            )

            // Transactions
            WalletTransactionsSection(
                formatAmount: formatAmount,
                selectedTx: $selectedTx,
                onBumpFee: { tx in
                    vm.bumpFee(transaction: tx)
                    showSend = true
                }
            )
        }
        .sheet(item: $selectedAddress) { addr in
            addressDetailSheet(addr)
        }
    }

    private var filteredUtxos: [UTXO] {
        if let selected = selectedAddress {
            return vm.utxos.filter { $0.address == selected.address }
        }
        return vm.utxos
    }

    // MARK: - Fee Chip

    // MARK: - Wallet Action Button (Apple-style)

    private func walletActionButton(title: String, icon: String, color: Color, iconSize: CGFloat = 20, badge: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 42, height: 42)
                    .overlay(
                        Circle()
                            .strokeBorder(color.opacity(0.45), lineWidth: 1.8)
                    )
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(badge ?? " ")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(badge != nil ? color.opacity(0.6) : .clear)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(WalletButtonStyle(color: color))
    }

    private func feeChip(_ label: String, rate: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(rate)")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
            Text("sat/vB")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Address Detail Sheet

    private func addressDetailSheet(_ addr: WalletAddress) -> some View {
        let addrUtxos = vm.utxos.filter { $0.address == addr.address }
        let balance = addrUtxos.reduce(0 as UInt64) { $0 + $1.value }

        return NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        Text(formatAmount(balance))
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                        Text(addr.address)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)

                        Button {
                            UIPasteboard.general.string = addr.address
                        } label: {
                            Label("Copy Address", systemImage: "doc.on.doc")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section("Details") {
                    LabeledContent("Index", value: "#\(addr.index)")
                    LabeledContent("Type", value: addr.isChange ? "Change" : "Receiving")
                    LabeledContent("UTXOs", value: "\(addrUtxos.count)")
                }

                Section("UTXOs") {
                    ForEach(addrUtxos) { utxo in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(utxo.txid.prefix(12)) + ":\(utxo.vout)")
                                    .font(.system(.caption2, design: .monospaced))
                                Text(utxo.status.confirmed ? "Confirmed" : "Unconfirmed")
                                    .font(.caption2)
                                    .foregroundStyle(utxo.status.confirmed ? .green : .orange)
                            }
                            Spacer()
                            Text(formatAmount(utxo.value))
                                .font(.caption.weight(.medium).monospacedDigit())
                        }
                    }
                }
            }
            .navigationTitle("Address #\(addr.index)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { selectedAddress = nil }
                }
            }
        }
    }

    // MARK: - UTXO row (used by Address Detail Sheet)

    // MARK: - Send sheet

    private var sendPage: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Hero
                VStack(spacing: 6) {
                    Image(systemName: "paperplane.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.btcOrange, Color.btcOrange.opacity(0.5))
                    Text("Send bitcoin to any address. Select UTXOs manually for full coin control.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 8)

                // Amount card
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("You send")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField("0", text: $vm.sendAmount)
                                .font(.system(size: 24, weight: .bold, design: .monospaced))
                                .keyboardType(.numberPad)
                            Spacer()
                            Text("sats")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                        }
                    }
                    .padding(.vertical, 10)

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Destination")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("bc1q... / tb1q...", text: $vm.sendAddress)
                            .font(.system(size: 14, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(.vertical, 10)
                }
                .padding(.horizontal, 4)

                // Fee
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Fee Rate")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(vm.sendFeeRate)) sat/vB")
                            .font(.system(size: 12, design: .monospaced))
                    }
                    Slider(value: $vm.sendFeeRate, in: 1...200, step: 1)
                        .tint(Color.btcOrange)
                    if vm.sendFeeRate > 100 {
                        Label("Very high fee rate!", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }

                // Coin control
                Divider().padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Coin Control")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Toggle("", isOn: $vm.coinControlEnabled)
                            .labelsHidden()
                            .tint(Color.btcOrange)
                    }

                    if !vm.coinControlEnabled {
                        HStack(spacing: 8) {
                            strategyChip("Largest", strategy: .largestFirst)
                            strategyChip("Smallest", strategy: .smallestFirst)
                            strategyChip("Exact", strategy: .exact)
                        }
                    }
                }

                // UTXO selection
                if vm.coinControlEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Select UTXOs")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if !vm.manuallySelectedOutpoints.isEmpty {
                                Text(formatAmount(vm.coinControlTotal))
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.btcOrange)
                            }
                        }

                        ForEach(vm.utxos) { utxo in
                            sendUtxoRow(utxo)
                        }
                    }
                }

                // Stonewall (Fake CoinJoin)
                Divider().padding(.vertical, 4)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stonewall")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Makes your tx look like a CoinJoin")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Toggle("", isOn: $vm.stonewallEnabled)
                        .labelsHidden()
                        .tint(.purple)
                }

                // Preview + Transaction Diagram
                if let preview = vm.sendPreview {
                    VStack(spacing: 6) {
                        sendDetailRow("Inputs", value: "\(preview.selectedUTXOs.count)")
                        sendDetailRow("Fee", value: "\(preview.fee) sats")
                        if preview.hasChange {
                            sendDetailRow("Change", value: formatAmount(preview.change))
                        }
                        if vm.stonewallEnabled {
                            sendDetailRow("Type", value: "Stonewall")
                        }
                    }

                    // Transaction diagram
                    TransactionDiagramView(
                        inputs: preview.selectedUTXOs,
                        destinationAddress: vm.sendAddress,
                        destinationAmount: UInt64(vm.sendAmount) ?? 0,
                        changeAmount: preview.change,
                        fee: preview.fee,
                        isStonewall: vm.stonewallEnabled
                    )
                    .padding(.vertical, 8)
                }

                // Error
                if let error = vm.sendError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                // Step buttons
                sendStepButtons
            }
            .padding()
        }
        .navigationTitle("Send")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var sendStepButtons: some View {
        if vm.sendStep == .form {
            Button {
                vm.buildAndPreview()
            } label: {
                Text("Build Transaction")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        (vm.sendAddress.isEmpty || vm.sendAmount.isEmpty) ? Color(.systemGray3) : Color.btcOrange,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(vm.sendAddress.isEmpty || vm.sendAmount.isEmpty)

        } else if vm.sendStep == .built {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("PSBT ready").font(.system(size: 13, weight: .medium))
                }

                Button {
                    Task { await vm.signAndPrepare() }
                } label: {
                    HStack {
                        if vm.isSigning { ProgressView().tint(.white).padding(.trailing, 4) }
                        Text(vm.isSigning ? "Check your Ledger..." : "Sign with Ledger")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.btcOrange, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(vm.isSigning)
            }

        } else if vm.sendStep == .signed {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Signed — ready to broadcast").font(.system(size: 13, weight: .medium))
                }

                Button {
                    Task { await vm.broadcastTransaction() }
                } label: {
                    HStack {
                        if vm.isSigning { ProgressView().tint(.white).padding(.trailing, 4) }
                        Text(vm.isSigning ? "Broadcasting..." : "Broadcast")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(vm.isSigning)
            }

        } else if vm.sendStep == .broadcast {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.green)
                Text("Sent!")
                    .font(.system(size: 16, weight: .bold))

                if let txid = vm.broadcastTxid {
                    Text(txid)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)

                    Button {
                        UIPasteboard.general.string = txid
                    } label: {
                        HStack { Image(systemName: "doc.on.doc"); Text("Copy txid") }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.btcOrange)
                    }
                }
            }
        }

        if vm.sendStep != .form {
            Button("Start Over") { vm.resetSend() }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private func sendUtxoRow(_ utxo: UTXO) -> some View {
        let selected = vm.isUTXOSelected(outpoint: utxo.outpoint)
        let frozen = vm.isFrozen(outpoint: utxo.outpoint)
        return Button {
            vm.toggleUTXOSelection(outpoint: utxo.outpoint)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.btcOrange : Color(.systemGray3))
                    .font(.system(size: 18))

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(utxo.address.prefix(14)) + "...")
                        .font(.system(size: 11, design: .monospaced))
                    HStack(spacing: 4) {
                        Text(String(utxo.txid.prefix(8)) + ":\(utxo.vout)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        if frozen {
                            Image(systemName: "snowflake")
                                .font(.system(size: 8))
                                .foregroundStyle(.cyan)
                        }
                        if vm.addressStatus(for: utxo.address) == .used {
                            Text("EXPOSED")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                    }
                }

                Spacer()

                Text(formatAmount(utxo.value))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(selected ? Color.btcOrange : .secondary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(selected ? Color.btcOrange.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .opacity(frozen ? 0.4 : 1)
        .disabled(frozen)
    }

    private func strategyChip(_ label: String, strategy: CoinSelectionStrategy) -> some View {
        Button {
            vm.selectedStrategy = strategy
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(vm.selectedStrategy == strategy ? .white : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    vm.selectedStrategy == strategy ? Color.btcOrange : Color(.systemGray5),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func sendDetailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, design: .monospaced))
        }
    }

    // MARK: - Receive Page

    @State private var copied = false

    private var receivePage: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Hero
                VStack(spacing: 6) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.green, .green.opacity(0.5))
                    Text("Share your address to receive bitcoin. Always use a fresh address for privacy.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 8)

                // QR code — dark background, no box
                if let qrImage = generateQRCode(from: vm.currentReceiveAddress) {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .colorInvert()
                        .padding(12)
                }

                // Address
                if !vm.currentReceiveAddress.isEmpty {
                    Text(vm.currentReceiveAddress)
                        .font(.system(size: 12, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    Button {
                        UIPasteboard.general.string = vm.currentReceiveAddress
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
                }

                // Status badge
                let status = vm.addressStatus(for: vm.currentReceiveAddress)
                HStack(spacing: 6) {
                    Circle()
                        .fill(status == .fresh ? Color.green : status == .funded ? Color.orange : Color.red)
                        .frame(width: 6, height: 6)
                    Text(status == .fresh ? "Fresh" : status == .funded ? "Funded" : "Used — exposed")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(status == .fresh ? .green : status == .funded ? .orange : .red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    (status == .fresh ? Color.green : status == .funded ? Color.orange : Color.red).opacity(0.1),
                    in: Capsule()
                )

                // Reuse warning
                if status == .used {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("Public key exposed on-chain. Use a fresh address.")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }

                // Address index stepper
                VStack(spacing: 8) {
                    HStack {
                        Text("Address Index")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("#\(vm.currentReceiveIndex)")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green)
                    }

                    Picker("Index", selection: Binding(
                        get: { vm.currentReceiveIndex },
                        set: { vm.selectAddressIndex($0) }
                    )) {
                        ForEach(0...vm.maxAddressIndex, id: \.self) { i in
                            HStack {
                                Text("\(i)")
                                let addr = vm.addresses.first { !$0.isChange && $0.index == UInt32(i) }
                                if let a = addr {
                                    let s = vm.addressStatus(for: a.address)
                                    Circle()
                                        .fill(s == .fresh ? Color.green : s == .funded ? Color.orange : Color.red)
                                        .frame(width: 6, height: 6)
                                }
                            }
                            .tag(UInt32(i))
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 100)
                }

                receiveAddressList
            }
            .padding()
        }
        .navigationTitle("Receive")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var receiveAddressList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Addresses")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            ForEach(0...vm.maxAddressIndex, id: \.self) { i in
                receiveAddressRow(index: UInt32(i))
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func receiveAddressRow(index: UInt32) -> some View {
        let addr = vm.addresses.first { !$0.isChange && $0.index == index }
        if let a = addr {
            let s = vm.addressStatus(for: a.address)
            let bal = vm.utxos.filter { $0.address == a.address }.reduce(0 as UInt64) { $0 + $1.value }

            if s != .fresh || a.index == vm.currentReceiveIndex {
                Button { vm.selectAddressIndex(a.index) } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(s == .fresh ? Color.green : s == .funded ? Color.orange : Color.red)
                            .frame(width: 6, height: 6)
                        Text("#\(a.index)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                        Text(String(a.address.prefix(10)) + "..." + String(a.address.suffix(6)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if bal > 0 {
                            Text(formatAmount(bal))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        } else {
                            Text(s.rawValue)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(a.index == vm.currentReceiveIndex ? Color.green.opacity(0.06) : .clear)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - QR Code

    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Wallet Addresses Section

private struct WalletAddressesSection: View {
    typealias AddrItem = (address: WalletAddress, balance: UInt64, utxoCount: Int, status: WalletAddress.Status)

    let activeAddresses: [AddrItem]
    let activeChangeAddresses: [AddrItem]
    let archivedAddresses: [AddrItem]
    let archivedChangeAddresses: [AddrItem]
    let formatAmount: (UInt64) -> String
    @Binding var selectedAddress: WalletAddress?

    var body: some View {
        // Active receiving addresses
        if !activeAddresses.isEmpty {
            Section {
                ForEach(activeAddresses, id: \.address.id) { item in
                    Button {
                        selectedAddress = item.address
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text("#\(item.address.index)")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(item.status == .funded ? Color.btcOrange : Color.gray, in: RoundedRectangle(cornerRadius: 4))
                                    Text(String(item.address.address.prefix(14)) + "..." + String(item.address.address.suffix(6)))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.primary)
                                }
                                HStack(spacing: 6) {
                                    Text("\(item.utxoCount) UTXO\(item.utxoCount == 1 ? "" : "s")")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(item.status == .funded ? "FUNDED" : "USED")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(item.status == .funded ? .orange : .red)
                                }
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(formatAmount(item.balance))
                                    .font(.subheadline.weight(.medium).monospacedDigit())
                                    .foregroundStyle(.primary)
                                if item.status == .used {
                                    Text("retired")
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
            } header: {
                Text("Receiving (\(activeAddresses.count))")
            }
        }

        // Active change addresses
        if !activeChangeAddresses.isEmpty {
            Section {
                ForEach(activeChangeAddresses, id: \.address.id) { item in
                    Button {
                        selectedAddress = item.address
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text("C#\(item.address.index)")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(item.status == .used ? Color.red : Color.btcOrange, in: RoundedRectangle(cornerRadius: 4))
                                    Text(String(item.address.address.prefix(14)) + "..." + String(item.address.address.suffix(6)))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.primary)
                                }
                                HStack(spacing: 6) {
                                    if item.utxoCount > 0 {
                                        Text("\(item.utxoCount) UTXO\(item.utxoCount == 1 ? "" : "s")")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(item.status == .used ? "PUBKEY EXPOSED" : "FUNDED")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(item.status == .used ? .red : .orange)
                                }
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                if item.balance > 0 {
                                    Text(formatAmount(item.balance))
                                        .font(.subheadline.weight(.medium).monospacedDigit())
                                        .foregroundStyle(.primary)
                                }
                                Text("change")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
            } header: {
                Text("Change (\(activeChangeAddresses.count))")
            }
        }

        // Archive (used/retired addresses)
        if !archivedAddresses.isEmpty || !archivedChangeAddresses.isEmpty {
            Section {
                DisclosureGroup("Archive (\(archivedAddresses.count + archivedChangeAddresses.count))") {
                    ForEach(archivedAddresses, id: \.address.id) { item in
                        archivedAddressRow(item, isChange: false)
                    }
                    ForEach(archivedChangeAddresses, id: \.address.id) { item in
                        archivedAddressRow(item, isChange: true)
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
            }
        }
    }

    private func archivedAddressRow(_ item: AddrItem, isChange: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(isChange ? "C#\(item.address.index)" : "#\(item.address.index)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    Text(String(item.address.address.prefix(12)) + "..." + String(item.address.address.suffix(4)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("USED")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.6))
            }

            Spacer()

            if item.balance > 0 {
                Text(formatAmount(item.balance))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text("empty")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.vertical, 3)
        .opacity(0.7)
    }
}

// MARK: - Wallet UTXOs Section

private struct WalletUTXOsSection: View {
    @EnvironmentObject var vm: WalletVM

    let utxos: [UTXO]
    let formatAmount: (UInt64) -> String

    var body: some View {
        if !utxos.isEmpty {
            Section("UTXOs (\(utxos.count))") {
                ForEach(utxos) { utxo in
                    utxoRow(utxo)
                        .listRowBackground(Color.clear)
                }
            }
        }
    }

    private func utxoRow(_ utxo: UTXO) -> some View {
        let addr = vm.addresses.first { $0.address == utxo.address }
        let isChange = addr?.isChange ?? false
        let index = addr?.index
        let status = vm.addressStatus(for: utxo.address)
        let frozen = vm.isFrozen(outpoint: utxo.outpoint)

        return HStack(spacing: 10) {
            // Index badge
            if let idx = index {
                Text(isChange ? "C#\(idx)" : "#\(idx)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        status == .used ? Color.red.opacity(0.8) :
                        isChange ? Color.gray : Color.btcOrange,
                        in: RoundedRectangle(cornerRadius: 4)
                    )
            }

            // Txid + address
            VStack(alignment: .leading, spacing: 3) {
                Text(String(utxo.txid.prefix(10)) + ":\(utxo.vout)")
                    .font(.system(size: 11, design: .monospaced))
                Text(String(utxo.address.prefix(12)) + "..." + String(utxo.address.suffix(4)))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Status indicators
            VStack(alignment: .trailing, spacing: 3) {
                Text(formatAmount(utxo.value))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))

                HStack(spacing: 4) {
                    // Confirmation
                    Circle()
                        .fill(utxo.status.confirmed ? Color.green : Color.orange)
                        .frame(width: 5, height: 5)

                    if frozen {
                        Image(systemName: "snowflake")
                            .font(.system(size: 8))
                            .foregroundStyle(.cyan)
                    }

                    if status == .used {
                        Text("EXPOSED")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .opacity(frozen ? 0.4 : 1)
        .swipeActions(edge: .trailing) {
            Button {
                vm.toggleFreeze(outpoint: utxo.outpoint)
            } label: {
                Label(
                    frozen ? "Unfreeze" : "Freeze",
                    systemImage: frozen ? "flame" : "snowflake"
                )
            }
            .tint(frozen ? .orange : .cyan)
        }
    }
}

// MARK: - Wallet Transactions Section

private struct WalletTransactionsSection: View {
    @EnvironmentObject var vm: WalletVM

    let formatAmount: (UInt64) -> String
    @Binding var selectedTx: Transaction?
    var onBumpFee: ((Transaction) -> Void)?

    var body: some View {
        if !vm.transactions.isEmpty {
            Section {
                ForEach(vm.transactions) { tx in
                    txRow(tx)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
            } header: {
                Text("Transactions (\(vm.transactions.count))")
            }
        }
    }

    private func txRow(_ tx: Transaction) -> some View {
        let isSend = txIsSend(tx)
        let amount = txAmount(tx)

        return HStack(spacing: 10) {
            // Direction icon
            Image(systemName: isSend ? "arrow.up.right" : "arrow.down.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSend ? .orange : .green)
                .frame(width: 28, height: 28)
                .background((isSend ? Color.orange : Color.green).opacity(0.12), in: Circle())

            // Txid + date
            VStack(alignment: .leading, spacing: 3) {
                Text(String(tx.txid.prefix(12)) + "..." + String(tx.txid.suffix(4)))
                    .font(.system(size: 11, design: .monospaced))

                HStack(spacing: 6) {
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

                    // Contract tag if destination is a known contract
                    if let tag = txContractTag(tx) {
                        Text(tag.label)
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(tag.color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(tag.color.opacity(0.12), in: Capsule())
                    }

                    if let label = vm.label(forTxid: tx.txid) {
                        Text(label)
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                    }
                }
            }

            Spacer()

            // Amount + fee
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(isSend ? "-" : "+")\(formatAmount(amount))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(isSend ? .orange : .green)
                Text("\(tx.fee) fee")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            if !tx.status.confirmed && txIsSend(tx) {
                Button {
                    onBumpFee?(tx)
                } label: {
                    Label("Bump Fee (RBF)", systemImage: "bolt.fill")
                }
            }
            Button { selectedTx = tx } label: {
                Label("Add Label", systemImage: "tag")
            }
            Button { UIPasteboard.general.string = tx.txid } label: {
                Label("Copy txid", systemImage: "doc.on.doc")
            }
        }
    }

    /// Determine if a transaction is a send (our addresses in inputs)
    private func txIsSend(_ tx: Transaction) -> Bool {
        let ourAddresses = Set(vm.addresses.map(\.address))
        for input in tx.vin {
            if let prevout = input.prevout, let addr = prevout.scriptpubkeyAddress {
                if ourAddresses.contains(addr) { return true }
            }
        }
        return false
    }

    /// Check if any output goes to a known contract address
    private func txContractTag(_ tx: Transaction) -> (label: String, color: Color)? {
        let contracts = ContractStore.shared.contractsForNetwork(isTestnet: NetworkConfig.shared.isTestnet)
        var contractAddrs: [String: Contract] = [:]
        for c in contracts { contractAddrs[c.address] = c }
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
        // Also check inputs — spending from a contract
        for input in tx.vin {
            if let prevout = input.prevout, let addr = prevout.scriptpubkeyAddress, let contract = contractAddrs[addr] {
                switch contract.type {
                case .vault: return ("CLTV", .orange)
                case .inheritance: return ("CSV", .purple)
                case .htlc: return ("HTLC", .teal)
                case .channel: return ("CHANNEL", .green)
                case .pool: return ("MULTI", .blue)
                }
            }
        }
        return nil
    }

    /// Calculate net amount for a transaction
    private func txAmount(_ tx: Transaction) -> UInt64 {
        let ourAddresses = Set(vm.addresses.map(\.address))
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for output in tx.vout {
            if let addr = output.scriptpubkeyAddress, ourAddresses.contains(addr) {
                received += output.value
            }
        }
        for input in tx.vin {
            if let prevout = input.prevout, let addr = prevout.scriptpubkeyAddress, ourAddresses.contains(addr) {
                sent += prevout.value
            }
        }
        if sent > received {
            return sent - received
        }
        return received - sent
    }
}

// MARK: - Transaction Diagram

struct TransactionDiagramView: View {
    let inputs: [UTXO]
    let destinationAddress: String
    let destinationAmount: UInt64
    let changeAmount: UInt64
    let fee: UInt64
    let isStonewall: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text("Transaction Flow")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)

            HStack(alignment: .center, spacing: 0) {
                // Inputs (left)
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(inputs.prefix(5)) { utxo in
                        HStack(spacing: 4) {
                            Text(BalanceUnit.formatSats(utxo.value))
                                .font(.system(size: 9, design: .monospaced))
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                        }
                    }
                    if inputs.count > 5 {
                        Text("+\(inputs.count - 5) more")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(minWidth: 80)

                // Arrow
                VStack(spacing: 2) {
                    Rectangle()
                        .fill(Color.btcOrange.opacity(0.4))
                        .frame(width: 40, height: 1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.btcOrange.opacity(0.6))
                }

                // Outputs (right)
                VStack(alignment: .leading, spacing: 6) {
                    // Destination
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(BalanceUnit.formatSats(destinationAmount))
                                .font(.system(size: 9, design: .monospaced))
                            Text(String(destinationAddress.prefix(10)) + "...")
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // Stonewall decoy
                    if isStonewall {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.purple)
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(BalanceUnit.formatSats(destinationAmount))
                                    .font(.system(size: 9, design: .monospaced))
                                Text("decoy (self)")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.purple)
                            }
                        }
                    }

                    // Change
                    if changeAmount >= 546 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.gray)
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(BalanceUnit.formatSats(changeAmount))
                                    .font(.system(size: 9, design: .monospaced))
                                Text("change")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    // Fee
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.red.opacity(0.6))
                            .frame(width: 6, height: 6)
                        Text("\(fee) sat fee")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.red.opacity(0.7))
                    }
                }
                .frame(minWidth: 100)
            }

            if isStonewall {
                Text("Stonewall: observers cannot tell which output is the real payment")
                    .font(.system(size: 8))
                    .foregroundStyle(.purple.opacity(0.7))
                    .padding(.top, 10)
            }
        }
        .padding(16)
        .background(Color(.systemGray6).opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Wallet Button Style (scale + highlight)

struct WalletButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .background(
                configuration.isPressed ? color.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}
