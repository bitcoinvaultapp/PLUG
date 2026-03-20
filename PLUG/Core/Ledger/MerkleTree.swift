import Foundation

// MARK: - Merkle Tree (Ledger-specific: leaf=SHA256(0x00+data), node=SHA256(0x01+left+right))
// Extracted from LedgerSigningV2.swift

extension LedgerSigningV2 {

    struct MerkleTree {
        let leaves: [Data] // raw leaf data (unhashed)
        let hashedLeaves: [Data] // SHA256(0x00 + leaf)

        init(leaves: [Data]) {
            self.leaves = leaves
            self.hashedLeaves = leaves.map { Self.hashLeaf($0) }
        }

        static func hashLeaf(_ data: Data) -> Data {
            Crypto.sha256(Data([0x00]) + data)
        }

        static func hashNode(_ left: Data, _ right: Data) -> Data {
            Crypto.sha256(Data([0x01]) + left + right)
        }

        var root: Data {
            if hashedLeaves.isEmpty { return Crypto.sha256(Data(repeating: 0, count: 32)) }
            if hashedLeaves.count == 1 { return hashedLeaves[0] }
            return Self.computeRoot(hashedLeaves)
        }

        private static func computeRoot(_ hashes: [Data]) -> Data {
            if hashes.count == 1 { return hashes[0] }
            // Split at highest power of 2 less than count
            let split = highestPow2LessThan(hashes.count)
            let left = computeRoot(Array(hashes[0..<split]))
            let right = computeRoot(Array(hashes[split...]))
            return hashNode(left, right)
        }

        private static func highestPow2LessThan(_ n: Int) -> Int {
            var p = 1
            while p * 2 < n { p *= 2 }
            return p
        }

        func proof(forIndex idx: Int) -> [Data] {
            Self.buildProof(hashedLeaves, index: idx)
        }

        private static func buildProof(_ hashes: [Data], index: Int) -> [Data] {
            if hashes.count <= 1 { return [] }
            let split = highestPow2LessThan(hashes.count)
            if index < split {
                let rightHash = computeRoot(Array(hashes[split...]))
                return buildProof(Array(hashes[0..<split]), index: index) + [rightHash]
            } else {
                let leftHash = computeRoot(Array(hashes[0..<split]))
                return buildProof(Array(hashes[split...]), index: index - split) + [leftHash]
            }
        }
    }

    // MARK: - MerkleMap (sorted keys + values, each in their own tree)

    struct MerkleMap {
        let sortedKeys: [Data]
        let sortedValues: [Data]
        let keysTree: MerkleTree
        let valuesTree: MerkleTree

        init(keys: [Data], values: [Data]) {
            // Sort keys lexicographically, reorder values to match
            let paired = zip(keys, values).sorted { $0.0.hex < $1.0.hex }
            self.sortedKeys = paired.map { $0.0 }
            self.sortedValues = paired.map { $0.1 }
            self.keysTree = MerkleTree(leaves: sortedKeys)
            self.valuesTree = MerkleTree(leaves: sortedValues)
        }

        /// Commitment = varint(n) + keysRoot + valuesRoot
        var commitment: Data {
            var data = Data()
            data.append(VarInt.encode(UInt64(sortedKeys.count)))
            data.append(keysTree.root)
            data.append(valuesTree.root)
            return data
        }
    }
}
