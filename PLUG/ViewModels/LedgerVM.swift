import Foundation
import Combine

extension Notification.Name {
    static let ledgerXpubChanged = Notification.Name("ledgerXpubChanged")
}

@MainActor
final class LedgerVM: ObservableObject {

    @Published var state: LedgerState = .disconnected
    @Published var discoveredDevices: [String] = [] // device names
    @Published var isLoading = false
    @Published var error: String?
    @Published var xpubResult: String?
    @Published var isDemoMode = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        LedgerManager.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.state = state
            }
            .store(in: &cancellables)

        LedgerManager.shared.$discoveredDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                self?.discoveredDevices = devices.map { $0.name ?? "Ledger" }
            }
            .store(in: &cancellables)

        LedgerManager.shared.$isDemoMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] demo in
                self?.isDemoMode = demo
            }
            .store(in: &cancellables)
    }

    func startScan() {
        LedgerManager.shared.startScan()
    }

    func connect(at index: Int) {
        let devices = LedgerManager.shared.discoveredDevices
        guard index < devices.count else { return }
        LedgerManager.shared.connect(to: devices[index])
    }

    func disconnect() {
        LedgerManager.shared.disconnect()
    }

    /// Fetch xpub from connected Ledger and save to Keychain.
    /// If the xpub changed (different Ledger or different app), clears all cached
    /// wallet data to prevent showing stale UTXOs from another device.
    func fetchAndSaveXpub() async {
        isLoading = true
        error = nil

        do {
            let isTestnet = NetworkConfig.shared.isTestnet
            let path = LedgerProtocol.defaultPath(isTestnet: isTestnet)
            let result = try await LedgerManager.shared.getXpub(path: path, display: true)

            // Check if xpub changed — if so, wipe cached wallet data
            let previousXpub = KeychainStore.shared.loadXpub(isTestnet: isTestnet)
            if previousXpub != nil && previousXpub != result.xpub {
                print("[LedgerVM] xpub changed — clearing stale wallet cache")
                // Post notification so WalletVM can invalidate its cache
                NotificationCenter.default.post(name: .ledgerXpubChanged, object: nil)
            }

            KeychainStore.shared.saveXpub(result.xpub, isTestnet: isTestnet)
            xpubResult = result.xpub

            // Always notify wallet to reload with fresh data
            NotificationCenter.default.post(name: .ledgerXpubChanged, object: nil)

        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    /// Activate demo mode
    func activateDemoMode() {
        DemoMode.shared.activate()
        LedgerManager.shared.isDemoMode = true
        state = .connected
    }

    /// Deactivate demo mode
    func deactivateDemoMode() {
        DemoMode.shared.deactivate()
        LedgerManager.shared.isDemoMode = false
        state = .disconnected
    }
}
