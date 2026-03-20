import Foundation
import Combine

/// Manages the embedded Arti Tor client.
/// Bootstrap → warmup HS circuit → ready for address queries.
@MainActor
final class TorManager: ObservableObject {

    static let shared = TorManager()

    enum TorState: Equatable {
        case disconnected
        case connecting
        case warmingUp       // Bootstrap done, warming up HS circuit
        case connected(port: UInt16)
        case error(String)
    }

    @Published var state: TorState = .disconnected

    /// Start Tor + warm up HS circuit. Updates state at each phase.
    func start() {
        guard state == .disconnected || {
            if case .error = state { return true }
            return false
        }() else { return }

        state = .connecting

        Task.detached(priority: .userInitiated) {
            // Phase 1: Bootstrap Tor (consensus download, ~12s)
            let port = plug_tor_start()
            guard port > 0 else {
                await MainActor.run { self.state = .error("Tor bootstrap failed") }
                return
            }

            await MainActor.run {
                TorConfig.shared.isEnabled = true
                self.state = .warmingUp
            }

            // Phase 2: Warm up HS circuit to .onion (~15-30s)
            let onionHost = TorConfig.shared.onionAddress
            let success = onionHost.withCString { hostPtr in
                plug_tor_warmup(hostPtr, 80)
            }

            await MainActor.run {
                if success {
                    self.state = .connected(port: port)
                } else {
                    // Warmup failed but Tor is running — let user try anyway
                    self.state = .connected(port: port)
                    #if DEBUG
                    print("[TorManager] Warmup failed but Tor is running — proceeding")
                    #endif
                }
            }
        }
    }

    /// Stop Tor.
    func stop() {
        plug_tor_stop()
        TorConfig.shared.isEnabled = false
        state = .disconnected
    }

    /// Check if Tor is actively running.
    var isRunning: Bool {
        plug_tor_is_running()
    }

    /// Get the current SOCKS5 port (legacy, returns 1 if running).
    var socksPort: UInt16 {
        plug_tor_port()
    }
}
