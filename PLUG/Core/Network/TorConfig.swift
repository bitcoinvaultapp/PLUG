import Foundation

// MARK: - Tor Routing Configuration
// All traffic goes through Tor. No clearnet.

final class TorConfig: ObservableObject {

    static let shared = TorConfig()

    private static let mempoolOnion = "mempoolhqx4isw62xs7abwphsq7ldayuidyx2v2oethdhhj6mlo2r6ad.onion"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "tor_enabled") }
    }

    /// Personal node .onion (Bitcoin Core + Electrs)
    @Published var personalNodeOnion: String {
        didSet { UserDefaults.standard.set(personalNodeOnion, forKey: "personal_node_onion") }
    }

    var isNodeConfigured: Bool {
        !personalNodeOnion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "tor_enabled")
        self.personalNodeOnion = UserDefaults.standard.string(forKey: "personal_node_onion") ?? ""
    }

    // MARK: - Routing

    /// Resolve endpoint to personal node (Electrs REST, no /api prefix)
    func resolve(endpoint: String) -> (host: String, path: String) {
        (personalNodeOnion, endpoint)
    }

    /// Resolve endpoint to mempool.space .onion (for price, difficulty only)
    func resolveMempoolSpace(endpoint: String) -> (host: String, path: String) {
        (Self.mempoolOnion, "/api\(endpoint)")
    }

    func resetToDefaults() {
        isEnabled = false
        personalNodeOnion = ""
    }
}
