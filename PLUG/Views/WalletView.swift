import SwiftUI
import CoreImage.CIFilterBuiltins

struct WalletView: View {
    @EnvironmentObject var vm: WalletVM
    @State private var showSend = false
    @State private var showReceive = false
    @State private var selectedTx: Transaction?
    @State private var labelText: String = ""

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
            .refreshable { await vm.loadWallet() }
            .task { await vm.loadWallet() }
            .sheet(isPresented: $showSend) { sendSheet }
            .sheet(isPresented: $showReceive) { receiveSheet }
        }
    }

    // MARK: - No wallet

    @State private var showLedger = false

    private var noWalletView: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No wallet configured")
                .font(.headline)
            Text("Connect your Ledger to get started")
                .foregroundStyle(.secondary)

            Button("Connect Ledger") {
                showLedger = true
            }
            .buttonStyle(.borderedProminent)

            // Debug: show xpub status
            if let xpubStr = KeychainStore.shared.loadXpub(isTestnet: NetworkConfig.shared.isTestnet) {
                VStack(spacing: 4) {
                    Text("xpub found in Keychain:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(xpubStr.prefix(20) + "...")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if ExtendedPublicKey.fromBase58(xpubStr) != nil {
                        Text("Parsing OK")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else {
                        Text("Parsing FAILED — invalid xpub")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.top, 8)
            } else {
                Text("No xpub in Keychain for \(NetworkConfig.shared.isTestnet ? "testnet" : "mainnet")")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showLedger) {
            NavigationStack {
                LedgerView()
            }
        }
    }

    // MARK: - Wallet content

    /// Receiving addresses that have any on-chain activity (funded or used)
    private var activeAddresses: [(address: WalletAddress, balance: UInt64, utxoCount: Int, status: WalletAddress.Status)] {
        let receiving = vm.addresses.filter { !$0.isChange }
        return receiving.compactMap { addr in
            let addrUtxos = vm.utxos.filter { $0.address == addr.address }
            let status = vm.addressStatus(for: addr.address)
            guard status != .fresh else { return nil } // Only show addresses with activity
            let balance = addrUtxos.reduce(0 as UInt64) { $0 + $1.value }
            return (address: addr, balance: balance, utxoCount: addrUtxos.count, status: status)
        }
        .sorted { $0.address.index < $1.address.index }
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
                VStack(spacing: 8) {
                    Text("\(vm.totalBalance) sats")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))

                    if vm.unconfirmedBalance > 0 {
                        HStack(spacing: 12) {
                            Label("\(vm.confirmedBalance)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Label("\(vm.unconfirmedBalance)", systemImage: "clock.fill")
                                .foregroundStyle(.orange)
                        }
                        .font(.system(size: 12, design: .monospaced))
                    }

                    HStack(spacing: 16) {
                        Button("Send") { showSend = true }
                            .buttonStyle(.borderedProminent)
                        Button("Receive") { showReceive = true }
                            .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
            }

            // Fee environment
            if let fees = vm.feeEstimate {
                Section("Network Fees") {
                    HStack {
                        feeChip("Fast", rate: fees.fastestFee, color: .red)
                        feeChip("Normal", rate: fees.halfHourFee, color: .orange)
                        feeChip("Economy", rate: fees.economyFee, color: .green)
                    }
                }
            }

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

            // Addresses with UTXOs
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
                                    Text("\(item.balance) sats")
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
                    }
                } header: {
                    Text("Addresses (\(activeAddresses.count))")
                }
            }

            // UTXOs
            if !vm.utxos.isEmpty {
                Section("UTXOs (\(vm.utxos.count))") {
                    ForEach(filteredUtxos) { utxo in
                        utxoRow(utxo)
                    }
                }
            }

            // Transactions
            if !vm.transactions.isEmpty {
                Section("Transactions (\(vm.transactions.count))") {
                    ForEach(vm.transactions) { tx in
                        txRow(tx)
                    }
                }
            }
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
                        Text("\(balance) sats")
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
                            Text("\(utxo.value) sats")
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

    // MARK: - UTXO row

    private func utxoRow(_ utxo: UTXO) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(utxo.txid.prefix(12)) + "...\(utxo.vout)")
                    .font(.system(.caption, design: .monospaced))
                Text(utxo.address.prefix(20) + "...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(utxo.value) sats")
                    .font(.subheadline.weight(.medium).monospacedDigit())

                if vm.isFrozen(outpoint: utxo.outpoint) {
                    Image(systemName: "snowflake")
                        .foregroundStyle(.cyan)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button {
                vm.toggleFreeze(outpoint: utxo.outpoint)
            } label: {
                Label(
                    vm.isFrozen(outpoint: utxo.outpoint) ? "Unfreeze" : "Freeze",
                    systemImage: vm.isFrozen(outpoint: utxo.outpoint) ? "flame" : "snowflake"
                )
            }
            .tint(vm.isFrozen(outpoint: utxo.outpoint) ? .orange : .cyan)
        }
    }

    // MARK: - Transaction row

    private func txRow(_ tx: Transaction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: tx.status.confirmed ? "checkmark.circle.fill" : "clock.fill")
                    .foregroundStyle(tx.status.confirmed ? .green : .orange)
                    .font(.caption)
                Text(String(tx.txid.prefix(16)) + "...")
                    .font(.system(.caption, design: .monospaced))
                Spacer()
                Text("\(tx.fee) sats fee")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let label = vm.label(forTxid: tx.txid) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

            if let blockTime = tx.status.blockTime {
                Text(Date(timeIntervalSince1970: TimeInterval(blockTime)), style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("Add label") { selectedTx = tx }
            Button("Copy txid") { UIPasteboard.general.string = tx.txid }
        }
    }

    // MARK: - Send sheet

    private var sendSheet: some View {
        NavigationStack {
            Form {
                Section("Destination") {
                    TextField("Address bc1...", text: $vm.sendAddress)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                }

                Section("Amount (sats)") {
                    TextField("Amount", text: $vm.sendAmount)
                        .keyboardType(.numberPad)
                }

                Section("Fee (sat/vB)") {
                    HStack {
                        Slider(value: $vm.sendFeeRate, in: 1...200, step: 1)
                        Text(String(format: "%.0f", vm.sendFeeRate))
                            .font(.system(.body, design: .monospaced))
                    }
                    if vm.sendFeeRate > 100 {
                        Label("Very high fee rate! Make sure you are not confusing sat/vB with sat/kB.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Strategy") {
                    Picker("Coin Selection", selection: $vm.selectedStrategy) {
                        Text("Largest first").tag(CoinSelectionStrategy.largestFirst)
                        Text("Smallest first").tag(CoinSelectionStrategy.smallestFirst)
                        Text("Exact").tag(CoinSelectionStrategy.exact)
                    }
                }

                if let preview = vm.sendPreview {
                    Section("Preview") {
                        LabeledContent("Inputs", value: "\(preview.selectedUTXOs.count)")
                        LabeledContent("Fee", value: "\(preview.fee) sats")
                        if preview.hasChange {
                            LabeledContent("Change", value: "\(preview.change) sats")
                        }
                    }
                }

                // Error display
                if let error = vm.sendError {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                // Step 1: Build PSBT
                if vm.sendStep == .form {
                    Button("1. Build transaction") {
                        vm.buildAndPreview()
                    }
                    .disabled(vm.sendAddress.isEmpty || vm.sendAmount.isEmpty)
                }

                // Step 2: Sign with Ledger
                if vm.sendStep == .built {
                    Section("Transaction built") {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("PSBT ready")
                        }

                        Button("Copy PSBT (base64)") {
                            if let psbt = vm.builtPSBTBase64 {
                                UIPasteboard.general.string = psbt
                            }
                        }
                        .font(.caption)
                    }

                    Button {
                        Task { await vm.signAndPrepare() }
                    } label: {
                        HStack {
                            if vm.isSigning {
                                ProgressView()
                            }
                            Text(vm.isSigning ? "Check your Ledger..." : "2. Sign with Ledger")
                        }
                    }
                    .disabled(vm.isSigning)
                }

                // Step 3: Review + Broadcast
                if vm.sendStep == .signed {
                    Section("Transaction signed") {
                        HStack {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Text("Ready to broadcast")
                                .fontWeight(.semibold)
                        }

                        if let hex = vm.signedTxHex {
                            LabeledContent("Size", value: "\(hex.count / 2) bytes")
                        }

                        if let preview = vm.sendPreview {
                            LabeledContent("Fee", value: "\(preview.fee) sats")
                        }
                    }

                    Button {
                        Task { await vm.broadcastTransaction() }
                    } label: {
                        HStack {
                            if vm.isSigning {
                                ProgressView()
                            }
                            Text(vm.isSigning ? "Broadcasting..." : "3. Broadcast to network")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isSigning)
                }

                // Step 4: Done
                if vm.sendStep == .broadcast {
                    Section("Transaction broadcast") {
                        HStack {
                            Image(systemName: "party.popper.fill")
                            Text("Sent successfully!")
                                .fontWeight(.bold)
                                .foregroundStyle(.green)
                        }

                        if let txid = vm.broadcastTxid {
                            Text(txid)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)

                            Button("Copy txid") {
                                UIPasteboard.general.string = txid
                            }
                            .font(.caption)
                        }
                    }
                }

                // Reset button
                if vm.sendStep != .form {
                    Button("Start over") {
                        vm.resetSend()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showSend = false }
                }
            }
            // Preview is triggered by the "Build" button, not on every keystroke
        }
    }

    // MARK: - Receive sheet

    @State private var copied = false

    private var receiveSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // QR Code
                    if let qrImage = generateQRCode(from: vm.currentReceiveAddress) {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 220, height: 220)
                            .padding(16)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    }

                    // Address
                    if vm.currentReceiveAddress.isEmpty {
                        ProgressView()
                            .padding()
                    } else {
                        VStack(spacing: 8) {
                            Text(vm.currentReceiveAddress)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                                .textSelection(.enabled)

                            Button {
                                UIPasteboard.general.string = vm.currentReceiveAddress
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                            } label: {
                                Label(copied ? "Copied" : "Copy Address", systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(copied ? .green : Color.btcOrange)
                            .padding(.horizontal, 40)
                        }
                    }

                    // Address balance + status
                    let status = vm.addressStatus(for: vm.currentReceiveAddress)
                    let addrUtxos = vm.utxos.filter { $0.address == vm.currentReceiveAddress }
                    let addrBalance = addrUtxos.reduce(0 as UInt64) { $0 + $1.value }

                    VStack(spacing: 10) {
                        // Balance
                        if addrBalance > 0 {
                            Text("\(addrBalance) sats")
                                .font(.system(size: 22, weight: .bold, design: .monospaced))
                            Text("\(addrUtxos.count) UTXO\(addrUtxos.count == 1 ? "" : "s")")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        // Status badge
                        HStack(spacing: 6) {
                            Circle()
                                .fill(status == .fresh ? Color.green : status == .funded ? Color.orange : Color.red)
                                .frame(width: 8, height: 8)
                            Text(status == .fresh ? "Fresh address" : status == .funded ? "Funded" : "Used — do not reuse")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(status == .fresh ? .green : status == .funded ? .orange : .red)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            (status == .fresh ? Color.green : status == .funded ? Color.orange : Color.red).opacity(0.1),
                            in: Capsule()
                        )
                    }

                    // Reuse warning
                    if status == .used {
                        VStack(spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text("This address has been spent from.")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.red)
                            }
                            Text("Your public key is now visible on-chain. Reusing this address weakens your privacy and security. Use a fresh address instead.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                    }

                    // Address Index Picker
                    VStack(spacing: 8) {
                        HStack {
                            Text("Address #\(vm.currentReceiveIndex)")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            let idxStatus = vm.addressStatus(for: vm.currentReceiveAddress)
                            Text(idxStatus.rawValue.uppercased())
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(idxStatus == .fresh ? .green : idxStatus == .funded ? .orange : .red)
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
                        .frame(height: 120)

                        Text("Always use a fresh address (green) for each payment. Never reuse an address you've already spent from.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                    // All addresses summary
                    VStack(alignment: .leading, spacing: 0) {
                        Text("ALL ADDRESSES")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)

                        ForEach(0...vm.maxAddressIndex, id: \.self) { i in
                            let addr = vm.addresses.first { !$0.isChange && $0.index == UInt32(i) }
                            if let a = addr {
                                let s = vm.addressStatus(for: a.address)
                                let bal = vm.utxos.filter { $0.address == a.address }.reduce(0 as UInt64) { $0 + $1.value }
                                let utxoCount = vm.utxos.filter { $0.address == a.address }.count

                                // Only show addresses with activity or the current one
                                if s != .fresh || a.index == vm.currentReceiveIndex {
                                    Button {
                                        vm.selectAddressIndex(a.index)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Circle()
                                                .fill(s == .fresh ? Color.green : s == .funded ? Color.orange : Color.red)
                                                .frame(width: 8, height: 8)

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("#\(a.index)  \(String(a.address.prefix(10)))...\(String(a.address.suffix(6)))")
                                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                    .foregroundStyle(.primary)
                                                if bal > 0 {
                                                    Text("\(utxoCount) UTXO\(utxoCount == 1 ? "" : "s")")
                                                        .font(.system(size: 10, design: .monospaced))
                                                        .foregroundStyle(.secondary)
                                                }
                                            }

                                            Spacer()

                                            if bal > 0 {
                                                Text("\(bal) sats")
                                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                                    .foregroundStyle(.primary)
                                            } else {
                                                Text(s == .fresh ? "fresh" : "empty")
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .background(a.index == vm.currentReceiveIndex ? Color.btcOrange.opacity(0.08) : Color.clear)
                                    }
                                    .buttonStyle(.plain)

                                    if i < vm.maxAddressIndex {
                                        Divider().padding(.leading, 34)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Receive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showReceive = false }
                }
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
