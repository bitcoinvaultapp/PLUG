import SwiftUI

struct ChannelView: View {
    @StateObject private var vm = ChannelVM()
    @State private var showCreate = false
    @State private var showCreated = false
    @State private var showClose = false
    @State private var showRefund = false
    @State private var selectedContract: Contract?
    @State private var showDetail = false
    @State private var copiedId = ""
    @State private var contractToDelete: Contract?
    @State private var showDeleteAlert = false

    var body: some View {
        List {
            VStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.green, .green.opacity(0.5))
                Text("2-of-2 payment channel with timeout refund.")
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
                    Image(systemName: "arrow.left.arrow.right.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No Channels")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Off-chain micropayments with timeout")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(vm.contracts) { contract in
                    channelListRow(contract)
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
        .navigationTitle("Payment Channels")
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
                channelDetailPage(contract)
            }
        }
        .navigationDestination(isPresented: $showCreate) { createPage }
        .sheet(isPresented: $showCreated) {
            ContractCreatedSheet(contract: vm.createdContract!, currentBlockHeight: vm.currentBlockHeight, onDismiss: { showCreated = false; vm.createdContract = nil })
        }
        .navigationDestination(isPresented: $showClose) { closePage }
        .navigationDestination(isPresented: $showRefund) { refundPage }
        .task {
            await vm.refresh()
        }
    }

    private func channelListRow(_ contract: Contract) -> some View {
        let funded = vm.fundedAmount(for: contract)
        let refundable = vm.isRefundable(contract)

        return HStack(spacing: 10) {
            Circle()
                .fill(refundable ? Color.orange : Color.green)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(contract.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text("P2MS")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.green.opacity(0.1), in: Capsule())
                    if let idx = contract.keyIndex {
                        Text("#\(idx)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(refundable ? "Refundable" : "Active")
                    .font(.system(size: 10))
                    .foregroundStyle(refundable ? .orange : .green)
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

    private func channelDetailPage(_ contract: Contract) -> some View {
        let funded = vm.fundedAmount(for: contract)

        return ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
                        Text("funded")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

                    // Parties & timeout
                    VStack(alignment: .leading, spacing: 8) {
                        if let senderPk = contract.senderPubkey {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sender").font(.caption.bold()).foregroundStyle(.secondary)
                                Text(senderPk.prefix(24) + "...").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                        if let receiverPk = contract.receiverPubkey {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Receiver").font(.caption.bold()).foregroundStyle(.secondary)
                                Text(receiverPk.prefix(24) + "...").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                        if let timeout = contract.timeoutBlocks {
                            let remaining = vm.blocksRemaining(for: contract)
                            if remaining > 0 {
                                Text("Timeout: \(BlockDurationPicker.blocksToHumanTime(blocks: remaining)) (block \(timeout))")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Timeout reached — refund available")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

                    // Address
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Address").font(.caption.bold()).foregroundStyle(.secondary)
                        Text(contract.address).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
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
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.blue, in: RoundedRectangle(cornerRadius: 12))
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
                            HStack { Image(systemName: "trash"); Text("Delete") }
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
        .navigationTitle("Channel Details")
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
                    Text("This contract contains \(balance) sats! Make sure you have saved the address and witness script.")
                } else {
                    Text("This action is irreversible.")
                }
            }
        }
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

    private var createPage: some View {
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
                    .disabled(vm.name.isEmpty || vm.receiverPubkey.isEmpty || vm.timeoutBlocks.isEmpty || !channelTimeoutValid)
                }
            }
            .navigationTitle("New channel")
            .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Close Sheet (Cooperative)

    private var closePage: some View {
            Form {
                if let contract = vm.selectedContract {
                    Section("Channel") {
                        Text(contract.name).font(.headline)
                        Text(contract.address.prefix(20) + "...").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
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
    }

    // MARK: - Refund Sheet (Unilateral)

    private var refundPage: some View {
            Form {
                if let contract = vm.selectedContract {
                    Section("Channel") {
                        Text(contract.name).font(.headline)
                        Text(contract.address.prefix(20) + "...").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
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
    }
}
