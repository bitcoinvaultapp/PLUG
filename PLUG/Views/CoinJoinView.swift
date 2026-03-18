import SwiftUI

struct CoinJoinView: View {
    @StateObject private var vm = CoinJoinVM()
    @EnvironmentObject var walletVM: WalletVM

    var body: some View {
        NavigationStack {
            Form {
                if vm.step == .setup {
                    setupSection
                } else if vm.step == .built {
                    builtSection
                } else if vm.step == .signed {
                    signedSection
                } else if vm.step == .broadcast {
                    broadcastSection
                }

                if let error = vm.error {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(vm.step == .signed ? .orange : .red)
                    }
                }

                if vm.step != .setup {
                    Section {
                        Button("Start Over") { vm.reset() }
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("CoinJoin")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Setup

    private var setupSection: some View {
        Group {
            Section {
                Picker("Role", selection: $vm.role) {
                    ForEach(CoinJoinVM.Role.allCases, id: \.self) { role in
                        Text(role.rawValue).tag(role)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(vm.role == .initiator
                     ? "Create a new CoinJoin and share the PSBT with participants."
                     : "Join an existing CoinJoin by importing a PSBT.")
            }

            if vm.role == .joiner {
                Section("Import PSBT") {
                    TextEditor(text: $vm.importedPSBT)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 80)

                    if let info = importedInfo {
                        LabeledContent("Denomination", value: "\(info.denomination) sats")
                        LabeledContent("Participants", value: "\(info.participantCount)")
                        LabeledContent("Inputs", value: "\(info.totalInputs)")
                    }
                }
            }

            Section("Denomination") {
                Picker("Amount", selection: $vm.denomination) {
                    ForEach(CoinJoinBuilder.denominations, id: \.self) { d in
                        Text(formatSats(d)).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(vm.role == .joiner && importedInfo != nil)
            }

            Section("Fee Rate") {
                HStack {
                    Slider(value: $vm.feeRate, in: 1...50, step: 1)
                    Text("\(Int(vm.feeRate)) sat/vB")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 70, alignment: .trailing)
                }
                LabeledContent("Fee per participant") {
                    Text("~\(vm.feePerInput) sats")
                        .font(.system(.caption, design: .monospaced))
                }
            }

            Section("Select UTXOs") {
                ForEach(walletVM.utxos) { utxo in
                    Button {
                        if vm.selectedOutpoints.contains(utxo.outpoint) {
                            vm.selectedOutpoints.remove(utxo.outpoint)
                        } else {
                            vm.selectedOutpoints.insert(utxo.outpoint)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: vm.selectedOutpoints.contains(utxo.outpoint) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(vm.selectedOutpoints.contains(utxo.outpoint) ? Color.btcOrange : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(utxo.address.prefix(16)) + "...")
                                    .font(.system(size: 11, design: .monospaced))
                                Text(String(utxo.txid.prefix(8)) + ":\(utxo.vout)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text("\(utxo.value) sats")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        }
                    }
                    .buttonStyle(.plain)
                }

                let total = walletVM.utxos.filter { vm.selectedOutpoints.contains($0.outpoint) }.reduce(UInt64(0)) { $0 + $1.value }
                if total > 0 {
                    HStack {
                        Text("Selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(total) sats")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.btcOrange)
                    }
                }
            }

            Section {
                Button {
                    if vm.role == .initiator {
                        vm.createCoinJoin(walletVM: walletVM)
                    } else {
                        vm.joinCoinJoin(walletVM: walletVM)
                    }
                } label: {
                    Text(vm.role == .initiator ? "Create CoinJoin" : "Join CoinJoin")
                        .frame(maxWidth: .infinity)
                }
                .disabled(vm.selectedOutpoints.isEmpty || (vm.role == .joiner && vm.importedPSBT.isEmpty))
            }
        }
    }

    // MARK: - Built (PSBT ready)

    private var builtSection: some View {
        Group {
            Section("CoinJoin PSBT") {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("PSBT ready")
                        .font(.subheadline.weight(.medium))
                }

                if let psbt = vm.exportedPSBT {
                    Text(String(psbt.prefix(60)) + "...")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    Button("Copy PSBT") {
                        UIPasteboard.general.string = psbt
                    }
                    .font(.caption)
                }
            }

            Section {
                Text("Share this PSBT with other participants. Once everyone has added their inputs, each participant signs with their Ledger.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    Task { await vm.signMyInputs(walletVM: walletVM) }
                } label: {
                    HStack {
                        if vm.isSigning { ProgressView().padding(.trailing, 4) }
                        Text(vm.isSigning ? "Signing..." : "Sign with Ledger")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(vm.isSigning)
            }
        }
    }

    // MARK: - Signed

    private var signedSection: some View {
        Group {
            Section("Signed") {
                HStack {
                    Image(systemName: "signature")
                        .foregroundStyle(.orange)
                    Text("Your inputs are signed")
                        .font(.subheadline.weight(.medium))
                }

                if let psbt = vm.exportedPSBT {
                    Button("Copy Signed PSBT") {
                        UIPasteboard.general.string = psbt
                    }
                    .font(.caption)
                }
            }

            Section {
                Text("Share the signed PSBT with other participants. Once all inputs are signed, any participant can broadcast.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Broadcast

    private var broadcastSection: some View {
        Section("CoinJoin Broadcast") {
            HStack {
                Image(systemName: "party.popper.fill")
                Text("CoinJoin sent!")
                    .fontWeight(.bold)
                    .foregroundStyle(.green)
            }

            if let txid = vm.broadcastTxid {
                Text(txid)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)

                Button("Copy txid") {
                    UIPasteboard.general.string = txid
                }
                .font(.caption)
            }
        }
    }

    // MARK: - Helpers

    private var importedInfo: CoinJoinBuilder.CoinJoinInfo? {
        guard let data = Data(base64Encoded: vm.importedPSBT.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return CoinJoinBuilder.analyzePSBT(data, isTestnet: vm.isTestnet)
    }

    private func formatSats(_ sats: UInt64) -> String {
        if sats >= 1_000_000 { return "\(sats / 1_000_000)M" }
        if sats >= 1_000 { return "\(sats / 1_000)k" }
        return "\(sats)"
    }
}
