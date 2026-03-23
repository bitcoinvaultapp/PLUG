import SwiftUI

struct VaultView: View {
    @StateObject private var vm = VaultVM()
    @State private var showCreate = false
    @State private var showSpend = false
    @State private var showCreated = false
    @State private var selectedContract: Contract?
    @State private var showDetail = false
    @State private var copiedId = ""
    @State private var contractToDelete: Contract?
    @State private var showDeleteAlert = false

    var body: some View {
        List {
            // Hero
            VStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 32))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.orange)
                Text("Lock your sats until a specific block height. No one can spend before then.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if vm.contracts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No Vaults")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Lock bitcoins over time")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(vm.contracts) { contract in
                    contractRow(contract)
                        .listRowBackground(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedContract = contract
                            showDetail = true
                        }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Vaults")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCreate = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(isPresented: $showDetail) {
            if let contract = selectedContract {
                vaultDetailPage(contract)
            }
        }
        .navigationDestination(isPresented: $showCreate) { createPage }
        .navigationDestination(isPresented: $showSpend) { spendPage }
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
        .task {
            await vm.refresh()
        }
    }

    // MARK: - Contract Row

    private func contractRow(_ contract: Contract) -> some View {
        let funded = vm.fundedAmount(for: contract)
        let unlocked = vm.isUnlocked(contract)
        let remaining = vm.blocksRemaining(for: contract)

        return HStack(spacing: 10) {
            Circle()
                .fill(unlocked ? Color.green : Color.orange)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(contract.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text("CLTV")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.orange.opacity(0.1), in: Capsule())
                    if let idx = contract.keyIndex {
                        Text("#\(idx)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 4) {
                    Text(unlocked ? "Unlocked" : "Locked")
                        .foregroundStyle(unlocked ? .green : .orange)
                    if !unlocked && remaining > 0 {
                        Text("·").foregroundStyle(.quaternary)
                        Text(BlockDurationPicker.blocksToHumanTime(blocks: remaining))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 10))
            }

            Spacer()

            Text(BalanceUnit.format(funded))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.quaternary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Detail Sheet

    private func vaultDetailPage(_ contract: Contract) -> some View {
        let funded = vm.fundedAmount(for: contract)

        return ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Status header
                    HStack {
                        Image(systemName: vm.isUnlocked(contract) ? "lock.open.fill" : "lock.fill")
                            .font(.title3)
                            .foregroundStyle(vm.isUnlocked(contract) ? .green : .orange)
                        Text(contract.name)
                            .font(.title2.bold())
                        Spacer()
                        if let _ = contract.lockBlockHeight {
                            let remaining = vm.blocksRemaining(for: contract)
                            if remaining > 0 {
                                Text(BlockDurationPicker.blocksToHumanTime(blocks: remaining))
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.orange.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.orange)
                            } else {
                                Text("Unlocked")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.green.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.green)
                            }
                        }
                    }

                    // Balance
                    VStack(alignment: .leading, spacing: 6) {
                        Text(BalanceUnit.format(funded))
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                        Text("sats")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

                    if let confs = vm.confirmations[contract.address], confs > 0 {
                        let label = confs >= 6 ? "Confirmed" : "\(confs)/6 confirmations"
                        let color: Color = confs >= 6 ? .green : .orange
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(color)
                    }

                    // Address
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Address")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(contract.address)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

                    // Script
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Witness Script")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(contract.witnessScript.isEmpty ? contract.script : contract.witnessScript)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(4)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

                    if let idx = contract.keyIndex {
                        HStack(spacing: 4) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Text("Key index: \(idx)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if contract.isTaproot {
                                Text("P2TR")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    // Action buttons
                    VStack(spacing: 10) {
                        if vm.isUnlocked(contract) {
                            Button {
                                showDetail = false
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
                                .padding(.vertical, 12)
                                .background(Color.green, in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }

                        HStack(spacing: 10) {
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
                                .padding(.vertical, 10)
                                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)

                            Button {
                                secureCopy(contract.script.isEmpty ? contract.witnessScript : contract.script)
                                copiedId = "\(contract.id):script"
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedId = "" }
                            } label: {
                                HStack {
                                    Image(systemName: copiedId == "\(contract.id):script" ? "checkmark" : "scroll")
                                    Text(copiedId == "\(contract.id):script" ? "Copied!" : "Script")
                                }
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }

                        Button(role: .destructive) {
                            contractToDelete = contract
                            showDeleteAlert = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Delete")
                            }
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        .navigationTitle("Vault Details")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete contract?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { contractToDelete = nil }
            Button("Delete", role: .destructive) {
                if let c = contractToDelete {
                    vm.delete(id: c.id)
                    contractToDelete = nil
                    showDetail = false
                    selectedContract = nil
                }
            }
        } message: {
            if let c = contractToDelete {
                let balance = vm.fundedAmount(for: c)
                if balance > 0 {
                    Text("This contract holds \(balance) sats! Backup address and witness script before deleting.")
                } else {
                    Text("This action is irreversible.")
                }
            }
        }
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

    private var createPage: some View {
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
                    .disabled(vm.name.isEmpty || vm.lockBlockHeight.isEmpty || !vaultLockHeightValid)
                }
            }
        .navigationTitle("New Vault")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            if vm.createdContract != nil { showCreated = true }
        }
    }

    // MARK: - Spend Page

    private var spendPage: some View {
        Form {
                if let contract = vm.selectedContract {
                    Section("Available balance") {
                        Text(BalanceUnit.format(vm.spendableBalance))
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
                            Text(BalanceUnit.format(vm.netSpendAmount))
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

                            // Broadcast happens automatically after signing

                            if let psbt = vm.psbtForReview {
                                Button("Export PSBT") {
                                    secureCopy(psbt)
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
    }
}
