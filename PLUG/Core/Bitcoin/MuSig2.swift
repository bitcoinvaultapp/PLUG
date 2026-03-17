import Foundation

// MARK: - MuSig2 (BIP327) Schnorr Key Aggregation
// Aggregates multiple public keys into a single Schnorr key for P2TR
// Signing is deferred to the Ledger device

struct MuSig2 {

    // MARK: - Tagged hashes for MuSig2

    /// Tagged hash: SHA256(SHA256(tag) || SHA256(tag) || data)
    private static func taggedHash(tag: String, data: Data) -> Data {
        let tagHash = Crypto.sha256(Data(tag.utf8))
        var input = Data()
        input.append(tagHash)
        input.append(tagHash)
        input.append(data)
        return Crypto.sha256(input)
    }

    // MARK: - Key sorting (BIP327 lexicographic)

    /// Sort public keys lexicographically (BIP327 KeySort)
    static func sortKeys(_ pubkeys: [Data]) -> [Data] {
        pubkeys.sorted { (a: Data, b: Data) -> Bool in
            a.lexicographicallyPrecedes(b)
        }
    }

    // MARK: - Key aggregation coefficient

    /// Compute the aggregation coefficient for pubkey at index
    /// L = SHA256(pk1 || pk2 || ... || pkn)
    /// a_i = tagged_hash("KeyAgg coefficient", L || pk_i)
    static func keyAggCoefficient(pubkeys: [Data], index: Int) -> UInt256? {
        // Compute L = hash of all pubkeys concatenated
        var lInput = Data()
        for pk in pubkeys {
            lInput.append(pk)
        }
        let l = Crypto.sha256(lInput)

        // Second public key optimization: if pk == pk_2, coefficient is 1
        // (BIP327 second key optimization)
        if pubkeys.count >= 2 && index != 0 {
            let secondKey = pubkeys[1]
            if pubkeys[index] == secondKey {
                return UInt256.one
            }
        }

        // a_i = tagged_hash("KeyAgg coefficient", L || pk_i)
        var coeffInput = Data()
        coeffInput.append(l)
        coeffInput.append(pubkeys[index])
        let coeffHash = taggedHash(tag: "KeyAgg coefficient", data: coeffInput)

        guard let coeff = UInt256(data: coeffHash) else { return nil }

        // Reduce mod n
        // Simple reduction: if coeff >= n, subtract n
        if coeff >= Secp256k1.n {
            return UInt256.sub(coeff, Secp256k1.n)
        }
        return coeff
    }

    // MARK: - Aggregate public keys

    /// Aggregate multiple compressed public keys into a single key (BIP327 KeyAgg)
    /// Returns the aggregated compressed public key (33 bytes)
    static func aggregateKeys(_ pubkeys: [Data]) -> Data? {
        guard pubkeys.count >= 2 else { return pubkeys.first }

        let sorted = sortKeys(pubkeys)

        // Q = sum(a_i * P_i) for all i
        var aggregate = Secp256k1.Point.infinity

        for (i, pk) in sorted.enumerated() {
            guard let point = Secp256k1.parsePublicKey(pk) else { return nil }
            guard let coeff = keyAggCoefficient(pubkeys: sorted, index: i) else { return nil }

            // a_i * P_i
            let weighted = Secp256k1.scalarMultiply(coeff, point)

            // Sum
            aggregate = Secp256k1.pointAdd(aggregate, weighted)
        }

        guard !aggregate.isInfinity else { return nil }

        return Secp256k1.serializePublicKey(aggregate)
    }

    // MARK: - X-only public key (BIP340)

    /// Convert a compressed public key to x-only (32 bytes, drop prefix)
    /// If y is odd, negate the key
    static func toXOnly(_ compressedKey: Data) -> Data? {
        guard compressedKey.count == 33 else { return nil }
        // x-only is just the x-coordinate (bytes 1-32)
        return Data(compressedKey[1...])
    }

    /// Check if a compressed key has even y (needed for BIP340)
    static func hasEvenY(_ compressedKey: Data) -> Bool {
        guard compressedKey.count == 33 else { return false }
        return compressedKey[0] == 0x02
    }

    // MARK: - Create P2TR address from aggregated key

    /// Aggregate keys and create a P2TR (Taproot) address
    /// The aggregated key becomes the internal key, optionally with script tree
    static func musigTaprootAddress(
        pubkeys: [Data],
        scripts: [Data]? = nil,
        isTestnet: Bool
    ) -> (address: String, aggregatedKey: Data)? {
        guard let aggKey = aggregateKeys(pubkeys) else { return nil }

        // For P2TR, we need the x-only key
        guard let xOnly = toXOnly(aggKey) else { return nil }

        // Build Taproot address with optional script tree
        let merkleRoot: Data?
        if let scripts = scripts, !scripts.isEmpty {
            merkleRoot = TaprootBuilder.computeMerkleRoot(scripts: scripts)
        } else {
            merkleRoot = nil
        }

        guard let address = TaprootBuilder.taprootAddress(
            internalKey: aggKey,
            scripts: scripts ?? [],
            isTestnet: isTestnet
        ) else { return nil }

        return (address, aggKey)
    }

    // MARK: - MuSig2 session context (for future signing)

    /// Session context for MuSig2 signing
    /// In our architecture, actual signing happens on the Ledger device
    /// This struct tracks the key aggregation state
    struct SessionContext {
        let pubkeys: [Data]         // all participant keys (sorted)
        let aggregatedKey: Data     // combined key
        let coefficients: [UInt256] // aggregation coefficients
        let message: Data?          // message to sign (set later)
    }

    /// Create a signing session context
    static func createSession(pubkeys: [Data]) -> SessionContext? {
        let sorted = sortKeys(pubkeys)

        guard let aggKey = aggregateKeys(sorted) else { return nil }

        var coeffs: [UInt256] = []
        for i in 0..<sorted.count {
            guard let c = keyAggCoefficient(pubkeys: sorted, index: i) else { return nil }
            coeffs.append(c)
        }

        return SessionContext(
            pubkeys: sorted,
            aggregatedKey: aggKey,
            coefficients: coeffs,
            message: nil
        )
    }

    // MARK: - Descriptor

    /// Generate a musig() descriptor string
    static func descriptor(pubkeys: [Data]) -> String {
        let sorted = sortKeys(pubkeys)
        let keyStrings = sorted.map { $0.hex }
        return "tr(musig(\(keyStrings.joined(separator: ","))))"
    }
}
