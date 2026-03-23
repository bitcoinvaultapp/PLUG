import Foundation

// MARK: - Core Data Models

struct UTXO: Identifiable, Codable, Equatable {
    let txid: String
    let vout: Int
    let value: UInt64       // satoshis
    let address: String
    let scriptPubKey: String
    let status: UTXOStatus

    var id: String { outpoint }
    var outpoint: String { "\(txid):\(vout)" }

    struct UTXOStatus: Codable, Equatable {
        let confirmed: Bool
        let blockHeight: Int?
        let blockHash: String?

        enum CodingKeys: String, CodingKey {
            case confirmed
            case blockHeight = "block_height"
            case blockHash = "block_hash"
        }
    }

    enum CodingKeys: String, CodingKey {
        case txid, vout, value, address, status
        case scriptPubKey = "scriptpubkey"
    }
}

struct Transaction: Identifiable, Codable {
    let txid: String
    let version: Int
    let locktime: Int
    let size: Int
    let weight: Int
    let fee: Int
    let status: TxStatus
    let vin: [TxInput]
    let vout: [TxOutput]

    var id: String { txid }

    struct TxStatus: Codable {
        let confirmed: Bool
        let blockHeight: Int?
        let blockTime: Int?

        enum CodingKeys: String, CodingKey {
            case confirmed
            case blockHeight = "block_height"
            case blockTime = "block_time"
        }
    }

    struct TxInput: Codable {
        let txid: String
        let vout: Int
        let prevout: TxOutput?
        let sequence: UInt32
        let witness: [String]?
    }

    struct TxOutput: Codable {
        let scriptpubkey: String
        let scriptpubkeyAddress: String?
        let scriptpubkeyType: String?
        let value: UInt64

        enum CodingKeys: String, CodingKey {
            case scriptpubkey, value
            case scriptpubkeyAddress = "scriptpubkey_address"
            case scriptpubkeyType = "scriptpubkey_type"
        }
    }
}

// MARK: - Contract types

enum ContractType: String, Codable, CaseIterable {
    case vault
    case inheritance
    case pool
    case htlc
    case channel
}

struct Contract: Identifiable, Codable, Hashable {
    static func == (lhs: Contract, rhs: Contract) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let id: String
    let type: ContractType
    let name: String
    let createdAt: Date
    var script: String       // hex script
    var witnessScript: String // hex
    var address: String      // P2WSH address
    var amount: UInt64       // satoshis locked
    var isTestnet: Bool

    // Type-specific fields
    var lockBlockHeight: Int?     // Vault: CLTV block height
    var csvBlocks: Int?           // Inheritance: CSV relative blocks
    var ownerPubkey: String?      // Inheritance: owner pubkey hex
    var heirPubkey: String?       // Inheritance: heir pubkey hex
    var multisigM: Int?           // Pool: M threshold
    var multisigPubkeys: [String]? // Pool: all pubkeys hex

    // HTLC / Channel fields
    var hashLock: String?         // HTLC: SHA256 hash lock hex
    var preimage: String?         // HTLC: preimage hex (sender keeps)
    var senderPubkey: String?     // HTLC / Channel: sender pubkey hex
    var receiverPubkey: String?   // HTLC / Channel: receiver pubkey hex
    var timeoutBlocks: Int?       // HTLC / Channel: CLTV timeout block height

    var isUnlocked: Bool = false
    var lastKeptAlive: Date?
    var txid: String?             // Funding txid
    var keyIndex: UInt32?         // BIP32 derivation index used to create this contract (m/84'/ct'/0'/0/keyIndex)

    // V2 wallet policy registration (for Ledger signing via SIGN_PSBT)
    var walletPolicyHmac: String?     // 32-byte HMAC hex from REGISTER_WALLET
    var walletPolicyDescriptor: String? // descriptor template, e.g. "wsh(and_v(v:pk(@0/**),after(850000)))"
    var masterFingerprint: String?    // master fingerprint used when HMAC was registered

    // External party xpubs (needed for V2 multi-key policies)
    var heirXpub: String?             // Inheritance: heir's xpub/tpub
    var receiverXpub: String?         // HTLC/Channel: receiver xpub
    var senderXpub: String?           // HTLC/Channel: sender xpub (when signing as receiver)
    var multisigXpubs: [String]?      // Pool: all co-signer xpubs

