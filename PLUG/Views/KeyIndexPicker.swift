import SwiftUI

/// Reusable key/address index picker for contract creation.
/// Shows the BIP32 derivation path, derived address, and address status color.
/// Fetches address status independently — no dependency on WalletVM.
struct KeyIndexPicker: View {
    @Binding var index: UInt32
    let maxIndex: UInt32

    @State private var status: WalletAddress.Status = .fresh
    @State private var isChecking = false

    private var coinType: String {
        NetworkConfig.shared.isTestnet ? "1" : "0"
    }

    private var derivationPath: String {
        "m/84'/\(coinType)'/0'/0/\(index)"
    }

    private var derivedAddress: String? {
        guard let xpubStr = KeychainStore.shared.loadXpub(isTestnet: NetworkConfig.shared.isTestnet),
              let xpub = ExtendedPublicKey.fromBase58(xpubStr) else { return nil }
        let addrs = AddressDerivation.deriveAddresses(
            xpub: xpub, change: 0, startIndex: index, count: 1, isTestnet: NetworkConfig.shared.isTestnet
        )
        return addrs.first?.address
    }

    private var statusColor: Color {
        switch status {
        case .fresh: return .green
        case .funded: return .orange
        case .used: return .red
        }
    }

    private var statusLabel: String {
        switch status {
        case .fresh: return "Fresh"
        case .funded: return "Funded"
        case .used: return "Used"
        }
    }

    var body: some View {
        Section {
            Stepper(value: $index, in: 0...maxIndex) {
                HStack {
                    Text("Key Index")
                    Spacer()
                    if isChecking {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text("#\(index)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(statusColor)
                }
            }

            LabeledContent("Path") {
                Text(derivationPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let addr = derivedAddress {
                LabeledContent("Address") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        Text(String(addr.prefix(10)) + "..." + String(addr.suffix(6)))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Status")
                    Spacer()
                    Text(statusLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(statusColor)
                }
            }
        } header: {
            Text("Signing Key")
        } footer: {
            Text("Green = fresh (safe). Orange = has funds. Red = already used (exposed key).")
        }
        .onChange(of: index) { _ in
            checkStatus()
        }
        .onAppear {
            checkStatus()
        }
    }

    private func checkStatus() {
        guard let addr = derivedAddress else {
            status = .fresh
            return
        }
        isChecking = true
        Task {
            do {
                let utxos = try await MempoolAPI.shared.getAddressUTXOs(address: addr)
                let txs = try await MempoolAPI.shared.getAddressTransactions(address: addr)

                if txs.isEmpty {
                    status = .fresh
                } else {
                    // Check if address was ever used as input (pubkey exposed)
                    let spentFrom = txs.contains { tx in
                        tx.vin.contains { input in
                            input.prevout?.scriptpubkeyAddress == addr
                        }
                    }
                    if spentFrom {
                        status = .used // Pubkey exposed — don't reuse
                    } else if !utxos.isEmpty {
                        status = .funded
                    } else {
                        status = .used // Had txs, no UTXOs = spent
                    }
                }
            } catch {
                status = .fresh
            }
            isChecking = false
        }
    }
}
