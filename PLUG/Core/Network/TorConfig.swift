import Foundation

// MARK: - Tor Routing Configuration
// SOCKS5 proxy configuration for .onion routing
// Persisted in UserDefaults

final class TorConfig: ObservableObject {

    static let shared = TorConfig()

    private let enabledKey = "tor_enabled"
    private let onionKey = "tor_onion_address"
    private let portKey = "tor_socks_port"

    private static let defaultOnionAddress = "mempoolhqx4isw62xs7abwphsq7ldayuidyx2v2oethdhhj6mlo2r6ad.onion"
    private static let defaultSocksPort = 9050

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: enabledKey)
        }
    }

    @Published var onionAddress: String {
        didSet {
            UserDefaults.standard.set(onionAddress, forKey: onionKey)
        }
    }

    @Published var socksPort: Int {
        didSet {
            UserDefaults.standard.set(socksPort, forKey: portKey)
        }
    }

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        self.onionAddress = UserDefaults.standard.string(forKey: onionKey) ?? TorConfig.defaultOnionAddress
        self.socksPort = UserDefaults.standard.integer(forKey: portKey) == 0
            ? TorConfig.defaultSocksPort
            : UserDefaults.standard.integer(forKey: portKey)
    }

    // MARK: - URL routing

    var mempoolBaseURL: String {
        if isEnabled {
            let isTestnet = NetworkConfig.shared.isTestnet
            let prefix = isTestnet ? "/testnet" : ""
            return "http://\(onionAddress)\(prefix)/api"
        }
        return NetworkConfig.shared.mempoolBaseURL
    }

    // MARK: - SOCKS5 proxy URLSession

    func createTorSession() -> URLSession? {
        guard isEnabled else { return nil }

        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [
            "SOCKSEnable": true,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": socksPort
        ]
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60

        return URLSession(configuration: config)
    }

    // MARK: - Reset

    func resetToDefaults() {
        onionAddress = TorConfig.defaultOnionAddress
        socksPort = TorConfig.defaultSocksPort
        isEnabled = false
    }
}
