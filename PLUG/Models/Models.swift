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
    case tirelire
    case heritage
    case cagnotte
    case htlc
    case channel
}

struct Contract: Identifiable, Codable {
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
    var lockBlockHeight: Int?     // Tirelire: CLTV block height
    var csvBlocks: Int?           // Heritage: CSV relative blocks
    var ownerPubkey: String?      // Heritage: owner pubkey hex
    var heirPubkey: String?       // Heritage: heir pubkey hex
    var multisigM: Int?           // Cagnotte: M threshold
    var multisigPubkeys: [String]? // Cagnotte: all pubkeys hex

    // HTLC / Channel fields
    var hashLock: String?         // HTLC: SHA256 hash lock hex
    var preimage: String?         // HTLC: preimage hex (sender keeps)
    var senderPubkey: String?     // HTLC / Channel: sender pubkey hex
    var receiverPubkey: String?   // HTLC / Channel: receiver pubkey hex
    var timeoutBlocks: Int?       // HTLC / Channel: CLTV timeout block height

    var isUnlocked: Bool = false
    var lastKeptAlive: Date?
    var txid: String?             // Funding txid

    // V2 wallet policy registration (for Ledger signing via SIGN_PSBT)
    var walletPolicyHmac: String?     // 32-byte HMAC hex from REGISTER_WALLET
    var walletPolicyDescriptor: String? // descriptor template, e.g. "wsh(and_v(v:pk(@0/**),after(850000)))"

    // External party xpubs (needed for V2 multi-key policies)
    var heirXpub: String?             // Heritage: heir's xpub/tpub
    var receiverXpub: String?         // HTLC/Channel: receiver xpub
    var senderXpub: String?           // HTLC/Channel: sender xpub (when signing as receiver)
    var multisigXpubs: [String]?      // Cagnotte: all co-signer xpubs

    static func newTirelire(
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
            type: .tirelire,
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

    static func newHeritage(
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
            type: .heritage,
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

    static func newCagnotte(
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
            type: .cagnotte,
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

struct WalletAddress: Identifiable, Codable {
    let index: UInt32
    let address: String
    let publicKey: String // hex
    let isChange: Bool

    var id: String { address }
}

// MARK: - Alert types for dashboard

enum DashboardAlert: Identifiable {
    case vaultUnlocked(contractName: String)
    case heritageApproaching(contractName: String, blocksRemaining: Int)
    case unconfirmedTx(txid: String)

    var id: String {
        switch self {
        case .vaultUnlocked(let name): return "vault_\(name)"
        case .heritageApproaching(let name, _): return "heritage_\(name)"
        case .unconfirmedTx(let txid): return "tx_\(txid)"
        }
    }

    var message: String {
        switch self {
        case .vaultUnlocked(let name):
            return "Vault \"\(name)\" is unlocked!"
        case .heritageApproaching(let name, let blocks):
            return "Heritage \"\(name)\": \(blocks) blocks remaining"
        case .unconfirmedTx(let txid):
            return "Unconfirmed transaction: \(String(txid.prefix(8)))..."
        }
    }
}