    // Atomic Swap fields (only set when HTLC is part of a swap)
    var swapId: String?                   // Shared UUID linking both legs
    var swapRole: String?                 // "initiator" or "responder"
    var counterpartyHTLCAddress: String?  // Other party's HTLC address to monitor
    var swapState: String?                // "created" | "funded" | "counterpartyFunded" | "claiming" | "completed" | "refunded"

    // Taproot (P2TR) fields
    var isTaproot: Bool = false           // true if this is a P2TR contract
    var taprootInternalKey: String?       // 32-byte x-only internal key hex
    var taprootMerkleRoot: String?        // 32-byte MAST root hex (nil for key-path only)
    var taprootScripts: [String]?         // hex scripts in the MAST tree
    var scriptPubKey: String?             // hex scriptPubKey (OP_1 <tweaked_key> for P2TR)

    static func newVault(
        name: String,
        script: Data,
        witnessScript: Data,
        address: String,
        lockBlockHeight: Int,
        amount: UInt64,
        isTestnet: Bool
    ) -> Contract {
        Contract(
            id: UUID().uuidString,
            type: .vault,
            name: name,
            createdAt: Date(),
            script: script.hex,
            witnessScript: witnessScript.hex,
            address: address,
            amount: amount,
            isTestnet: isTestnet,
            lockBlockHeight: lockBlockHeight
        )
    }

    static func newInheritance(
        name: String,
        script: Data,
        witnessScript: Data,
        address: String,
        csvBlocks: Int,
        ownerPubkey: Data,
        heirPubkey: Data,
        amount: UInt64,
        isTestnet: Bool
    ) -> Contract {
        Contract(
            id: UUID().uuidString,
            type: .inheritance,
            name: name,
            createdAt: Date(),
            script: script.hex,
            witnessScript: witnessScript.hex,
            address: address,
            amount: amount,
            isTestnet: isTestnet,
            csvBlocks: csvBlocks,
            ownerPubkey: ownerPubkey.hex,
            heirPubkey: heirPubkey.hex
        )
    }

    static func newPool(
        name: String,
        script: Data,
        witnessScript: Data,
        address: String,
        m: Int,
        pubkeys: [Data],
        amount: UInt64,
        isTestnet: Bool
    ) -> Contract {
        Contract(
            id: UUID().uuidString,
            type: .pool,
            name: name,
            createdAt: Date(),
            script: script.hex,
            witnessScript: witnessScript.hex,
            address: address,
            amount: amount,
            isTestnet: isTestnet,
            multisigM: m,
            multisigPubkeys: pubkeys.map { $0.hex }
        )
    }

    static func newHTLC(
        name: String,
        script: Data,
        witnessScript: Data,
        address: String,
        hashLock: Data,
        senderPubkey: Data,
        receiverPubkey: Data,
        timeoutBlocks: Int,
        amount: UInt64,
        isTestnet: Bool
    ) -> Contract {
        Contract(
            id: UUID().uuidString,
            type: .htlc,
            name: name,
            createdAt: Date(),
            script: script.hex,
            witnessScript: witnessScript.hex,
            address: address,
            amount: amount,
            isTestnet: isTestnet,
            hashLock: hashLock.hex,
            senderPubkey: senderPubkey.hex,
            receiverPubkey: receiverPubkey.hex,
            timeoutBlocks: timeoutBlocks
        )
    }

    static func newChannel(
        name: String,
        script: Data,
        witnessScript: Data,
        address: String,
        senderPubkey: Data,
        receiverPubkey: Data,
        timeoutBlocks: Int,
        amount: UInt64,
        isTestnet: Bool
    ) -> Contract {
        Contract(
            id: UUID().uuidString,
            type: .channel,
            name: name,
            createdAt: Date(),
            script: script.hex,
            witnessScript: witnessScript.hex,
            address: address,
            amount: amount,
            isTestnet: isTestnet,
            senderPubkey: senderPubkey.hex,
            receiverPubkey: receiverPubkey.hex,
            timeoutBlocks: timeoutBlocks
        )
    }

    static func newTaprootVault(
        name: String,
        internalKey: Data,
        tweakedKey: Data,
        address: String,
        lockBlockHeight: Int,
        amount: UInt64,
        isTestnet: Bool,
        script: Data? = nil,
        merkleRoot: Data? = nil,
        scripts: [Data]? = nil
    ) -> Contract {
        Contract(
            id: UUID().uuidString,
            type: .vault,
            name: name,
            createdAt: Date(),
            script: script?.hex ?? "",
            witnessScript: "",
            address: address,
            amount: amount,
            isTestnet: isTestnet,
            lockBlockHeight: lockBlockHeight,
            isTaproot: true,
            taprootInternalKey: internalKey.hex,
            taprootMerkleRoot: merkleRoot?.hex,
            taprootScripts: scripts?.map { $0.hex },
            scriptPubKey: TaprootBuilder.p2trScriptPubKey(tweakedKey: tweakedKey).hex
        )
    }

