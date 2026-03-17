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
    /// Result of tweaking an internal key — includes parity for control block.
    struct TweakResult {
        let xOnly: Data       // 32-byte x-only tweaked key
        let full: Data        // 33-byte compressed tweaked key
        let parityBit: UInt8  // 0 if even Y, 1 if odd Y
    }

    static func tweakPublicKey(internalKey: Data, merkleRoot: Data?) -> Data? {
        tweakPublicKeyFull(internalKey: internalKey, merkleRoot: merkleRoot)?.xOnly
    }

    /// Full tweak result with parity info (needed for control blocks).
    static func tweakPublicKeyFull(internalKey: Data, merkleRoot: Data?) -> TweakResult? {
        guard internalKey.count == 32 else { return nil }

        // Compute the tweak scalar: t = TaggedHash("TapTweak", P || merkleRoot?)
        var tweakInput = Data()
        tweakInput.append(internalKey)
        if let root = merkleRoot {
            tweakInput.append(root)
        }
        let tweak = taggedHash(tag: "TapTweak", data: tweakInput)

        // Lift x-only to compressed key with even Y (BIP340)
        let fullKey = Secp256k1.liftXOnly(internalKey)

        // Q = P + t*G using secp256k1_ec_pubkey_tweak_add (constant-time)
        guard let result = Secp256k1.tweakAdd(pubkey: fullKey, tweak: tweak) else { return nil }

        let xOnly = Secp256k1.xOnly(result.key)
        let parityBit: UInt8 = result.evenY ? 0 : 1

        return TweakResult(xOnly: xOnly, full: result.key, parityBit: parityBit)
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

    // MARK: - Control block construction (BIP341)

    /// Build a control block for script-path spending.
    ///
    /// Format: (leaf_version | parity_bit) || internal_key || merkle_proof
    ///
    /// - Parameters:
    ///   - internalKey: 32-byte x-only internal public key
    ///   - merkleRoot: optional merkle root (nil if single leaf)
    ///   - scriptIndex: index of the script being spent in the scripts array
    ///   - scripts: all scripts in the MAST tree
    /// - Returns: control block bytes, or nil on error
    static func controlBlock(
        internalKey: Data,
        scripts: [Data],
        scriptIndex: Int
    ) -> Data? {
        guard internalKey.count == 32, scriptIndex < scripts.count else { return nil }

        let merkleRoot = computeMerkleRoot(scripts: scripts)
        guard let tweakResult = tweakPublicKeyFull(internalKey: internalKey, merkleRoot: merkleRoot) else {
            return nil
        }

        // First byte: leaf_version | parity_bit
        let firstByte = tapscriptLeafVersion | tweakResult.parityBit

        var cb = Data()
        cb.append(firstByte)
        cb.append(internalKey)

        // Compute Merkle proof for the target leaf
        let proof = merkleProof(scripts: scripts, leafIndex: scriptIndex)
        for hash in proof {
            cb.append(hash)
        }

        return cb
    }

    /// Compute the Merkle proof (sibling hashes) for a specific leaf index.
    static func merkleProof(scripts: [Data], leafIndex: Int) -> [Data] {
        guard scripts.count > 1 else { return [] }

        var nodes = scripts.map { tapLeafHash(script: $0) }
        var proof: [Data] = []
        var idx = leafIndex

        while nodes.count > 1 {
            var nextLevel: [Data] = []
            var i = 0
            while i < nodes.count {
                if i + 1 < nodes.count {
                    // If our target is in this pair, record the sibling
                    if i == idx || i + 1 == idx {
                        let sibling = (i == idx) ? nodes[i + 1] : nodes[i]
                        proof.append(sibling)
                    }
                    nextLevel.append(tapBranchHash(left: nodes[i], right: nodes[i + 1]))
                } else {
                    nextLevel.append(nodes[i])
                }
                i += 2
            }
            idx /= 2
            nodes = nextLevel
        }

        return proof
    }

    // MARK: - Witness builders for Taproot spends

    /// Key-path witness: just the Schnorr signature (64 bytes, or 65 with sighash).
    static func keyPathWitness(signature: Data) -> [Data] {
        [signature]
    }

    /// Script-path witness: [...stack items, script, controlBlock]
    static func scriptPathWitness(stack: [Data], script: Data, controlBlock: Data) -> [Data] {
        var witness = stack
        witness.append(script)
        witness.append(controlBlock)
        return witness
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
