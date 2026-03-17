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
            .navigationBarHidden(true)
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

            Button("Demo mode (testnet)") {
                DemoMode.shared.activate()
                LedgerManager.shared.isDemoMode = true
                Task { await vm.loadWallet() }
            }
            .buttonStyle(.bordered)

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

    private var walletContent: some View {
        List {
            PlugHeader(pageName: "Wallet")
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            // Balance
            Section {
                VStack(spacing: 8) {
                    Text("\(vm.totalBalance) sats")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
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

            // UTXOs
            Section("UTXOs (\(vm.utxos.count))") {
                ForEach(vm.utxos) { utxo in
                    utxoRow(utxo)
                }
            }

            // Transactions
            Section("Transactions (\(vm.transactions.count))") {
                ForEach(vm.transactions) { tx in
                    txRow(tx)
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

    private var receiveSheet: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Receive bitcoin")
                    .font(.headline)

                if let qrImage = generateQRCode(from: vm.currentReceiveAddress) {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .padding()
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                }

                if vm.currentReceiveAddress.isEmpty {
                    Text("Deriving address...")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text(vm.currentReceiveAddress)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .textSelection(.enabled)
                }

                Button("Copy address") {
                    UIPasteboard.general.string = vm.currentReceiveAddress
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.currentReceiveAddress.isEmpty)

                Text("Address #\(vm.currentReceiveIndex)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showReceive = false }
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
