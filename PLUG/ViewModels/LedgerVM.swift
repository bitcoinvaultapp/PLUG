import Foundation
import Combine

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

    /// Fetch xpub from connected Ledger and save to Keychain
    func fetchAndSaveXpub() async {
        isLoading = true
        error = nil

        do {
            let isTestnet = NetworkConfig.shared.isTestnet
            let path = LedgerProtocol.defaultPath(isTestnet: isTestnet)
            let result = try await LedgerManager.shared.getXpub(path: path, display: true)

            KeychainStore.shared.saveXpub(result.xpub, isTestnet: isTestnet)
            xpubResult = result.xpub

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
