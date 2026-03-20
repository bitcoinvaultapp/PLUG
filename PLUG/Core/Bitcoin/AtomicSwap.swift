import Foundation

// MARK: - Swap Offer (exchanged between parties via QR)

struct SwapOffer: Codable {
    let version: Int                    // 1
    let hashLock: String                // SHA256 hash hex (32 bytes)
    let initiatorHTLCAddress: String    // Initiator's funded HTLC P2WSH address
    let initiatorAmount: UInt64         // Sats initiator locked
    let initiatorTimeout: Int           // CLTV block height
    let initiatorXpub: String           // Initiator's xpub (needed to build responder HTLC)
    let requestedAmount: UInt64         // Sats initiator wants from responder
    let suggestedTimeout: Int           // Suggested responder timeout (initiatorTimeout / 2 distance)
    let network: String                 // "testnet" or "mainnet"
    let keyIndex: UInt32                // BIP32 key index initiator used
}

// MARK: - Atomic Swap Utilities

enum AtomicSwapUtil {

    /// Encode a SwapOffer to a base64 string (for QR code)
    static func encodeOffer(_ offer: SwapOffer) -> String? {
        guard let data = try? JSONEncoder().encode(offer) else { return nil }
        return data.base64EncodedString()
    }

    /// Decode a SwapOffer from a base64 string (from QR scan)
    static func decodeOffer(_ string: String) -> SwapOffer? {
        // Try base64 first
        if let data = Data(base64Encoded: string),
           let offer = try? JSONDecoder().decode(SwapOffer.self, from: data) {
            return offer
        }
        // Try raw JSON
        if let data = string.data(using: .utf8),
           let offer = try? JSONDecoder().decode(SwapOffer.self, from: data) {
            return offer
        }
        return nil
    }

    /// Validate timeout safety: initiator timeout must be at least 2x the gap from current block to responder timeout
    /// This ensures the initiator has enough time to claim after the responder creates their HTLC
    static func validateTimeouts(initiatorTimeout: Int, responderTimeout: Int, currentBlockHeight: Int) -> Bool {
        guard responderTimeout > currentBlockHeight else { return false }
        guard initiatorTimeout > responderTimeout else { return false }
        let responderWindow = responderTimeout - currentBlockHeight
        let initiatorWindow = initiatorTimeout - currentBlockHeight
        return initiatorWindow >= 2 * responderWindow
    }

    /// Extract preimage from a spending transaction's witness data.
    /// HTLC claim witness stack: [preimage(32 bytes), signature, witnessScript]
    /// Returns the preimage if found and verified against the expected hash.
    static func extractPreimageFromWitness(witnesses: [String], expectedHashLock: String) -> Data? {
        // The claim witness has 3+ items; the preimage is the first 32-byte element
        for witnessHex in witnesses {
            guard let data = Data(hex: witnessHex), data.count == 32 else { continue }
            // Verify SHA256(data) matches the hash lock
            let hash = Crypto.sha256(data)
            if hash.hex == expectedHashLock {
                return data
            }
        }
        return nil
    }

    /// Check all inputs of a transaction for a preimage matching the expected hash lock
    static func extractPreimageFromTransaction(_ tx: Transaction, expectedHashLock: String) -> Data? {
        for input in tx.vin {
            guard let witnesses = input.witness else { continue }
            if let preimage = extractPreimageFromWitness(witnesses: witnesses, expectedHashLock: expectedHashLock) {
                return preimage
            }
        }
        return nil
    }
}
