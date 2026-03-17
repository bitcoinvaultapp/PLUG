import Foundation

// MARK: - Taproot (P2TR) Support - BIP340/341/342
// Tagged hash functions, MAST construction, key tweaking, and P2TR address generation.
// Uses x-only (32-byte) public keys per BIP340.

struct TaprootBuilder {

    /// Default leaf version for Tapscript (BIP342)
    static let tapscriptLeafVersion: UInt8 = 0xC0

    // MARK: - Tagged hashes (BIP340/341)

    /// Compute a tagged hash: SHA256(SHA256(tag) || SHA256(tag) || data)
    ///
    /// Tagged hashes prevent cross-protocol attacks by domain-separating
    /// hash inputs with a tag prefix.
    ///
    /// - Parameters:
    ///   - tag: ASCII tag string (e.g. "TapLeaf", "TapBranch", "TapTweak")
    ///   - data: data to hash
    /// - Returns: 32-byte tagged hash
    static func taggedHash(tag: String, data: Data) -> Data {
        let tagHash = Crypto.sha256(Data(tag.utf8))
        var preimage = Data()
        preimage.append(tagHash)
        preimage.append(tagHash)
        preimage.append(data)
        return Crypto.sha256(preimage)
    }

    // MARK: - Tap leaf and branch hashes

    /// Compute the TapLeaf hash for a script
    ///
    /// TapLeaf = TaggedHash("TapLeaf", leaf_version || compact_size(script) || script)
    ///
    /// - Parameters:
    ///   - script: the leaf script bytes
    ///   - leafVersion: leaf version byte (default 0xC0 for Tapscript)
    /// - Returns: 32-byte TapLeaf hash
    static func tapLeafHash(script: Data, leafVersion: UInt8 = tapscriptLeafVersion) -> Data {
        var payload = Data()
        payload.append(leafVersion)
        payload.append(VarInt.encode(UInt64(script.count)))
        payload.append(script)
        return taggedHash(tag: "TapLeaf", data: payload)
    }

    /// Compute the TapBranch hash for two child nodes
    ///
    /// TapBranch = TaggedHash("TapBranch", sorted(left, right))
    /// Children are sorted lexicographically to ensure canonical ordering.
    ///
    /// - Parameters:
    ///   - left: 32-byte hash of the left child
    ///   - right: 32-byte hash of the right child
    /// - Returns: 32-byte TapBranch hash
    static func tapBranchHash(left: Data, right: Data) -> Data {
        // Sort lexicographically for canonical tree construction
        let (first, second) = left.hex <= right.hex ? (left, right) : (right, left)
        var payload = Data()
        payload.append(first)
        payload.append(second)
        return taggedHash(tag: "TapBranch", data: payload)
    }

    // MARK: - MAST root computation

    /// Compute the Merkle root from an array of script leaves
    ///
    /// Builds a balanced binary Merkle tree using TapLeaf and TapBranch hashes.
    ///
    /// - Parameter scripts: array of raw script bytes (each becomes a leaf)
    /// - Returns: 32-byte Merkle root, or nil if scripts is empty
    static func computeMerkleRoot(scripts: [Data]) -> Data? {
        guard !scripts.isEmpty else { return nil }

        // Hash each script into a TapLeaf
        var nodes = scripts.map { tapLeafHash(script: $0) }

        // Build tree bottom-up
        while nodes.count > 1 {
            var nextLevel: [Data] = []
            var i = 0
            while i < nodes.count {
                if i + 1 < nodes.count {
                    nextLevel.append(tapBranchHash(left: nodes[i], right: nodes[i + 1]))
                } else {
                    // Odd node propagates up
                    nextLevel.append(nodes[i])
                }
                i += 2
            }
            nodes = nextLevel
        }

        return nodes.first
    }

    // MARK: - Key tweaking

    /// Tweak an x-only internal public key with an optional Merkle root
    ///
    /// tweak = TaggedHash("TapTweak", internal_key || merkle_root)
    /// For key-path-only spending (no scripts): tweak = TaggedHash("TapTweak", internal_key)
    ///
    /// The tweaked key Q = P + tweak*G is computed using secp256k1 point addition.
    ///
    /// - Parameters:
    ///   - internalKey: 32-byte x-only internal public key
    ///   - merkleRoot: optional 32-byte MAST Merkle root
    /// - Returns: 32-byte x-only tweaked public key, or nil on error
    static func tweakPublicKey(internalKey: Data, merkleRoot: Data?) -> Data? {
        guard internalKey.count == 32 else { return nil }

        // Compute the tweak scalar
        var tweakInput = Data()
        tweakInput.append(internalKey)
        if let root = merkleRoot {
            tweakInput.append(root)
        }
        let tweak = taggedHash(tag: "TapTweak", data: tweakInput)

        // Q = P + t*G using secp256k1
        // Lift x-only key to full point (assume even Y)
        var fullKey = Data([0x02])
        fullKey.append(internalKey)

        guard let tweakScalar = UInt256(data: tweak) else { return nil }
        guard !tweakScalar.isZero else { return nil }

        // Use secp256k1 point operations
        guard let p = Secp256k1.parsePublicKey(fullKey) else { return nil }
        let tG = Secp256k1.scalarMultiply(tweakScalar, Secp256k1.G)
        let q = Secp256k1.pointAdd(p, tG)
        guard !q.isInfinity else { return nil }

        // Return x-only (32 bytes)
        return q.x.toData()
    }

    // MARK: - P2TR output script

    /// Build a P2TR (SegWit v1) output script
    ///
    /// Format: OP_1 <32-byte-tweaked-key>
    ///
    /// - Parameter tweakedKey: 32-byte x-only tweaked public key
    /// - Returns: P2TR scriptPubKey
    static func p2trScriptPubKey(tweakedKey: Data) -> Data {
        var script = Data()
        script.append(OpCode.op_1.rawValue) // SegWit version 1
        script.append(0x20) // push 32 bytes
        script.append(tweakedKey)
        return script
    }

    // MARK: - P2TR address generation

    /// Generate a P2TR bech32m address from an internal key and optional script tree
    ///
    /// - Parameters:
    ///   - internalKey: 32-byte x-only internal public key
    ///   - scripts: optional array of scripts to form the MAST (can be empty)
    ///   - isTestnet: network flag
    /// - Returns: bech32m-encoded P2TR address, or nil on error
    static func taprootAddress(
        internalKey: Data,
        scripts: [Data] = [],
        isTestnet: Bool
    ) -> String? {
        let merkleRoot: Data?
        if scripts.isEmpty {
            merkleRoot = nil
        } else {
            merkleRoot = computeMerkleRoot(scripts: scripts)
        }

        guard let tweakedKey = tweakPublicKey(internalKey: internalKey, merkleRoot: merkleRoot) else {
            return nil
        }

        let hrp = isTestnet ? "tb" : "bc"
        return Bech32.segwitEncode(hrp: hrp, version: 1, program: tweakedKey)
    }
}
