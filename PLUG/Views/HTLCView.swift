import SwiftUI

struct HTLCView: View {
    @StateObject private var vm = HTLCVM()
    @State private var showCreate = false
    @State private var showCreated = false
    @State private var showClaim = false
    @State private var showRefund = false
    @State private var revealedPreimage: String?
    @State private var showPreimageAlert = false
    @State private var copiedId = ""
    @State private var contractToDelete: Contract?
    @State private var showDeleteAlert = false

    var body: some View {
            List {
                if vm.contracts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.rotation")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No HTLCs")
                            .font(.headline)
                        Text("Conditional payments with hash preimage")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    ForEach(vm.contracts) { contract in
                        htlcRow(contract)
                    }
                    .onDelete { indexSet in
                        if let i = indexSet.first {
                            contractToDelete = vm.contracts[i]
                            showDeleteAlert = true
                        }
                    }
                }
            }
            .navigationTitle("Hash Time-Lock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showCreate = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreate, onDismiss: { if vm.createdContract != nil { showCreated = true } }) { createSheet }
            .sheet(isPresented: $showCreated) {
                ContractCreatedSheet(contract: vm.createdContract!, currentBlockHeight: vm.currentBlockHeight, preimage: vm.generatedPreimage, onDismiss: { showCreated = false; vm.createdContract = nil })
            }
            .sheet(isPresented: $showClaim) { claimSheet }
            .sheet(isPresented: $showRefund) { refundSheet }
            .alert("Preimage", isPresented: $showPreimageAlert) {
                Button("Copy") {
                    if let p = revealedPreimage {
                        UIPasteboard.general.string = p
                    }
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
                    }
                }
            } message: {
                if let c = contractToDelete {
                    let balance = vm.fundedAmount(for: c)
                    if balance > 0 {
                        Text("This contract contains \(balance) sats! Make sure you have saved the address and witness script before deleting. Funds will be unrecoverable without this information.")
                    } else {
                        Text("This action is irreversible.")
                    }
                }
            }
            .refreshable { await vm.refresh() }
            .task { await vm.refresh() }
    }

    private func htlcRow(_ contract: Contract) -> some View {
        let funded = vm.fundedAmount(for: contract)
        let target = contract.amount
        let progress = vm.progress(for: contract)
        let pct = Int(progress * 100)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: statusIcon(for: contract))
                    .foregroundStyle(statusColor(for: contract))
                Text(contract.name)
                    .font(.headline)
                Spacer()
                Text(statusLabel(for: contract))
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor(for: contract).opacity(0.15), in: Capsule())
                    .foregroundStyle(statusColor(for: contract))
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
                    .foregroundStyle(progress >= 1.0 ? .green : .yellow)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(progress >= 1.0 ? Color.green : Color.yellow)
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

            // Party roles
            if contract.preimage != nil {
                Text("Sender: you hold the secret")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Receiver: needs the secret")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let hashLock = contract.hashLock {
                Text("Hash Lock (public): \(hashLock.prefix(24))...")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Preimage warning
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(BlockDurationPicker.blocksToHumanTime(blocks: remaining))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Refund available ~\(BlockDurationPicker.blocksToDateString(blocks: remaining))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Timeout reached — refund available")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
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
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.green.opacity(0.15))
                        .foregroundStyle(.green)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    if vm.isRefundable(contract) {
                        Button {
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
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.orange.opacity(0.15))
                            .foregroundStyle(.orange)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    UIPasteboard.general.string = contract.address
                    copiedId = "\(contract.id):address"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if copiedId == "\(contract.id):address" {
                            copiedId = ""
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: copiedId == "\(contract.id):address" ? "checkmark" : "doc.on.doc")
                        Text(copiedId == "\(contract.id):address" ? "Copied!" : "Copy address")
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
        .padding(.vertical, 4)
    }

    private func statusIcon(for contract: Contract) -> String {
        if vm.isRefundable(contract) {
            return "arrow.uturn.backward.circle.fill"
        }
        return "lock.fill"
    }

    private func statusColor(for contract: Contract) -> Color {
        if vm.isRefundable(contract) {
            return .orange
        }
        return .yellow
    }

    private func statusLabel(for contract: Contract) -> String {
        if vm.isRefundable(contract) {
            return "Refundable"
        }
        return "Locked"
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

        // Use a deterministic placeholder hash lock for preview (all zeros)
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

    private var htlcPreviewHashLock: String? {
        // Show a preview SHA256 hash of a placeholder preimage to illustrate the concept
        // The real preimage+hash will be generated at creation time
        guard htlcTimeoutValid,
              !vm.receiverPubkey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Generate a deterministic preview: SHA256 of "preview" for display purposes
        return "Will be generated automatically at creation"
    }

    private var createSheet: some View {
        NavigationStack {
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

                Section("Amount (sats)") {
                    TextField("Amount", text: $vm.amount)
                        .keyboardType(.numberPad)
                }

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
                    .disabled(vm.name.isEmpty || vm.receiverPubkey.isEmpty || vm.timeoutBlocks.isEmpty || vm.amount.isEmpty || !htlcTimeoutValid)
                }
            }
            .navigationTitle("New HTLC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCreate = false }
                }
            }
        }
    }

    // MARK: - Claim Sheet

    private var claimSheet: some View {
        NavigationStack {
            Form {
                if let contract = vm.selectedContract {
                    Section("Contract") {
                        Text(contract.name).font(.headline)
                        Text("\(contract.amount) sats").font(.subheadline.monospacedDigit())
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
                        if vm.spendFeeRate > 100 {
                            Label("Very high fee rate! Make sure you are not confusing sat/vB with sat/kB.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    if let error = vm.spendError {
                        Section {
                            Text(error).foregroundStyle(.red).font(.caption)
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
                    } else {
                        Section {
                            Button("Claim with preimage") {
                                Task {
                                    await vm.claimWithPreimage(
                                        contract: contract,
                                        preimage: vm.claimPreimage,
                                        destination: vm.claimDestination
                                    )
                                }
                            }
                            .disabled(vm.claimPreimage.isEmpty || vm.claimDestination.isEmpty || vm.isSpending)

                            if vm.isSpending {
                                HStack {
                                    ProgressView()
                                    Text("Signing in progress...")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Claim HTLC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showClaim = false }
                }
            }
        }
    }

    // MARK: - Refund Sheet

    private var refundSheet: some View {
        NavigationStack {
            Form {
                if let contract = vm.selectedContract {
                    Section("Contract") {
                        Text(contract.name).font(.headline)
                        Text("\(contract.amount) sats").font(.subheadline.monospacedDigit())
                        if let timeout = contract.timeoutBlocks {
                            Text("Timeout: block \(timeout)")
                                .font(.caption).foregroundStyle(.secondary)
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
                        if vm.spendFeeRate > 100 {
                            Label("Very high fee rate! Make sure you are not confusing sat/vB with sat/kB.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    if let error = vm.spendError {
                        Section {
                            Text(error).foregroundStyle(.red).font(.caption)
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
                    } else {
                        Section {
                            Button("Refund") {
                                Task {
                                    await vm.refund(
                                        contract: contract,
                                        destination: vm.refundDestination
                                    )
                                }
                            }
                            .disabled(vm.refundDestination.isEmpty || vm.isSpending)

                            if vm.isSpending {
                                HStack {
                                    ProgressView()
                                    Text("Signing in progress...")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Refund HTLC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showRefund = false }
                }
            }
        }
    }
}
