import SwiftUI

/// Reusable key/address index picker for contract creation.
/// Shows the BIP32 derivation path and the derived address.
struct KeyIndexPicker: View {
    @Binding var index: UInt32
    let maxIndex: UInt32

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

    var body: some View {
        Section {
            Stepper(value: $index, in: 0...maxIndex) {
                HStack {
                    Text("Key Index")
                    Spacer()
                    Text("#\(index)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.btcOrange)
                }
            }

            LabeledContent("Path") {
                Text(derivationPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let addr = derivedAddress {
                LabeledContent("Address") {
                    Text(String(addr.prefix(10)) + "..." + String(addr.suffix(6)))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Signing Key")
        } footer: {
            Text("Select which address index from your Ledger to use for this contract. Each index derives a different key pair.")
        }
    }
}
