import SwiftUI

struct InheritanceView: View {
    @StateObject private var vm = InheritanceVM()
    @State private var showCreate = false
    @State private var showCreated = false
    @State private var showClaim = false
    @State private var showKeepAlive = false
    @State private var copiedId = ""
    @State private var contractToDelete: Contract?
    @State private var showDeleteAlert = false

    var body: some View {
        NavigationStack {
            List {
                PlugHeader(pageName: "Inheritance")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                if vm.contracts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.2.circle")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No Inheritance")
                            .font(.headline)
                        Text("Set up a conditional transfer with CSV")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    ForEach(vm.contracts) { contract in
                        inheritanceRow(contract)
                    }
                    .onDelete { indexSet in
                        if let i = indexSet.first {
                            contractToDelete = vm.contracts[i]
                            showDeleteAlert = true
                        }
                    }
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
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
            .sheet(isPresented: $showKeepAlive) { keepAliveSheet }
            .sheet(isPresented: $showClaim) { claimSheet }
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
                        Text("This contract holds \(balance) sats! Make sure you have backed up the address and the witness script before deleting. Funds will be unrecoverable without this information.")
                    } else {
                        Text("This action is irreversible.")
                    }
                }
            }
            .refreshable { await vm.refresh() }
            .task { await vm.refresh() }
        }
    }

    private static func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func inheritanceRow(_ contract: Contract) -> some View {
        let funded = vm.fundedAmount(for: contract)
        let target = contract.amount
        let progress = vm.progress(for: contract)
        let pct = Int(progress * 100)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.purple)
                Text(contract.name)
                    .font(.headline)
                Spacer()
                if let csv = contract.csvBlocks {
                    Text(BlockDurationPicker.blocksToHumanTime(blocks: csv))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let csv = contract.csvBlocks {
                Text("Claimable ~\(BlockDurationPicker.blocksToDateString(blocks: csv)) after inactivity")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(progress >= 1.0 ? .green : .purple)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(progress >= 1.0 ? Color.green : Color.purple)
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

            if let ownerPk = contract.ownerPubkey {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Owner: \(ownerPk.prefix(16))...")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("Can spend at any time")
                        .font(.caption2)
                        .foregroundStyle(.purple.opacity(0.7))
                }
            }

            if let heirPk = contract.heirPubkey {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Heir: \(heirPk.prefix(16))...")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("Can claim after inactivity")
                        .font(.caption2)
                        .foregroundStyle(.purple.opacity(0.7))
                }
            }

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

            // Action buttons — full width for easy tapping
            VStack(spacing: 8) {
                Button {
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
                    .padding(.vertical, 10)
                    .background(Color.blue.opacity(0.15))
                    .foregroundStyle(.blue)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(vm.isSpending)

                HStack(spacing: 8) {
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
                        .padding(.vertical, 8)
                        .background(Color.purple.opacity(0.15))
                        .foregroundStyle(.purple)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Use 'Keep Alive' regularly to prevent the heir from claiming")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .italic()

            if vm.isSpending {
                HStack {
                    ProgressView()
                    Text("Transaction in progress...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let result = vm.spendResult {
                Text("TX: \(result.prefix(16))...")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
            }

            if let error = vm.spendError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Create Sheet

    private var inheritancePreviewAddress: String? {
        guard inheritanceHeirKeyValid,
              let csv = Int(vm.csvBlocks), csv > 0,
              let xpubStr = KeychainStore.shared.loadXpub(isTestnet: vm.isTestnet),
              let xpub = ExtendedPublicKey.fromBase58(xpubStr),
              let ownerKey = xpub.derivePath([0, 0]) else { return nil }

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
        // Valid xpub/tpub
        if trimmed.hasPrefix("xpub") || trimmed.hasPrefix("tpub") {
            return ExtendedPublicKey.fromBase58(trimmed) != nil
        }
        // Valid 33-byte compressed pubkey hex (66 hex chars)
        if trimmed.count == 66, let data = Data(hex: trimmed), data.count == 33 {
            return true
        }
        return false
    }

    private var createSheet: some View {
        NavigationStack {
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

                Section("Amount (sats)") {
                    TextField("Amount", text: $vm.amount)
                        .keyboardType(.numberPad)
                }

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
                    .disabled(vm.name.isEmpty || vm.csvBlocks.isEmpty || vm.heirXpub.isEmpty || vm.amount.isEmpty || !inheritanceHeirKeyValid)
                }
            }
            .navigationTitle("New Inheritance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCreate = false }
                }
            }
        }
    }

    // MARK: - Keep Alive Sheet

    private var keepAliveSheet: some View {
        NavigationStack {
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
                        Text("Current balance: \(funded) sats")
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showKeepAlive = false }
                }
            }
        }
    }

    // MARK: - Claim Sheet (Heir)

    private var claimSheet: some View {
        NavigationStack {
            Form {
                if let contract = vm.selectedContract {
                    Section("Contract") {
                        Text(contract.name)
                            .font(.headline)
                        Text("\(contract.amount) sats")
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showClaim = false }
                }
            }
        }
    }
}
