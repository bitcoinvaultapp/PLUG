import SwiftUI

struct CoinJoinView: View {
    @StateObject private var vm = CoinJoinVM()
    @EnvironmentObject var walletVM: WalletVM

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Progress
                progressStepper

                // Step content
                switch vm.step {
                case .setup:
                    setupView
                case .built:
                    builtView
                case .signed:
                    signedView
                case .broadcast:
                    broadcastView
                }

                // Error
                if let error = vm.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(vm.step == .signed ? .orange : .red)
                        .padding(.horizontal)
                }

                if vm.step != .setup {
                    Button("Start Over") { vm.reset() }
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle("CoinJoin")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Progress

    private var progressStepper: some View {
        let steps = ["Setup", "PSBT", "Sign", "Broadcast"]
        let currentIndex: Int = {
            switch vm.step {
            case .setup: return 0
            case .built: return 1
            case .signed: return 2
            case .broadcast: return 3
            }
        }()

        return HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, label in
                VStack(spacing: 4) {
                    Circle()
                        .fill(index <= currentIndex ? Color.purple : Color(.systemGray4))
                        .frame(width: 8, height: 8)
                    Text(label)
                        .font(.system(size: 8, weight: index == currentIndex ? .bold : .regular))
                        .foregroundStyle(index <= currentIndex ? .primary : .tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Setup

    private var setupView: some View {
        VStack(spacing: 16) {
            // Hero explanation
            VStack(spacing: 8) {
                Image(systemName: "person.3.sequence.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.purple)
                Text("Pool your transaction with others to break chain analysis links.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 8)

            // Role cards
            HStack(spacing: 12) {
                roleCard(
                    icon: "plus.circle.fill",
                    title: "Create",
                    desc: "Start a new pool",
                    isSelected: vm.role == .initiator
                ) { vm.role = .initiator }

                roleCard(
                    icon: "arrow.down.circle.fill",
                    title: "Join",
                    desc: "Import a PSBT",
                    isSelected: vm.role == .joiner
                ) { vm.role = .joiner }
            }

            // Joiner: import PSBT
            if vm.role == .joiner {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Import PSBT")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $vm.importedPSBT)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 70)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                    if let info = importedInfo {
                        HStack(spacing: 16) {
                            miniStat("Denomination", value: BalanceUnit.format(info.denomination))
                            miniStat("Participants", value: "\(info.participantCount)")
                            miniStat("Inputs", value: "\(info.totalInputs)")
                        }
                    }
                }
            }

            // Denomination picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Denomination")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(CoinJoinBuilder.denominations, id: \.self) { d in
                        denomChip(d)
                    }
                }
            }

            // Fee rate
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Fee Rate")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(vm.feeRate)) sat/vB")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                Slider(value: $vm.feeRate, in: 1...50, step: 1)
                    .tint(.purple)
                Text("~\(vm.feePerInput) sats per participant")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            // UTXO selection
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Select UTXOs")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    let total = walletVM.utxos.filter { vm.selectedOutpoints.contains($0.outpoint) }.reduce(UInt64(0)) { $0 + $1.value }
                    if total > 0 {
                        Text(BalanceUnit.format(total))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.purple)
                    }
                }

                ForEach(walletVM.utxos) { utxo in
                    utxoRow(utxo)
                }
            }

            // Action button
            Button {
                if vm.role == .initiator {
                    vm.createCoinJoin(walletVM: walletVM)
                } else {
                    vm.joinCoinJoin(walletVM: walletVM)
                }
            } label: {
                Text(vm.role == .initiator ? "Create CoinJoin" : "Join CoinJoin")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        vm.selectedOutpoints.isEmpty ? Color(.systemGray3) : Color.purple,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(vm.selectedOutpoints.isEmpty || (vm.role == .joiner && vm.importedPSBT.isEmpty))
        }
    }

    private func roleCard(icon: String, title: String, desc: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isSelected ? .purple : .secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(desc)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Color.purple.opacity(0.4) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func denomChip(_ sats: UInt64) -> some View {
        Button {
            vm.denomination = sats
        } label: {
            Text(formatSats(sats))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(vm.denomination == sats ? .white : .secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    vm.denomination == sats ? Color.purple : Color(.systemGray5),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func utxoRow(_ utxo: UTXO) -> some View {
        let selected = vm.selectedOutpoints.contains(utxo.outpoint)
        return Button {
            if selected {
                vm.selectedOutpoints.remove(utxo.outpoint)
            } else {
                vm.selectedOutpoints.insert(utxo.outpoint)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? .purple : Color(.systemGray3))
                    .font(.system(size: 18))

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(utxo.address.prefix(14)) + "...")
                        .font(.system(size: 11, design: .monospaced))
                    Text(String(utxo.txid.prefix(8)) + ":\(utxo.vout)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Text(BalanceUnit.format(utxo.value))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(selected ? .purple : .secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(selected ? Color.purple.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func miniStat(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Built

    private var builtView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.purple)
                Text("PSBT Ready")
                    .font(.system(size: 16, weight: .semibold))
                Text("Share with other participants, then sign with your Ledger.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let psbt = vm.exportedPSBT {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(psbt.prefix(60)) + "...")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Button {
                        secureCopy(psbt)
                    } label: {
                        HStack {
                            Image(systemName: "doc.on.doc")
                            Text("Copy PSBT")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.purple)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }

            Button {
                Task { await vm.signMyInputs(walletVM: walletVM) }
            } label: {
                HStack {
                    if vm.isSigning { ProgressView().tint(.white).padding(.trailing, 4) }
                    Text(vm.isSigning ? "Signing..." : "Sign with Ledger")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.purple, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(vm.isSigning)
        }
    }

    // MARK: - Signed

    private var signedView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: "signature")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                Text("Signed")
                    .font(.system(size: 16, weight: .semibold))
                Text("Share the signed PSBT. Once all participants have signed, any participant can broadcast.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let psbt = vm.exportedPSBT {
                Button {
                    UIPasteboard.general.string = psbt
                } label: {
                    HStack {
                        Image(systemName: "doc.on.doc")
                        Text("Copy Signed PSBT")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Broadcast

    private var broadcastView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text("CoinJoin Sent")
                    .font(.system(size: 18, weight: .bold))
                Text("Your transaction is now mixed with other participants.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let txid = vm.broadcastTxid {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transaction ID")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(txid)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)

                    Button {
                        UIPasteboard.general.string = txid
                    } label: {
                        HStack {
                            Image(systemName: "doc.on.doc")
                            Text("Copy")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(.vertical, 20)
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