    static func newTaprootInheritance(
        name: String,
        internalKey: Data,
        tweakedKey: Data,
        address: String,
        csvBlocks: Int,
        ownerPubkey: Data,
        heirPubkey: Data,
        amount: UInt64,
        isTestnet: Bool,
        scripts: [Data]? = nil,
        merkleRoot: Data? = nil
    ) -> Contract {
        Contract(
            id: UUID().uuidString,
            type: .inheritance,
            name: name,
            createdAt: Date(),
            script: "",
            witnessScript: "",
            address: address,
            amount: amount,
            isTestnet: isTestnet,
            csvBlocks: csvBlocks,
            ownerPubkey: ownerPubkey.hex,
            heirPubkey: heirPubkey.hex,
            isTaproot: true,
            taprootInternalKey: internalKey.hex,
            taprootMerkleRoot: merkleRoot?.hex,
            taprootScripts: scripts?.map { $0.hex },
            scriptPubKey: TaprootBuilder.p2trScriptPubKey(tweakedKey: tweakedKey).hex
        )
    }
}

// MARK: - Network data models

struct BlockchainInfo: Codable {
    let height: Int
    let hash: String
    let time: Int
    let medianTime: Int

    enum CodingKeys: String, CodingKey {
        case height, hash, time
        case medianTime = "median_time"
    }
}

struct FeeEstimate: Codable {
    let fastestFee: Int
    let halfHourFee: Int
    let hourFee: Int
    let economyFee: Int
    let minimumFee: Int
}

struct MempoolInfo: Codable {
    let count: Int
    let vsize: Int
    let totalFee: Double

    enum CodingKeys: String, CodingKey {
        case count, vsize
        case totalFee = "total_fee"
    }
}

struct DifficultyAdjustment: Codable {
    let progressPercent: Double
    let difficultyChange: Double
    let estimatedRetargetDate: Int
    let remainingBlocks: Int
    let remainingTime: Int
    let previousRetarget: Double
    let nextRetargetHeight: Int
    let timeAvg: Int
    let timeOffset: Int
}

// MARK: - Wallet state

struct WalletAddress: Identifiable, Codable, Hashable {
    let index: UInt32
    let address: String
    let publicKey: String // hex
    let isChange: Bool
    var addressType: AddressType

    var id: String { address }

    enum AddressType: String, Codable {
        case p2wpkh  // bc1q... (BIP84, m/84'/0'/0')
        case p2tr    // bc1p... (BIP86, m/86'/0'/0')
    }

    /// Convenience init with default type (backward compatibility)
    init(index: UInt32, address: String, publicKey: String, isChange: Bool, addressType: AddressType = .p2wpkh) {
        self.index = index
        self.address = address
        self.publicKey = publicKey
        self.isChange = isChange
        self.addressType = addressType
    }

    /// Address lifecycle for privacy hygiene.
    /// Fresh → Funded (received sats) → Used (spent from, pubkey exposed on-chain).
    /// Never reuse a Used address — derive a new one instead.
    enum Status: String, Codable {
        case fresh       // Never seen on-chain — safe to receive
        case funded      // Has unspent UTXOs — holding funds
        case used        // Spent from — public key exposed, retired
    }
}

// MARK: - Alert types for dashboard

enum DashboardAlert: Identifiable {
    case vaultUnlocked(contractId: String, contractName: String)
    case inheritanceApproaching(contractId: String, contractName: String, blocksRemaining: Int)
    case unconfirmedTx(txid: String)

    var id: String {
        switch self {
        case .vaultUnlocked(let cid, _): return "vault_\(cid)"
        case .inheritanceApproaching(let cid, _, _): return "inheritance_\(cid)"
        case .unconfirmedTx(let txid): return "tx_\(txid)"
        }
    }

    var message: String {
        switch self {
        case .vaultUnlocked(_, let name):
            return "Vault \"\(name)\" is unlocked!"
        case .inheritanceApproaching(_, let name, let blocks):
            return "Inheritance \"\(name)\": \(blocks) blocks remaining"
        case .unconfirmedTx(let txid):
            return "Unconfirmed transaction: \(String(txid.prefix(8)))..."
        }
    }
}
