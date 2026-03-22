import Foundation

/// Manages the embedded Arti Tor client.
/// Bootstrap → warmup HS circuit → ready for address queries.
@MainActor
final class TorManager: ObservableObject {

    static let shared = TorManager()

    enum TorState: Equatable {
        case disconnected
        case connecting
        case warmingUp
        case connected
        case error(String)
    }

    @Published var state: TorState = .disconnected

    var isRunning: Bool { plug_tor_is_running() }

    func start() {
        guard state == .disconnected || {
            if case .error = state { return true }
            return false
        }() else { return }

        state = .connecting

        Task.detached(priority: .userInitiated) {
            // Phase 1: Bootstrap Tor (~12s)
            let port = plug_tor_start()
            guard port > 0 else {
                await MainActor.run { self.state = .error("Tor bootstrap failed") }
                return
            }

            await MainActor.run {
                TorConfig.shared.isEnabled = true
                self.state = .warmingUp
            }

            // Phase 2: Warm up HS circuit (~15-30s)
            let (host, _) = TorConfig.shared.resolve(endpoint: "/blocks/tip/height")
            host.withCString { plug_tor_warmup($0, 80) }

            await MainActor.run {
                self.state = .connected
            }
        }
    }

    func stop() {
        plug_tor_stop()
        TorConfig.shared.isEnabled = false
        state = .disconnected
    }
}
