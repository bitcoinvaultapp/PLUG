import Foundation

@MainActor
final class SettingsVM: ObservableObject {

    @Published var isTestnet: Bool
    @Published var hasXpub: Bool = false
    @Published var xpubDisplay: String = ""
    @Published var isDemoMode: Bool = false
    @Published var showClearConfirmation = false

    init() {
        isTestnet = NetworkConfig.shared.isTestnet
        refresh()
    }

    func refresh() {
        isTestnet = NetworkConfig.shared.isTestnet
        isDemoMode = DemoMode.shared.isActive

        if let xpub = KeychainStore.shared.loadXpub(isTestnet: isTestnet) {
            hasXpub = true
            // Show only first/last 8 chars
            if xpub.count > 20 {
                xpubDisplay = "\(xpub.prefix(8))...\(xpub.suffix(8))"
            } else {
                xpubDisplay = xpub
            }
        } else {
            hasXpub = false
            xpubDisplay = ""
        }
    }

    func toggleNetwork() {
        isTestnet.toggle()
        NetworkConfig.shared.isTestnet = isTestnet
        refresh()
    }

    func exportDescriptor() -> String? {
        guard let xpub = KeychainStore.shared.loadXpub(isTestnet: isTestnet) else { return nil }
        let prefix = isTestnet ? "84h/1h/0h" : "84h/0h/0h"
        return "wpkh([\(prefix)]\(xpub)/0/*)"
    }

    func clearAllData() {
        KeychainStore.shared.clearAll()
        ContractStore.shared.clearAll()
        TxLabelStore.shared.clearAll()
        FrozenUTXOStore.shared.clearAll()
        DemoMode.shared.deactivate()
        LedgerManager.shared.isDemoMode = false
        refresh()
    }
}
