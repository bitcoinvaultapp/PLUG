import SwiftUI

struct InheritanceView: View {
    @StateObject private var vm = InheritanceVM()
    @State private var showCreate = false
    @State private var showCreated = false
    @State private var showClaim = false
    @State private var showKeepAlive = false
    @State private var selectedContract: Contract?
    @State private var showDetail = false
    @State private var copiedId = ""
    @State private var contractToDelete: Contract?
    @State private var showDeleteAlert = false

    var body: some View {
        List {
            VStack(spacing: 6) {
                Image(systemName: "person.line.dotted.person.fill")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.purple, .purple.opacity(0.5))
                Text("Your heir gets access only after a period of inactivity.")
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
                    Image(systemName: "person.2.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No Inheritance")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Set up a conditional transfer with CSV")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(vm.contracts) { contract in
                    inheritanceRow(contract)
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
        .navigationTitle("Inheritance")
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
                inheritanceDetailPage(contract)
            }
        }
        .navigationDestination(isPresented: $showCreate) { createPage }
        .navigationDestination(isPresented: $showKeepAlive) { keepAlivePage }
        .navigationDestination(isPresented: $showClaim) { claimPage }
        .sheet(isPresented: $showCreated) {
            ContractCreatedSheet(contract: vm.createdContract!, currentBlockHeight: vm.currentBlockHeight, onDismiss: { showCreated = false; vm.createdContract = nil })
        }
        .task {
            await vm.refresh()
        }
    }

    // MARK: - Contract Row

    private func inheritanceRow(_ contract: Contract) -> some View {
        let funded = vm.fundedAmount(for: contract)
        let csvInfo = contract.csvBlocks.map { BlockDurationPicker.blocksToHumanTime(blocks: $0) } ?? ""

        return HStack(spacing: 10) {
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(contract.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text("CSV")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.purple.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.purple.opacity(0.1), in: Capsule())
                    if let idx = contract.keyIndex {
                        Text("#\(idx)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 4) {
                    Text("Active").foregroundStyle(.green)
                    if !csvInfo.isEmpty {
                        Text("·").foregroundStyle(.quaternary)
                        Text(csvInfo).foregroundStyle(.secondary)
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

    private func inheritanceDetailPage(_ contract: Contract) -> some View {
        let funded = vm.fundedAmount(for: contract)

        return ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    HStack {
                        Image(systemName: "person.2.fill")
                            .font(.title3)
                            .foregroundStyle(.purple)
                        Text(contract.name)
                            .font(.title2.bold())
                        Spacer()
                        if let csv = contract.csvBlocks {
                            Text(BlockDurationPicker.blocksToHumanTime(blocks: csv))
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.purple.opacity(0.15), in: Capsule())
                                .foregroundStyle(.purple)
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

                    if let csv = contract.csvBlocks {
                        Text("Claimable ~\(BlockDurationPicker.blocksToDateString(blocks: csv)) after inactivity")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    // Parties
                    VStack(alignment: .leading, spacing: 8) {
                        if let ownerPk = contract.ownerPubkey {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Owner")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                Text(ownerPk.prefix(24) + "...")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text("Can spend at any time")
                                    .font(.caption2)
                                    .foregroundStyle(.purple.opacity(0.7))
                            }
                        }
                        if let heirPk = contract.heirPubkey {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Heir")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                Text(heirPk.prefix(24) + "...")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text("Can claim after inactivity")
                                    .font(.caption2)
                                    .foregroundStyle(.purple.opacity(0.7))
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

                    if let lastAlive = contract.lastKeptAlive {
                        Text("Last Keep Alive: \(Self.relativeTime(from: lastAlive))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let lastAlive = contract.lastKeptAlive, let csvBlocks = contract.csvBlocks {
                        if Date().timeIntervalSince(lastAlive) > TimeInterval(csvBlocks * 10 * 60) * 0.5 {
                            Label("Keep Alive recommended soon", systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }

                    // Share with heir
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Share with heir")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text("Your heir needs this information to claim the inheritance after the CSV delay expires.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)

                        Button {
                            var shareText = "Inheritance Contract"
                            shareText += "\nAddress: \(contract.address)"
                            shareText += "\nWitness Script: \(contract.script)"
                            if let csv = contract.csvBlocks { shareText += "\nCSV Delay: \(csv) blocks" }
                            UIPasteboard.general.string = shareText
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("Copy heir recovery info")
                            }
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.purple)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

                    // Actions
                    VStack(spacing: 10) {
                        Button {
                            showDetail = false
                            vm.selectedContract = contract
                            vm.spendError = nil
                            vm.spendResult = nil
                            showKeepAlive = true
                        } label: {
                            HStack {
                                Image(systemName: "heart.fill")
                                Text("Keep Alive")
                            }
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)

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
                                showDetail = false
                                vm.selectedContract = contract
                                vm.heirClaimAddress = ""
                                vm.spendError = nil
                                vm.spendResult = nil
                                showClaim = true
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.down.circle")
                                    Text("Claim")
                                }
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(.purple)
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
        .navigationTitle("Inheritance Details")
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
                    Text("This contract holds \(balance) sats! Make sure you have backed up the address and the witness script before deleting.")
                } else {
                    Text("This action is irreversible.")
                }
            }
        }
    }

    private static func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Create Sheet

    private var inheritancePreviewAddress: String? {
        guard inheritanceHeirKeyValid,
              let csv = Int(vm.csvBlocks), csv > 0,
              let xpubStr = KeychainStore.shared.loadXpub(isTestnet: vm.isTestnet),
              let xpub = ExtendedPublicKey.fromBase58(xpubStr),
              let ownerKey = xpub.derivePath([0, vm.keyIndex]) else { return nil }

        let heirInput = vm.heirXpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let heirPubkey: Data
        if let heirXpub = ExtendedPublicKey.fromBase58(heirInput),
           let derived = heirXpub.derivePath([0, 0]) {
            heirPubkey = derived.key
        } else if let hexData = Data(hex: heirInput), hexData.count == 33 {
            heirPubkey = hexData
        } else {
            return nil
        }

        let script = ScriptBuilder.inheritanceScript(
            ownerPubkey: ownerKey.key, heirPubkey: heirPubkey, csvBlocks: Int64(csv)
        )
        if vm.useTaproot {
            let internalKey = Secp256k1.xOnly(ownerKey.key)
            let ownerScript = ScriptBuilder().pushData(ownerKey.key).addOp(.op_checksig).script
            return TaprootBuilder.taprootAddress(
                internalKey: internalKey,
                scripts: [ownerScript, script.script],
                isTestnet: vm.isTestnet
            )
        }
        return script.p2wshAddress(isTestnet: vm.isTestnet)
    }

    private var inheritanceHeirKeyValid: Bool {
        let trimmed = vm.heirXpub.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("xpub") || trimmed.hasPrefix("tpub") {
            return ExtendedPublicKey.fromBase58(trimmed) != nil
        }
        if trimmed.count == 66, let data = Data(hex: trimmed), data.count == 33 {
            return true
        }
        return false
    }

    private var createPage: some View {
            Form {
                Section("Name") {
                    TextField("My Inheritance", text: $vm.name)
                }

                Section {
                    Toggle("Use Taproot (P2TR)", isOn: $vm.useTaproot)
                    if vm.useTaproot {
                        Text("Owner spends via key-path (private, cheap). Heir uses script-path after CSV delay.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("xpub/tpub or pubkey hex (33 bytes)", text: $vm.heirXpub)
                        .font(.system(.caption, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if !vm.heirXpub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !inheritanceHeirKeyValid {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text("Invalid format. Expected: 33 bytes hex (66 characters) or valid xpub/tpub.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Heir's key")
                }

                BlockDurationPicker(
                    value: $vm.csvBlocks,
                    currentBlockHeight: vm.currentBlockHeight,
                    mode: .relativeCSV,
                    presets: [("7d", 1008), ("30d", 4320), ("90d", 12960), ("180d", 25920), ("1y", 52560)]
                )

                if let csv = Int(vm.csvBlocks), csv > 0 {
                    Section("How it works") {
                        Text("The owner can reset the timer with Keep Alive. The heir can only spend after \(csv) blocks of inactivity.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                KeyIndexPicker(index: $vm.keyIndex, maxIndex: 19)

                if let address = inheritancePreviewAddress {
                    Section(vm.useTaproot ? "P2TR Address (preview)" : "P2WSH Address (preview)") {
                        Text(address)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                if let error = vm.error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Create Inheritance") {
                        Task {
                            await vm.create()
                            if vm.createdContract != nil { showCreate = false }
                        }
                    }
                    .disabled(vm.name.isEmpty || vm.csvBlocks.isEmpty || vm.heirXpub.isEmpty || !inheritanceHeirKeyValid)
                }
            }
        .navigationTitle("New Inheritance")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            if vm.createdContract != nil { showCreated = true }
        }
    }

    // MARK: - Keep Alive Sheet

    private var keepAlivePage: some View {
            Form {
                if let contract = vm.selectedContract {
                    Section("Contract") {
                        Text(contract.name)
                            .font(.headline)
                        Text(contract.address)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        let funded = vm.fundedAmount(for: contract)
                        Text("Current balance: \(BalanceUnit.format(funded))")
                            .font(.subheadline.monospacedDigit())
                    } header: {
                        Text("Balance")
                    }

                    Section {
                        HStack {
                            Text(String(format: "%.0f", vm.spendFeeRate))
                                .font(.subheadline.monospacedDigit())
                            Slider(value: $vm.spendFeeRate, in: 1...100, step: 1)
                        }
                        if vm.spendFeeRate > 100 {
                            Label("Very high fee rate!", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } header: {
                        Text("Fee (sat/vB)")
                    } footer: {
                        Text("Funds will be sent back to the same Inheritance address, minus fees. This resets the heir's CSV counter.")
                    }

                    if let error = vm.spendError {
                        Section {
                            Text(error).foregroundStyle(.red).font(.caption)
                        }
                    }

                    if let txid = vm.spendResult {
                        Section("Result") {
                            Text("Keep Alive successful!")
                                .foregroundStyle(.green)
                            Text(txid)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                            Button("Close") {
                                showKeepAlive = false
                                Task { await vm.refresh() }
                            }
                        }
                    } else {
                        Section {
                            Button {
                                Task { await vm.keepAlive(contract: contract) }
                            } label: {
                                HStack {
                                    if vm.isSpending {
                                        ProgressView()
                                            .padding(.trailing, 4)
                                    }
                                    Image(systemName: "heart.fill")
                                    Text("Confirm Keep Alive")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .disabled(vm.isSpending)
                        }
                    }
                }
            }
        .navigationTitle("Keep Alive")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Claim Sheet (Heir)

    private var claimPage: some View {
            Form {
                if let contract = vm.selectedContract {
                    Section("Contract") {
                        Text(contract.name)
                            .font(.headline)
                        Text(contract.address.prefix(20) + "...").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                            .font(.subheadline.monospacedDigit())
                        if let csv = contract.csvBlocks {
                            Text("CSV: \(csv) blocks")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Destination address") {
                        TextField("bc1q... / tb1q...", text: $vm.heirClaimAddress)
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
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Success")
                                    .font(.headline)
                                    .foregroundStyle(.green)
                            }
                            Text(txid)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                            Button("Copy txid") {
                                UIPasteboard.general.string = txid
                            }
                            .font(.caption)

                            Button("Done") {
                                vm.spendResult = nil
                                showClaim = false
                            }
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.green, in: RoundedRectangle(cornerRadius: 10))
                            .padding(.top, 8)
                        }
                    } else {
                        Section {
                            Button("Claim Inheritance") {
                                Task {
                                    await vm.heirClaim(
                                        contract: contract,
                                        destinationAddress: vm.heirClaimAddress
                                    )
                                }
                            }
                            .disabled(vm.heirClaimAddress.isEmpty || vm.isSpending)

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
        .navigationTitle("Claim Inheritance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
