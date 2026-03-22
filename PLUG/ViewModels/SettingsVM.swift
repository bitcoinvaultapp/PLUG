import Foundation

@MainActor
final class SettingsVM: ObservableObject {

    @Published var hasXpub: Bool = false
    @Published var xpubDisplay: String = ""
    @Published var showClearConfirmation = false

    init() { refresh() }

    func refresh() {
        if let xpub = KeychainStore.shared.loadXpub(isTestnet: false) {
            hasXpub = true
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

    func exportDescriptor() -> String? {
        guard let xpub = KeychainStore.shared.loadXpub(isTestnet: false) else { return nil }
        return "wpkh([84h/0h/0h]\(xpub)/0/*)"
    }

    func clearAllData() {
        KeychainStore.shared.clearAll()
        ContractStore.shared.clearAll()
        TxLabelStore.shared.clearAll()
        FrozenUTXOStore.shared.clearAll()
        refresh()
    }
}
