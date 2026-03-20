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
    }
}
