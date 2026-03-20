import Foundation
import Combine

/// Manages the embedded Arti Tor client.
/// Starts a local SOCKS5 proxy that URLSession can route through.
///
/// Usage:
///   TorManager.shared.start()
///   // Wait for state == .connected
///   // Use TorConfig.shared.socksPort for URLSession proxy
///   TorManager.shared.stop()
@MainActor
final class TorManager: ObservableObject {

    static let shared = TorManager()

    enum TorState: Equatable {
        case disconnected
        case connecting
        case connected(port: UInt16)
        case error(String)
    }

    @Published var state: TorState = .disconnected

    /// Start Tor in background thread. Updates state on completion.
    /// Bootstrap takes 10-30 seconds.
    func start() {
        guard state == .disconnected || {
            if case .error = state { return true }
            return false
        }() else { return }

        state = .connecting

        Task.detached(priority: .userInitiated) {
            // plug_tor_start() blocks until Tor bootstrap completes
            let port = plug_tor_start()

            await MainActor.run {
                if port > 0 {
                    TorConfig.shared.socksPort = Int(port)
                    TorConfig.shared.isEnabled = true
                    self.state = .connected(port: port)
                } else {
                    self.state = .error("Tor bootstrap failed")
                }
            }
        }
    }

    /// Stop the Tor proxy.
    func stop() {
        plug_tor_stop()
        TorConfig.shared.isEnabled = false
        state = .disconnected
    }

    /// Check if Tor is actively running.
    var isRunning: Bool {
        plug_tor_is_running()
    }

    /// Get the current SOCKS5 port (0 if not running).
    var socksPort: UInt16 {
        plug_tor_port()
    }
}
