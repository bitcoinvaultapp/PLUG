import Foundation

// MARK: - Tor Routing Configuration
// Persisted in UserDefaults

final class TorConfig: ObservableObject {

    static let shared = TorConfig()

    private static let defaultOnionAddress = "mempoolhqx4isw62xs7abwphsq7ldayuidyx2v2oethdhhj6mlo2r6ad.onion"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "tor_enabled") }
    }

    @Published var onionAddress: String {
        didSet { UserDefaults.standard.set(onionAddress, forKey: "tor_onion_address") }
    }

    /// Personal Bitcoin node — routes all queries to user's own Electrs .onion
    @Published var usePersonalNode: Bool {
        didSet { UserDefaults.standard.set(usePersonalNode, forKey: "personal_node_enabled") }
    }

    @Published var personalNodeOnion: String {
        didSet { UserDefaults.standard.set(personalNodeOnion, forKey: "personal_node_onion") }
    }

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "tor_enabled")
        self.onionAddress = UserDefaults.standard.string(forKey: "tor_onion_address")
            ?? TorConfig.defaultOnionAddress
        self.usePersonalNode = UserDefaults.standard.bool(forKey: "personal_node_enabled")
        self.personalNodeOnion = UserDefaults.standard.string(forKey: "personal_node_onion") ?? ""
    }

    // MARK: - Routing

    /// Resolve the .onion host and API path prefix for the current configuration.
    /// Personal node: direct Electrs REST. Otherwise: mempool.space .onion.
    func resolve(endpoint: String) -> (host: String, path: String) {
        if usePersonalNode, !personalNodeOnion.isEmpty {
            return (personalNodeOnion, "/api\(endpoint)")
        }
        return (onionAddress, "/api\(endpoint)")
    }

    func resetToDefaults() {
        onionAddress = TorConfig.defaultOnionAddress
        isEnabled = false
        usePersonalNode = false
        personalNodeOnion = ""
    }
}
