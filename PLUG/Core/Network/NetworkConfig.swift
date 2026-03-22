import Foundation

// MARK: - Network Configuration
// Mainnet only.

final class NetworkConfig: ObservableObject {

    static let shared = NetworkConfig()

    let isTestnet = false

    var mempoolBaseURL: String { "https://mempool.space/api" }
    var mempoolWSURL: String { "wss://mempool.space/api/v1/ws" }
    var bech32HRP: String { "bc" }
    var coinType: UInt32 { 0 }
    var networkName: String { "Mainnet" }
}
