import SwiftUI

struct ChannelView: View {
    @StateObject private var vm = ChannelVM()
    @State private var showCreate = false
    @State private var showCreated = false
    @State private var showClose = false
    @State private var showRefund = false
    @State private var copiedId = ""
    @State private var contractToDelete: Contract?
    @State private var showDeleteAlert = false

    var body: some View {
            List {
                if vm.contracts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.left.arrow.right.circle")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No channels")
                            .font(.headline)
                        Text("Off-chain micropayments with timeout")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    ForEach(vm.contracts) { contract in
                        channelRow(contract)
                    }
                    .onDelete { indexSet in
                        if let i = indexSet.first {
                            contractToDelete = vm.contracts[i]
                            showDeleteAlert = true
                        }
                    }
                }
            }
            .navigationTitle("Payment Channels")
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
                ContractCreatedSheet(contract: vm.createdContract!, currentBlockHeight: vm.currentBlockHeight, onDismiss: { showCreated = false; vm.createdContract = nil })
            }
            .sheet(isPresented: $showClose) { closeSheet }
            .sheet(isPresented: $showRefund) { refundSheet }
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

    private func channelRow(_ contract: Contract) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: statusIcon(for: contract))
                    .foregroundStyle(statusColor(for: contract))
                Text(contract.name)
                    .font(.headline)
            }

            HStack {
                Text("\(contract.amount) sats")
                    .font(.subheadline.monospacedDigit())
                Spacer()
                Text(statusLabel(for: contract))
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor(for: contract).opacity(0.15), in: Capsule())
                    .foregroundStyle(statusColor(for: contract))
            }

            // Funded balance with progress bar
            let funded = vm.fundedAmount(for: contract)
            let target = contract.amount
            let progress = vm.progress(for: contract)
            let pct = Int(progress * 100)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(funded) / \(target) sats")
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Text("\(pct)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: progress)
                    .tint(progress >= 1.0 ? .green : .orange)
            }

            if let confs = vm.confirmations[contract.address], confs > 0 {
                let label = confs >= 6 ? "Confirmed" : "\(confs)/6 confirmations"
                let color: Color = confs >= 6 ? .green : .orange
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(color)
            }

            if let senderPk = contract.senderPubkey {
                Text("Sender: \(senderPk.prefix(16))...")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let receiverPk = contract.receiverPubkey {
                Text("Receiver: \(receiverPk.prefix(16))...")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let timeout = contract.timeoutBlocks {
                let remaining = vm.blocksRemaining(for: contract)
                if remaining > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(BlockDurationPicker.blocksToHumanTime(blocks: remaining)) remaining (block \(timeout))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Estimated: \(BlockDurationPicker.blocksToDateString(blocks: remaining))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Timeout reached (block \(timeout))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            // Close type explanation
            if vm.isRefundable(contract) {
                Text("Timeout reached — unilateral refund available")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                Text("Cooperative close (cheap) or unilateral refund after timeout")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        vm.selectedContract = contract
                        vm.closesSenderAmount = ""
                        vm.closesReceiverAmount = ""
                        vm.closeSenderAddress = ""
                        vm.closeReceiverAddress = ""
                        vm.spendError = nil
                        vm.spendResult = nil
                        showClose = true
                    } label: {
                        HStack {
                            Image(systemName: "xmark.circle.fill")
                            Text("Close")
                        }
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.15))
                        .foregroundStyle(.blue)
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
        return "bolt.fill"
    }

    private func statusColor(for contract: Contract) -> Color {
        if vm.isRefundable(contract) {
            return .orange
        }
        return .green
    }

    private func statusLabel(for contract: Contract) -> String {
        if vm.isRefundable(contract) {
            return "Refundable"
        }
        return "Active"
    }

    // MARK: - Create Sheet

    private var channelReceiverKeyValid: Bool {
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

    private var channelPreviewAddress: String? {
        guard channelTimeoutValid, channelReceiverKeyValid,
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

        let script = PaymentChannelBuilder.channelScript(
            senderPubkey: senderKey.key,
            receiverPubkey: receiverKey,
            timeoutBlocks: Int64(timeout)
        )
        return script.p2wshAddress(isTestnet: vm.isTestnet)
    }

    private var channelTimeoutValid: Bool {
        guard let timeout = Int(vm.timeoutBlocks) else { return false }
        return timeout > vm.currentBlockHeight
    }

    private var createSheet: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                        Text("Cooperative close (2-of-2) or unilateral refund after timeout")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Name") {
                    TextField("My channel", text: $vm.name)
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
                    presets: [("1d", 144), ("1w", 1008), ("1mo", 4320)]
                )

                Section("Amount (sats)") {
                    TextField("Amount", text: $vm.amount)
                        .keyboardType(.numberPad)
                }

                KeyIndexPicker(index: $vm.keyIndex, maxIndex: 19)

                if let address = channelPreviewAddress {
                    Section("P2WSH address (preview)") {
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
                    Button("Open channel") {
                        Task {
                            await vm.create()
                            if vm.createdContract != nil {
                                showCreate = false
                            }
                        }
                    }
                    .disabled(vm.name.isEmpty || vm.receiverPubkey.isEmpty || vm.timeoutBlocks.isEmpty || vm.amount.isEmpty || !channelTimeoutValid)
                }
            }
            .navigationTitle("New channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCreate = false }
                }
            }
        }
    }

    // MARK: - Close Sheet (Cooperative)

    private var closeSheet: some View {
        NavigationStack {
            Form {
                if let contract = vm.selectedContract {
                    Section("Channel") {
                        Text(contract.name).font(.headline)
                        Text("\(contract.amount) sats").font(.subheadline.monospacedDigit())
                    }

                    Section("Sender amount (sats)") {
                        TextField("Sats for sender", text: $vm.closesSenderAmount)
                            .keyboardType(.numberPad)
                    }

                    Section("Sender address") {
                        TextField("bc1q... / tb1q...", text: $vm.closeSenderAddress)
                            .font(.system(.caption, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Section("Receiver amount (sats)") {
                        TextField("Sats for receiver", text: $vm.closesReceiverAmount)
                            .keyboardType(.numberPad)
                    }

                    Section("Receiver address") {
                        TextField("bc1q... / tb1q...", text: $vm.closeReceiverAddress)
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
                            Button("Close channel") {
                                Task {
                                    let sAmt = UInt64(vm.closesSenderAmount) ?? 0
                                    let rAmt = UInt64(vm.closesReceiverAmount) ?? 0
                                    await vm.cooperativeClose(
                                        contract: contract,
                                        senderAmount: sAmt,
                                        receiverAmount: rAmt,
                                        senderAddress: vm.closeSenderAddress,
                                        receiverAddress: vm.closeReceiverAddress
                                    )
                                }
                            }
                            .disabled(
                                vm.closeSenderAddress.isEmpty ||
                                vm.closeReceiverAddress.isEmpty ||
                                vm.closesSenderAmount.isEmpty ||
                                vm.closesReceiverAmount.isEmpty ||
                                vm.isSpending
                            )

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
            .navigationTitle("Close Channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showClose = false }
                }
            }
        }
    }

    // MARK: - Refund Sheet (Unilateral)

    private var refundSheet: some View {
        NavigationStack {
            Form {
                if let contract = vm.selectedContract {
                    Section("Channel") {
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
                                    await vm.unilateralRefund(
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
            .navigationTitle("Refund Channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showRefund = false }
                }
            }
        }
    }
}
