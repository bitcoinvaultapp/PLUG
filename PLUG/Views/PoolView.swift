import SwiftUI

struct PoolView: View {
    @StateObject private var vm = PoolVM()
    @State private var showCreate = false
    @State private var showCreated = false
    @State private var showImportPSBT = false
    @State private var participantLabels: [String] = ["", ""]
    @State private var copiedId = ""
    @State private var contractToDelete: Contract?
    @State private var showDeleteAlert = false

    @State private var selectedContract: Contract?
    @State private var showDetail = false

    var body: some View {
        List {
            VStack(spacing: 6) {
                Image(systemName: "person.3.sequence.fill")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.blue, .blue.opacity(0.7), .blue.opacity(0.4))
                Text("M-of-N multisig. Multiple signatures required to spend.")
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
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No Pool")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Create an M-of-N multisig")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(vm.contracts) { contract in
                    poolListRow(contract)
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
        .navigationTitle("Multisig Pool")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Pool") { showCreate = true }
                    Button("Import PSBT") { showImportPSBT = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(isPresented: $showDetail) {
            if let contract = selectedContract {
                poolDetailPage(contract)
            }
        }
        .navigationDestination(isPresented: $showCreate) { createPage }
        .sheet(isPresented: $showCreated) {
            ContractCreatedSheet(contract: vm.createdContract!, currentBlockHeight: 0, onDismiss: { showCreated = false; vm.createdContract = nil })
        }
        .navigationDestination(isPresented: $showImportPSBT) { importPSBTPage }
        .task {
            await vm.refresh()
        }
    }

    private func poolListRow(_ contract: Contract) -> some View {
        let funded = vm.fundedAmount(for: contract)
        let mOfN: String = {
            if let m = contract.multisigM, let n = contract.multisigPubkeys?.count {
                return "\(m)-of-\(n)"
            }
            return "Active"
        }()

        return HStack(spacing: 10) {
            Circle()
                .fill(Color.blue)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(contract.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text("MULTI")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.blue.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.blue.opacity(0.1), in: Capsule())
                    if let idx = contract.keyIndex {
                        Text("#\(idx)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(mOfN)
                    .font(.system(size: 10))
                    .foregroundStyle(.blue)
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

    private func poolDetailPage(_ contract: Contract) -> some View {
        let funded = vm.fundedAmount(for: contract)

        return ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "person.3.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                        Text(contract.name)
                            .font(.title2.bold())
                        Spacer()
                        if let m = contract.multisigM, let n = contract.multisigPubkeys?.count {
                            Text("\(m)-of-\(n)")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.blue.opacity(0.15), in: Capsule())
                                .foregroundStyle(.blue)
                        }
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

                    // Signers
                    if let keys = contract.multisigPubkeys {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Signers")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            ForEach(Array(keys.enumerated()), id: \.offset) { i, key in
                                Text("Signer \(i+1): \(key.prefix(24))...")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }

                    // Address
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Address").font(.caption.bold()).foregroundStyle(.secondary)
                        Text(contract.address).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

                    // Spend (export PSBT for co-signers)
                    if funded > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Spend").font(.caption.bold()).foregroundStyle(.secondary)
                            Text("Create a PSBT, sign with your key, then share with co-signers.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)

                            NavigationLink {
                                PoolSpendPage(contract: contract, vm: vm)
                            } label: {
                                HStack {
                                    Image(systemName: "signature")
                                    Text("Create Spend Transaction")
                                }
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Actions
                    VStack(spacing: 10) {
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
        .navigationTitle("Pool Details")
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
                    Text("This contract holds \(balance) sats! Ensure you have the address and witness script backed up.")
                } else {
                    Text("This action is irreversible.")
                }
            }
        }
    }

    // MARK: - Create Sheet

    private var poolMValid: Bool {
        guard let mInt = Int(vm.m), mInt > 0 else { return false }
        let filledKeys = vm.pubkeys.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return mInt <= filledKeys.count
    }

    private var poolDuplicateKeys: Bool {
        let trimmed = vm.pubkeys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Set(trimmed).count != trimmed.count
    }

    private var poolSortedKeys: [String] {
        let parsed: [Data] = vm.pubkeys.compactMap { pk in
            let trimmed = pk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let xpub = ExtendedPublicKey.fromBase58(trimmed),
               let derived = xpub.derivePath([0, 0]) {
                return derived.key
            } else if let hexData = Data(hex: trimmed), hexData.count == 33 {
                return hexData
            }
            return nil
        }
        return parsed.sorted(by: { $0.hex < $1.hex }).map { $0.hex }
    }

    private var createPage: some View {
            Form {
                Section("Name") {
                    TextField("My Pool", text: $vm.name)
                }

                Section {
                    TextField("2", text: $vm.m)
                        .keyboardType(.numberPad)

                    if let mInt = Int(vm.m) {
                        let filledKeys = vm.pubkeys.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        if mInt > filledKeys.count && filledKeys.count > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text("M (\(mInt)) cannot be greater than N (\(filledKeys.count))")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        if mInt <= 0 {
                            Text("M must be greater than 0")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Threshold (M)")
                }

                Section {
                    ForEach(vm.pubkeys.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 4) {
                            if i < participantLabels.count {
                                TextField("Participant \(i+1) (ex: Alice)", text: Binding(
                                    get: { i < participantLabels.count ? participantLabels[i] : "" },
                                    set: { newVal in
                                        while participantLabels.count <= i { participantLabels.append("") }
                                        participantLabels[i] = newVal
                                    }
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            TextField("Pubkey \(i+1)", text: $vm.pubkeys[i])
                                .font(.system(.caption, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }

                    HStack {
                        Button("Add a key") {
                            vm.addPubkeyField()
                            participantLabels.append("")
                        }
                        Spacer()
                        if vm.pubkeys.count > 2 {
                            Button("Remove") {
                                vm.removePubkeyField(at: vm.pubkeys.count - 1)
                                if participantLabels.count > 2 {
                                    participantLabels.removeLast()
                                }
                            }
                            .foregroundStyle(.red)
                        }
                    }

                    if poolDuplicateKeys {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text("Public keys must be unique")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Public keys (\(vm.pubkeys.count))")
                }

                if !poolSortedKeys.isEmpty && poolSortedKeys.count >= 2 {
                    Section("BIP67 order (deterministic sort)") {
                        ForEach(Array(poolSortedKeys.enumerated()), id: \.offset) { i, key in
                            Text("\(i+1). \(key.prefix(20))...\(key.suffix(8))")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text("Keys are BIP67 sorted. Deterministic ordering ensures all signers generate the same address.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = vm.error {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section {
                    Button("Create Pool") {
                        Task {
                            await vm.create()
                            if vm.createdContract != nil { showCreate = false }
                        }
                    }
                    .disabled(!poolMValid || poolDuplicateKeys || vm.name.isEmpty)
                }
            }
            .navigationTitle("New Pool")
            .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Import PSBT Sheet

    private var importPSBTPage: some View {
        Form {
            Section("PSBT Base64") {
                TextEditor(text: $vm.importedPSBTBase64)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 120)
            }

            Button("Import & Validate") {
                vm.importPSBT()
            }

            if vm.parsedPSBT != nil {
                Section("Imported PSBT") {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Valid PSBT").foregroundStyle(.green)
                    }

                    // Select which pool contract to sign for
                    if vm.contracts.isEmpty {
                        Text("No pool contracts found. Create one first.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(vm.contracts) { contract in
                            Button {
                                Task { await vm.signImportedPSBT(contract: contract) }
                            } label: {
                                HStack {
                                    if vm.isSigning {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "signature")
                                    }
                                    Text("Sign as \(contract.name)")
                                        .font(.subheadline.bold())
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                            .disabled(vm.isSigning)
                        }
                    }
                }

                // Signed result
                if let signedPSBT = vm.signedPSBTBase64 {
                    Section("Signed PSBT") {
                        HStack {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            Text("Signature added").foregroundStyle(.green)
                        }
                        Text("Share this with the next co-signer, or broadcast if enough signatures collected.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(signedPSBT.prefix(60) + "...")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)

                        Button("Copy Signed PSBT") {
                            UIPasteboard.general.string = signedPSBT
                        }
                        .font(.caption.bold())
                    }
                }

                Section {
                    Button("Copy Original PSBT") {
                        UIPasteboard.general.string = vm.importedPSBTBase64
                    }
                    .font(.caption)
                }
            }

            if let error = vm.error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Import PSBT")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Pool Spend Page

private struct PoolSpendPage: View {
    let contract: Contract
    @ObservedObject var vm: PoolVM
    @State private var destination = ""
    @State private var amount = ""
    @State private var feeRate: Double = 2.0
    @State private var isBuilding = false
    @State private var psbtBase64: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Balance
                VStack(spacing: 4) {
                    Text("Available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(BalanceUnit.format(vm.fundedAmount(for: contract)))
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                }

                // Destination
                VStack(alignment: .leading, spacing: 6) {
                    Text("Destination address")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("bc1q...", text: $destination)
                        .font(.system(size: 14, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                // Amount
                VStack(alignment: .leading, spacing: 6) {
                    Text("Amount (sats)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("0", text: $amount)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .keyboardType(.numberPad)
                }

                // Fee
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Fee rate")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(feeRate)) sat/vB")
                            .font(.system(size: 12, design: .monospaced))
                    }
                    Slider(value: $feeRate, in: 1...200, step: 1)
                        .tint(Color.btcOrange)
                }

                // Build PSBT
                Button {
                    buildPSBT()
                } label: {
                    HStack {
                        if isBuilding {
                            ProgressView().controlSize(.small)
                        }
                        Text("Build PSBT")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                }
                .disabled(destination.isEmpty || amount.isEmpty || isBuilding)

                // Result
                if let psbt = psbtBase64 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PSBT Ready")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                        Text("Share this PSBT with co-signers. Each signer adds their signature, then the last one broadcasts.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(psbt.prefix(60) + "...")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)

                        Button("Copy PSBT") {
                            UIPasteboard.general.string = psbt
                        }
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.blue)
                    }
                }

                if let err = error {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            .padding()
        }
        .navigationTitle("Spend Pool")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func buildPSBT() {
        isBuilding = true
        error = nil
        Task {
            defer { isBuilding = false }
            do {
                guard let amt = UInt64(amount) else { error = "Invalid amount"; return }
                let utxos = try await MempoolAPI.shared.getAddressUTXOs(address: contract.address)
                guard !utxos.isEmpty else { error = "No UTXOs"; return }

                let psbtData = try SpendManager.buildPoolSpendPSBT(
                    contract: contract, utxos: utxos,
                    destinationAddress: destination.trimmingCharacters(in: .whitespacesAndNewlines),
                    amount: amt, feeRate: feeRate,
                    isTestnet: NetworkConfig.shared.isTestnet
                )
                psbtBase64 = psbtData.base64EncodedString()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
