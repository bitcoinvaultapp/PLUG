import Foundation

// MARK: - Network Configuration
// Runtime switch between testnet and mainnet

final class NetworkConfig: ObservableObject {

    static let shared = NetworkConfig()

    @Published var isTestnet: Bool {
        didSet {
            UserDefaults.standard.set(isTestnet, forKey: "is_testnet")
        }
    }

    init() {
        self.isTestnet = UserDefaults.standard.bool(forKey: "is_testnet")
    }

    var mempoolBaseURL: String {
        isTestnet
            ? "https://mempool.space/testnet4/api"
            : "https://mempool.space/api"
    }

    var mempoolWSURL: String {
        isTestnet
            ? "wss://mempool.space/testnet4/api/v1/ws"
            : "wss://mempool.space/api/v1/ws"
    }

    var bech32HRP: String {
        isTestnet ? "tb" : "bc"
    }

    /// BIP84 derivation path components (from xpub level: change/index)
    /// Full path is m/84'/coin'/0'/change/index
    /// coin = 0 (mainnet) or 1 (testnet)
    var coinType: UInt32 {
        isTestnet ? 1 : 0
    }

    var networkName: String {
        isTestnet ? "Testnet" : "Mainnet"
    }
}
