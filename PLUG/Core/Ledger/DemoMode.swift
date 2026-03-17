import Foundation

// MARK: - Demo Mode
// Simulator for testing without physical Ledger
// Uses test xpubs injected into Keychain
// Broadcast is BLOCKED in demo mode

final class DemoMode: ObservableObject {

    static let shared = DemoMode()

    init() {
        self.isActive = UserDefaults.standard.bool(forKey: "demo_mode_active")
    }

    @Published var isActive: Bool {
        didSet { UserDefaults.standard.set(isActive, forKey: "demo_mode_active") }
    }

    // Test xpub (BIP84 testnet)
    // This is a well-known test vector - no real funds
    static let testXpub = "tpubDCBWBScQPGv4YUYGv5Ee71cimsLL5aRoR6J8CQxjXvLKExTKxemUSeCosXxtzEQRaj9CYWkd4CCRejxndqbbuEJQvcApBrqRJ7veg7JHfPe"

    // Simulated compressed public key (from test vector)
    static let testPublicKey = Data(hex: "0330d54fd0dd420a6e5f8d3624f5f3482cae350f79d5f0753bf5beef9c2d91af3c")!

    // Simulated chain code
    static let testChainCode = Data(hex: "873dff81c02f525623fd1fe5167eac3a55a049de3d314bb42ee227ffed37d508")!

    func activate() {
        isActive = true

        // Inject test xpub into Keychain
        KeychainStore.shared.saveXpub(Self.testXpub, isTestnet: true)

        // Force testnet
        NetworkConfig.shared.isTestnet = true
    }

    func deactivate() {
        isActive = false
    }

    /// Handle APDU in demo mode (simulate Ledger responses)
    func handleAPDU(_ apdu: LedgerProtocol.APDU) async throws -> Data {
        // Simulate processing delay
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s

        switch apdu.ins {
        case LedgerProtocol.BitcoinCommand.getWalletPublicKey.rawValue:
            return simulateXpubResponse()
        default:
            // For signing, return a dummy signature
            return simulateSignResponse()
        }
    }

    private func simulateXpubResponse() -> Data {
        var response = Data()

        // Uncompressed public key (65 bytes)
        let uncompressed = Data(hex: "04" + Self.testPublicKey.hex.dropFirst(2) +
            "e8ade9ef7fee5e28792900ad2ac07ad17ef2aa808de0eb57f3b0651c70c81c26")!

        response.append(UInt8(uncompressed.count))
        response.append(uncompressed)

        // Address
        let address = "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"
        let addrData = address.data(using: .ascii)!
        response.append(UInt8(addrData.count))
        response.append(addrData)

        // Chain code
        response.append(Self.testChainCode)

        return response
    }

    private func simulateSignResponse() -> Data {
        // Return a dummy DER signature (won't validate but allows UI testing)
        let dummySig = Data(hex: "3045022100c4d5e5f4d3c2b1a0f0e0d0c0b0a09080706050403020100f0e0d0c0b0a09080022071f2e3d4c5b6a79880011223344556677889900aabbccddeeff00112233445566")!
        return dummySig
    }

    /// Check if broadcast should be blocked
    func shouldBlockBroadcast() -> Bool {
        return isActive
    }
}
