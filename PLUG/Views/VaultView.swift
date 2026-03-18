import SwiftUI

struct VaultView: View {
    @StateObject private var vm = VaultVM()
    @State private var showCreate = false
    @State private var showSpend = false
    @State private var showCreated = false
    /// Tracks which button was copied: "contractId:field" to avoid all cards showing "Copied!"
    @State private var copiedId = ""
    @State private var contractToDelete: Contract?
    @State private var showDeleteAlert = false

    var body: some View {
            List {
                // Existing vaults
                if vm.contracts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No Vault")
                            .font(.headline)
                        Text("Lock bitcoins over time")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    ForEach(vm.contracts) { contract in
                        vaultRow(contract)
                    }
                    .onDelete { indexSet in
                        if let i = indexSet.first {
                            contractToDelete = vm.contracts[i]
                            showDeleteAlert = true
                        }
                    }
                }
            }
            .navigationTitle("Vaults")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showCreate = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreate, onDismiss: {
                if vm.createdContract != nil { showCreated = true }
            }) { createSheet }
            .sheet(isPresented: $showCreated) {
                if let contract = vm.createdContract {
                    ContractCreatedSheet(
                        contract: contract,
                        currentBlockHeight: vm.currentBlockHeight,
                        onDismiss: {
                            showCreated = false
                            vm.createdContract = nil
                        }
                    )
                }
            }
            .sheet(isPresented: $showSpend) { spendSheet }
            .alert("Delete contract?", isPresented: $showDeleteAlert) {
                Button("Cancel", role: .cancel) { contractToDelete = nil }
                Button("Delete", role: .destructive) {
                    if let c = contractToDelete {
                        let balance = vm.fundedAmount(for: c)
                        if balance > 0 {
                            // Still has funds — warn harder but allow
                        }
                        vm.delete(id: c.id)
                        contractToDelete = nil
                    }
                }
            } message: {
                if let c = contractToDelete {
                    let balance = vm.fundedAmount(for: c)
                    if balance > 0 {
                        Text("This contract holds \(balance) sats! Make sure you have backed up the address and the witness script before deleting. Funds will be unrecoverable without this information.")
                    } else {
                        Text("This action is irreversible.")
                    }
                }
            }
            .refreshable { await vm.refresh() }
            .task { await vm.refresh() }
    }

    private func vaultRow(_ contract: Contract) -> some View {
        let funded = vm.fundedAmount(for: contract)
        let target = contract.amount
        let progress = vm.progress(for: contract)
        let pct = Int(progress * 100)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: vm.isUnlocked(contract) ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(vm.isUnlocked(contract) ? .green : .orange)
                Text(contract.name)
                    .font(.headline)
                Spacer()
                if let _ = contract.lockBlockHeight {
                    let remaining = vm.blocksRemaining(for: contract)
                    if remaining > 0 {
                        Text(BlockDurationPicker.blocksToHumanTime(blocks: remaining))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Unlocked")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            // Funded amount vs target
            HStack(alignment: .firstTextBaseline) {
                Text("\(funded)")
                    .font(.title2.bold().monospacedDigit())
                Text("/ \(target) sats")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(pct)%")
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(progress >= 1.0 ? .green : .orange)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(progress >= 1.0 ? Color.green : Color.orange)
                        .frame(width: geo.size.width * progress, height: 6)
                }
            }
            .frame(height: 6)

            if let confs = vm.confirmations[contract.address], confs > 0 {
                let label = confs >= 6 ? "Confirmed" : "\(confs)/6 confirmations"
                let color: Color = confs >= 6 ? .green : .orange
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(color)
            }

            Text(contract.address)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            VStack(spacing: 8) {
                // Primary: Spend (only when unlocked)
                if vm.isUnlocked(contract) {
                    Button {
                        Task {
                            await vm.prepareSpend(contract: contract)
                            showSpend = true
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("Spend")
                        }
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.green.opacity(0.15))
                        .foregroundStyle(.green)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 8) {
                    Button {
                        UIPasteboard.general.string = contract.address
                        copiedId = "\(contract.id):address"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedId = "" }
                    } label: {
                        HStack {
                            Image(systemName: copiedId == "\(contract.id):address" ? "checkmark" : "doc.on.doc")
                            Text(copiedId == "\(contract.id):address" ? "Copied!" : "Address")
                        }
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray5))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    Button {
                        UIPasteboard.general.string = contract.witnessScript
                        copiedId = "\(contract.id):script"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedId = "" }
                    } label: {
                        HStack {
                            Image(systemName: copiedId == "\(contract.id):script" ? "checkmark" : "scroll")
                            Text(copiedId == "\(contract.id):script" ? "Copied!" : "Script")
                        }
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray5))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Create Sheet

    private var vaultLockHeightValid: Bool {
        guard let lockHeight = Int(vm.lockBlockHeight) else { return false }
        return lockHeight > vm.currentBlockHeight
    }

    private var vaultPreviewAddress: String? {
        guard vaultLockHeightValid,
              let lockHeight = Int(vm.lockBlockHeight),
              let xpubStr = KeychainStore.shared.loadXpub(isTestnet: vm.isTestnet),
              let xpub = ExtendedPublicKey.fromBase58(xpubStr),
              let derivedKey = xpub.derivePath([0, vm.keyIndex]) else { return nil }
        let script = ScriptBuilder.vaultScript(locktime: Int64(lockHeight), pubkey: derivedKey.key)
        return script.p2wshAddress(isTestnet: vm.isTestnet)
    }

    private var createSheet: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("My Vault", text: $vm.name)
                }

                // Taproot disabled for single-key vaults — Ledger V2 requires
                // unique keys in the policy, but a vault uses only one key.
                // P2WSH vaults work correctly with the Ledger.

                BlockDurationPicker(
                    value: $vm.lockBlockHeight,
                    currentBlockHeight: vm.currentBlockHeight,
                    mode: .absoluteCLTV,
                    presets: [("1h", 6), ("1d", 144), ("1w", 1008), ("1mo", 4320), ("6mo", 25920), ("1y", 52560)]
                )

                Section("Amount (sats)") {
                    TextField("Amount", text: $vm.amount)
                        .keyboardType(.numberPad)
                }

                KeyIndexPicker(index: $vm.keyIndex, maxIndex: 19)

                if vaultLockHeightValid, let lockHeight = Int(vm.lockBlockHeight) {
                    Section("Information") {
                        Text("The sats will be locked until block \(lockHeight). No one will be able to spend them before then.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let address = vaultPreviewAddress {
                    Section("P2WSH Address (preview)") {
                        Text(address)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                if let error = vm.error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Create Vault") {
                        Task {
                            await vm.create()
                            if vm.createdContract != nil {
                                showCreate = false
                            }
                        }
                    }
                    .disabled(vm.name.isEmpty || vm.lockBlockHeight.isEmpty || vm.amount.isEmpty || !vaultLockHeightValid)
                }
            }
            .navigationTitle("New Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCreate = false }
                }
            }
        }
    }

    // MARK: - Spend Sheet

    private var spendSheet: some View {
        NavigationStack {
            Form {
                if let contract = vm.selectedContract {
                    Section("Available balance") {
                        Text("\(vm.spendableBalance) sats")
                            .font(.title2.monospacedDigit().bold())
                    }

                    Section("Destination address") {
                        TextField("bc1q... / tb1q...", text: $vm.spendAddress)
                            .font(.system(.caption, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Section("Fee (sat/vB)") {
                        HStack {
                            Text(String(format: "%.0f", vm.spendFeeRate))
                                .font(.subheadline.monospacedDigit())
                            Slider(value: $vm.spendFeeRate, in: 1...100, step: 1)
                                .onChange(of: vm.spendFeeRate) { _ in
                                    vm.updateEstimatedFee()
                                }
                        }
                        if vm.spendFeeRate > 100 {
                            Label("Very high fee rate! Make sure you are not confusing sat/vB with sat/kB.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        HStack {
                            Text("Estimated fee:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(vm.estimatedFee) sats")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Net amount:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(vm.netSpendAmount) sats")
                                .font(.caption.monospacedDigit().bold())
                        }
                    }

                    if let error = vm.spendError {
                        Section {
                            Text(error)
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }

                    if let txid = vm.spendResult {
                        Section("Transaction broadcast") {
                            Text(txid)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                            Button("Copy txid") {
                                UIPasteboard.general.string = txid
                            }
                            .font(.caption)
                        }
                    } else if let txHex = vm.txForReview {
                        // Transaction ready for review before broadcast
                        Section("Transaction ready") {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Transaction signed and ready")
                                    .font(.subheadline.weight(.medium))
                            }

                            HStack {
                                Text("Size:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(txHex.count / 2) bytes")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            HStack {
                                Text("Estimated fee:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(vm.estimatedFee) sats")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            Button("Broadcast") {
                                Task { await vm.confirmBroadcast() }
                            }
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.green, in: RoundedRectangle(cornerRadius: 8))
                            .disabled(vm.isSpending)

                            if let psbt = vm.psbtForReview {
                                Button("Export PSBT") {
                                    UIPasteboard.general.string = psbt
                                }
                                .font(.caption)
                            }
                        }

                        if vm.isSpending {
                            HStack {
                                ProgressView()
                                Text("Broadcasting...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Section {
                            Button("Spend") {
                                Task { await vm.spendVault() }
                            }
                            .disabled(vm.spendAddress.isEmpty || vm.isSpending || vm.netSpendAmount == 0)

                            if vm.isSpending {
                                HStack {
                                    ProgressView()
                                    Text("Signing...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Spend Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showSpend = false }
                }
            }
        }
    }
}
