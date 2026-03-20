import SwiftUI

struct HTLCView: View {
    @StateObject private var vm = HTLCVM()
    @State private var showCreate = false
    @State private var showCreated = false
    @State private var showClaim = false
    @State private var showRefund = false
    @State private var selectedContract: Contract?
    @State private var showDetail = false
    @State private var revealedPreimage: String?
    @State private var showPreimageAlert = false
    @State private var copiedId = ""
    @State private var contractToDelete: Contract?
    @State private var showDeleteAlert = false

    var body: some View {
        List {
            VStack(spacing: 6) {
                Image(systemName: "key.viewfinder")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.teal, .teal.opacity(0.5))
                Text("Conditional payment released with a secret preimage.")
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
                    Image(systemName: "lock.rotation")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No HTLCs")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Conditional payments with hash preimage")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(vm.contracts) { contract in
                    htlcListRow(contract)
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
        .navigationTitle("Hash Time-Lock")
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
                htlcDetailPage(contract)
            }
        }
        .navigationDestination(isPresented: $showCreate) { createPage }
        .sheet(isPresented: $showCreated) {
            ContractCreatedSheet(contract: vm.createdContract!, currentBlockHeight: vm.currentBlockHeight, preimage: vm.generatedPreimage, onDismiss: { showCreated = false; vm.createdContract = nil })
        }
        .navigationDestination(isPresented: $showClaim) { claimPage }
        .navigationDestination(isPresented: $showRefund) { refundPage }
        .alert("Preimage", isPresented: $showPreimageAlert) {
            Button("Copy") {
                if let p = revealedPreimage { secureCopy(p) }
            }
            Button("Close", role: .cancel) {}
        } message: {
            Text(revealedPreimage ?? "Not found")
        }
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
                    Text("This contract contains \(balance) sats! Make sure you have saved the address and witness script.")
                } else {
                    Text("This action is irreversible.")
                }
            }
        }
        .task {
            await vm.refresh()
        }
    }

    private func htlcListRow(_ contract: Contract) -> some View {
        let funded = vm.fundedAmount(for: contract)
        let refundable = vm.isRefundable(contract)

        return HStack(spacing: 10) {
            Circle()
                .fill(refundable ? Color.orange : Color.teal)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(contract.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text("HTLC")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.teal.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.teal.opacity(0.1), in: Capsule())
                    if let idx = contract.keyIndex {
                        Text("#\(idx)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(refundable ? "Refundable" : "Locked")
                    .font(.system(size: 10))
                    .foregroundStyle(refundable ? .orange : .teal)
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

    private func htlcDetailPage(_ contract: Contract) -> some View {
        let funded = vm.fundedAmount(for: contract)

        return ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    HStack {
                        Image(systemName: statusIcon(for: contract))
                            .font(.title3)
                            .foregroundStyle(statusColor(for: contract))
                        Text(contract.name)
                            .font(.title2.bold())
                        Spacer()
                        Text(statusLabel(for: contract))
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(statusColor(for: contract).opacity(0.15), in: Capsule())
                            .foregroundStyle(statusColor(for: contract))
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

                    // Role + hash lock
                    VStack(alignment: .leading, spacing: 8) {
                        if contract.preimage != nil {
                            Text("Role: Sender (you hold the secret)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Role: Receiver (needs the secret)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let hashLock = contract.hashLock {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Hash Lock")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                Text(hashLock)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                            }
                        }

                        // Preimage status
                        if contract.preimage != nil {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.shield.fill")
                                    .foregroundStyle(.green)
                                Text("Preimage saved")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                        } else if vm.loadPreimage(for: contract) != nil {
                            HStack(spacing: 4) {
                                Image(systemName: "key.fill")
                                    .foregroundStyle(.blue)
                                Text("Preimage recoverable from keychain")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }
                            Button("Reveal preimage") {
                                revealedPreimage = vm.loadPreimage(for: contract)
                                showPreimageAlert = true
                            }
                            .font(.caption2.bold())
                            .foregroundStyle(.blue)
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text("Preimage not saved — risk of loss")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }

                        if let _ = contract.timeoutBlocks {
                            let remaining = vm.blocksRemaining(for: contract)
                            if remaining > 0 {
                                Text("Timeout: \(BlockDurationPicker.blocksToHumanTime(blocks: remaining))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Timeout reached — refund available")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

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

                    // Actions
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Button {
                                showDetail = false
                                vm.selectedContract = contract
                                vm.claimPreimage = ""
                                vm.claimDestination = ""
                                vm.spendError = nil
                                vm.spendResult = nil
                                showClaim = true
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.down.circle.fill")
                                    Text("Claim")
                                }
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.green, in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)

                            if vm.isRefundable(contract) {
                                Button {
                                    showDetail = false
                                    vm.selectedContract = contract
                                    vm.refundDestination = ""
                                    vm.spendError = nil
                                    vm.spendResult = nil
                                    showRefund = true
                                } label: {
                                    HStack {
                                        Image(systemName: "arrow.uturn.backward.circle.fill")
                                        Text("Refund")
                                    }
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
                                    .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Button {
                            UIPasteboard.general.string = contract.address
                            copiedId = "\(contract.id):address"
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedId = "" }
                        } label: {
                            HStack {
                                Image(systemName: copiedId == "\(contract.id):address" ? "checkmark" : "doc.on.doc")
                                Text(copiedId == "\(contract.id):address" ? "Copied!" : "Copy Address")
                            }
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)

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
        .navigationTitle("HTLC Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func statusIcon(for contract: Contract) -> String {
        vm.isRefundable(contract) ? "arrow.uturn.backward.circle.fill" : "lock.fill"
    }

    private func statusColor(for contract: Contract) -> Color {
        vm.isRefundable(contract) ? .orange : .yellow
    }

    private func statusLabel(for contract: Contract) -> String {
        vm.isRefundable(contract) ? "Refundable" : "Locked"
    }

    // MARK: - Create Sheet

    private var htlcReceiverKeyValid: Bool {
        let trimmed = vm.receiverPubkey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("xpub") || trimmed.hasPrefix("tpub") {
            return ExtendedPublicKey.fromBase58(trimmed) != nil
        }
        if trimmed.count == 66, let data = Data(hex: trimmed), data.count == 33 {
            return true
        }
        return false
    }

    private var htlcPreviewAddress: String? {
        guard htlcTimeoutValid, htlcReceiverKeyValid,
              let timeout = Int(vm.timeoutBlocks),
              let xpubStr = KeychainStore.shared.loadXpub(isTestnet: vm.isTestnet),
              let xpub = ExtendedPublicKey.fromBase58(xpubStr),
              let senderKey = xpub.derivePath([0, vm.keyIndex]) else { return nil }

        let receiverInput = vm.receiverPubkey.trimmingCharacters(in: .whitespacesAndNewlines)
        let receiverKey: Data
        if let rxpub = ExtendedPublicKey.fromBase58(receiverInput),
           let derived = rxpub.derivePath([0, 0]) {
            receiverKey = derived.key
        } else if let hexData = Data(hex: receiverInput), hexData.count == 33 {
            receiverKey = hexData
        } else {
            return nil
        }

        let placeholderHash = Data(repeating: 0, count: 32)
        let script = HTLCBuilder.htlcScript(
            receiverPubkey: receiverKey,
            senderPubkey: senderKey.key,
            hashLock: placeholderHash,
            timeoutBlocks: Int64(timeout)
        )
        return script.p2wshAddress(isTestnet: vm.isTestnet)
    }

    private var htlcTimeoutValid: Bool {
        guard let timeout = Int(vm.timeoutBlocks) else { return false }
        return timeout > vm.currentBlockHeight
    }

    private var createPage: some View {
            Form {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                        Text("The preimage will be generated automatically (32 random bytes). Keep it safe — it will be shown ONLY ONCE.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Name") {
                    TextField("My HTLC", text: $vm.name)
                }

                Section("Receiver public key") {
                    TextField("Hex or xpub", text: $vm.receiverPubkey)
                        .font(.system(.caption, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                BlockDurationPicker(
                    value: $vm.timeoutBlocks,
                    currentBlockHeight: vm.currentBlockHeight,
                    mode: .absoluteCLTV,
                    presets: [("1h", 6), ("6h", 36), ("1d", 144), ("1w", 1008)]
                )

                KeyIndexPicker(index: $vm.keyIndex, maxIndex: 19)

                if htlcTimeoutValid && !vm.receiverPubkey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Hash Lock (SHA256 of preimage)") {
                        Text("The hash lock will be computed automatically from the randomly generated preimage.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let address = htlcPreviewAddress {
                    Section("P2WSH address (preview)") {
                        Text(address)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                        Text("The final address will differ because the hash lock will be randomly generated.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = vm.error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Create HTLC") {
                        Task {
                            await vm.create()
                            if vm.createdContract != nil {
                                showCreate = false
                            }
                        }
                    }
                    .disabled(vm.name.isEmpty || vm.receiverPubkey.isEmpty || vm.timeoutBlocks.isEmpty || !htlcTimeoutValid)
                }
            }
            .navigationTitle("New HTLC")
            .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Claim Sheet

    private var claimPage: some View {
            Form {
                if let contract = vm.selectedContract {
                    Section("Contract") {
                        Text(contract.name).font(.headline)
                        Text(contract.address.prefix(20) + "...").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    }

                    Section("Preimage (hex)") {
                        TextField("32 bytes hex", text: $vm.claimPreimage)
                            .font(.system(.caption, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Section("Destination address") {
                        TextField("bc1q... / tb1q...", text: $vm.claimDestination)
                            .font(.system(.caption, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Section("Fee (sat/vB)") {
                        HStack {
                            Text(String(format: "%.0f", vm.spendFeeRate))
                                .font(.subheadline.monospacedDigit())
                            Slider(value: $vm.spendFeeRate, in: 1...100, step: 1)
                        }
                    }

                    if let error = vm.spendError {
                        Section { Text(error).foregroundStyle(.red).font(.caption) }
                    }

                    if let txid = vm.spendResult {
                        Section("Transaction broadcast") {
                            Text(txid).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                            Button("Copy txid") { UIPasteboard.general.string = txid }.font(.caption)
                        }
                    } else {
                        Section {
                            Button("Claim with preimage") {
                                Task {
                                    await vm.claimWithPreimage(contract: contract, preimage: vm.claimPreimage, destination: vm.claimDestination)
                                }
                            }
                            .disabled(vm.claimPreimage.isEmpty || vm.claimDestination.isEmpty || vm.isSpending)

                            if vm.isSpending {
                                HStack { ProgressView(); Text("Signing...").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Claim HTLC")
            .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Refund Sheet

    private var refundPage: some View {
            Form {
                if let contract = vm.selectedContract {
                    Section("Contract") {
                        Text(contract.name).font(.headline)
                        Text(contract.address.prefix(20) + "...").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        if let timeout = contract.timeoutBlocks {
                            Text("Timeout: block \(timeout)").font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Section("Destination address") {
                        TextField("bc1q... / tb1q...", text: $vm.refundDestination)
                            .font(.system(.caption, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Section("Fee (sat/vB)") {
                        HStack {
                            Text(String(format: "%.0f", vm.spendFeeRate))
                                .font(.subheadline.monospacedDigit())
                            Slider(value: $vm.spendFeeRate, in: 1...100, step: 1)
                        }
                    }

                    if let error = vm.spendError {
                        Section { Text(error).foregroundStyle(.red).font(.caption) }
                    }

                    if let txid = vm.spendResult {
                        Section("Transaction broadcast") {
                            Text(txid).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                            Button("Copy txid") { UIPasteboard.general.string = txid }.font(.caption)
                        }
                    } else {
                        Section {
                            Button("Refund") {
                                Task { await vm.refund(contract: contract, destination: vm.refundDestination) }
                            }
                            .disabled(vm.refundDestination.isEmpty || vm.isSpending)

                            if vm.isSpending {
                                HStack { ProgressView(); Text("Signing...").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Refund HTLC")
            .navigationBarTitleDisplayMode(.inline)
    }
}
