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

    var body: some View {
            List {
                Section {
                    if vm.contracts.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("No Pool")
                                .font(.headline)
                            Text("Create an M-of-N multisig")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    } else {
                        ForEach(vm.contracts) { contract in
                            poolRow(contract)
                        }
                        .onDelete { indexSet in
                            if let i = indexSet.first {
                                contractToDelete = vm.contracts[i]
                                showDeleteAlert = true
                            }
                        }
                    }
                }
            }
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
            .sheet(isPresented: $showCreate, onDismiss: { if vm.createdContract != nil { showCreated = true } }) { createSheet }
            .sheet(isPresented: $showCreated) {
                ContractCreatedSheet(contract: vm.createdContract!, currentBlockHeight: 0, onDismiss: { showCreated = false; vm.createdContract = nil })
            }
            .sheet(isPresented: $showImportPSBT) { importPSBTSheet }
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
            .task { await vm.refresh() }
    }

    private func poolRow(_ contract: Contract) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(.blue)
                Text(contract.name)
                    .font(.headline)
            }

            HStack {
                Text("\(contract.amount) sats")
                    .font(.subheadline.monospacedDigit())
                Spacer()
                if let m = contract.multisigM, let n = contract.multisigPubkeys?.count {
                    Text("\(m)-of-\(n)")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.1), in: Capsule())
                }
            }

            // Signature requirement reminder
            if let m = contract.multisigM {
                Text("Requires \(m) signatures to spend")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

            if let keys = contract.multisigPubkeys {
                ForEach(Array(keys.enumerated()), id: \.offset) { i, key in
                    Text("Signer \(i+1): \(key.prefix(16))...")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
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
        .padding(.vertical, 4)
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

    private var createSheet: some View {
        NavigationStack {
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

                Section("Amount (sats)") {
                    TextField("Amount", text: $vm.amount)
                        .keyboardType(.numberPad)
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
                    .disabled(!poolMValid || poolDuplicateKeys || vm.name.isEmpty || vm.amount.isEmpty)
                }
            }
            .navigationTitle("New Pool")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCreate = false }
                }
            }
        }
    }

    // MARK: - Import PSBT Sheet

    private var importPSBTSheet: some View {
        NavigationStack {
            Form {
                Section("PSBT Base64") {
                    TextEditor(text: $vm.importedPSBTBase64)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120)
                }

                Button("Import") {
                    vm.importPSBT()
                }

                if vm.parsedPSBT != nil {
                    Section("Imported PSBT") {
                        Text("Valid PSBT")
                            .foregroundStyle(.green)
                    }
                }

                if let error = vm.error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Import PSBT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showImportPSBT = false }
                }
            }
        }
    }
}
