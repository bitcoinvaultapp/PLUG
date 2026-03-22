import Foundation

// MARK: - Spend Manager
// Central engine for spending from all contract types.
// Deterministic: parameters in → PSBT out. No branching, no hidden state.

struct SpendManager {

    static let dustThreshold: UInt64 = 546

    // MARK: - Sequence constants (BIP68/BIP125)

    /// RBF-enabled, no timelock enforcement
    static let seqRBF: UInt32 = 0xFFFFFFFD
    /// Enables nLockTime (absolute timelock)
    static let seqLocktime: UInt32 = 0xFFFFFFFE

    // MARK: - P2WSH Spend (unified for all contract types)

    /// Parameters that vary between contract spend types.
    struct SpendParams {
        let witnessScript: Data
        let utxos: [UTXO]
        let feeRate: Double
        let isTestnet: Bool
        let sequence: UInt32
        let locktime: UInt32
        let witnessSize: Int
        /// Destination outputs (address → amount). nil amount = send all minus fee.
        let destinations: [(address: String, amount: UInt64?)]
        /// Change address (contract address for keep-alive, or nil for no change)
        let changeAddress: String?
    }

    /// Build a P2WSH PSBT from unified parameters.
    /// One function for all P2WSH contract types.
    static func buildP2WSHSpend(_ p: SpendParams) throws -> Data {
        guard !p.utxos.isEmpty else { throw SpendError.insufficientFunds }

        // Validate all destination addresses
        for dest in p.destinations {
            guard PSBTBuilder.scriptPubKeyFromAddress(dest.address, isTestnet: p.isTestnet) != nil else {
                throw SpendError.invalidAddress
            }
        }

        let totalInput = p.utxos.reduce(UInt64(0)) { $0 + $1.value }
        let outputCount = p.destinations.count + (p.changeAddress != nil ? 1 : 0)
        let fee = CoinSelection.estimateP2WSHFee(
            inputCount: p.utxos.count,
            outputCount: max(outputCount, 1),
            witnessSize: p.witnessSize,
            feeRate: p.feeRate
        )

        // Build outputs — handle "send all" (amount == nil) vs fixed amount
        var outputs: [PSBTBuilder.TxOutput] = []
        var allocated: UInt64 = 0

        for dest in p.destinations {
            let destScript = PSBTBuilder.scriptPubKeyFromAddress(dest.address, isTestnet: p.isTestnet)!
            if let amount = dest.amount {
                guard amount >= dustThreshold else { throw SpendError.belowDust }
                outputs.append(PSBTBuilder.TxOutput(value: amount, scriptPubKey: destScript))
                allocated += amount
            } else {
                // Send all: will be filled below
                outputs.append(PSBTBuilder.TxOutput(value: 0, scriptPubKey: destScript))
            }
        }

        guard totalInput >= allocated + fee else { throw SpendError.insufficientFunds }

        // Fill "send all" outputs
        let remaining = totalInput - allocated - fee
        for i in 0..<outputs.count {
            if outputs[i].value == 0 {
                guard remaining >= dustThreshold else { throw SpendError.belowDust }
                outputs[i] = PSBTBuilder.TxOutput(value: remaining, scriptPubKey: outputs[i].scriptPubKey)
            }
        }

        // Change output
        if let changeAddr = p.changeAddress {
            let change = totalInput - allocated - remaining - fee
            if change >= dustThreshold {
                guard let changeScript = PSBTBuilder.scriptPubKeyFromAddress(changeAddr, isTestnet: p.isTestnet) else {
                    throw SpendError.invalidAddress
                }
                outputs.append(PSBTBuilder.TxOutput(value: change, scriptPubKey: changeScript))
            }
        }

        // BIP69: sort outputs for privacy
        outputs.sort { $0.scriptPubKey.hex < $1.scriptPubKey.hex }

        // Build inputs
        let inputs: [PSBTBuilder.TxInput] = p.utxos.map { utxo in
            let spk = Data(hex: utxo.scriptPubKey)
                ?? PSBTBuilder.p2wshScriptPubKey(scriptHash: Crypto.sha256(p.witnessScript))
            return PSBTBuilder.TxInput(
                txid: txidToInternalOrder(utxo.txid),
                vout: UInt32(utxo.vout),
                sequence: p.sequence,
                witnessUtxo: PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk),
                witnessScript: p.witnessScript
            )
        }

        return PSBTBuilder.buildPSBT(inputs: inputs, outputs: outputs, locktime: p.locktime)
    }

    // MARK: - Vault Spend (CLTV)

    static func buildVaultSpendPSBT(
        contract: Contract, utxos: [UTXO],
        destinationAddress: String, feeRate: Double, isTestnet: Bool
    ) throws -> Data {
        guard contract.type == .vault, let lockHeight = contract.lockBlockHeight else {
            throw SpendError.invalidContract
        }
        let ws = try witnessScript(contract)
        return try buildP2WSHSpend(SpendParams(
            witnessScript: ws, utxos: utxos, feeRate: feeRate, isTestnet: isTestnet,
            sequence: seqLocktime, locktime: UInt32(lockHeight),
            witnessSize: ws.count + 72 + 10,
            destinations: [(destinationAddress, nil)], changeAddress: nil
        ))
    }

    static func vaultWitness(signature: Data, witnessScript: Data) -> [Data] {
        [signature, witnessScript]
    }

    // MARK: - Inheritance Keep-Alive (Owner)

    static func buildInheritanceKeepAlivePSBT(
        contract: Contract, utxos: [UTXO],
        feeRate: Double, isTestnet: Bool
    ) throws -> Data {
        guard contract.type == .inheritance else { throw SpendError.invalidContract }
        let ws = try witnessScript(contract)
        return try buildP2WSHSpend(SpendParams(
            witnessScript: ws, utxos: utxos, feeRate: feeRate, isTestnet: isTestnet,
            sequence: seqRBF, locktime: 0,
            witnessSize: ws.count + 72 + 1 + 10,
            destinations: [(contract.address, nil)], changeAddress: nil
        ))
    }

    static func inheritanceKeepAliveWitness(signature: Data, witnessScript: Data) -> [Data] {
        [signature, witnessScript]
    }

    // MARK: - Inheritance Heir Claim (CSV)

    static func buildInheritanceHeirClaimPSBT(
        contract: Contract, utxos: [UTXO],
        destinationAddress: String, feeRate: Double, isTestnet: Bool
    ) throws -> Data {
        guard contract.type == .inheritance, let csvBlocks = contract.csvBlocks else {
            throw SpendError.invalidContract
        }
        let ws = try witnessScript(contract)
        let maskedCSV = UInt32(csvBlocks) & 0x0000FFFF
        return try buildP2WSHSpend(SpendParams(
            witnessScript: ws, utxos: utxos, feeRate: feeRate, isTestnet: isTestnet,
            sequence: maskedCSV, locktime: 0,
            witnessSize: ws.count + 72 + 1 + 10,
            destinations: [(destinationAddress, nil)], changeAddress: nil
        ))
    }

    static func inheritanceHeirClaimWitness(signature: Data, witnessScript: Data) -> [Data] {
        [signature, Data(), witnessScript]
    }

    // MARK: - Pool Spend (Multisig)

    static func buildPoolSpendPSBT(
        contract: Contract, utxos: [UTXO],
        destinationAddress: String, amount: UInt64,
        feeRate: Double, isTestnet: Bool
    ) throws -> Data {
        guard contract.type == .pool else { throw SpendError.invalidContract }
        let ws = try witnessScript(contract)
        let m = contract.multisigM ?? 2
        return try buildP2WSHSpend(SpendParams(
            witnessScript: ws, utxos: utxos, feeRate: feeRate, isTestnet: isTestnet,
            sequence: seqRBF, locktime: 0,
            witnessSize: ws.count + (72 * m) + m + 10,
            destinations: [(destinationAddress, amount)], changeAddress: contract.address
        ))
    }

    // MARK: - HTLC Claim (Receiver)

    static func buildHTLCClaimPSBT(
        contract: Contract, preimage: Data, utxos: [UTXO],
        destinationAddress: String, feeRate: Double, isTestnet: Bool
    ) throws -> Data {
        guard contract.type == .htlc else { throw SpendError.invalidContract }
        guard preimage.count == 32 else { throw SpendError.missingPreimage }
        if let hashLockHex = contract.hashLock {
            guard Crypto.sha256(preimage).hex == hashLockHex else { throw SpendError.missingPreimage }
        }
        let ws = try witnessScript(contract)
        return try buildP2WSHSpend(SpendParams(
            witnessScript: ws, utxos: utxos, feeRate: feeRate, isTestnet: isTestnet,
            sequence: seqRBF, locktime: 0,
            witnessSize: ws.count + 72 + 32 + 1 + 10,
            destinations: [(destinationAddress, nil)], changeAddress: nil
        ))
    }

    static func htlcClaimWitness(signature: Data, preimage: Data, witnessScript: Data) -> [Data] {
        HTLCBuilder.claimWitness(signature: signature, preimage: preimage, witnessScript: witnessScript)
    }

    // MARK: - HTLC Refund (Sender)

    static func buildHTLCRefundPSBT(
        contract: Contract, utxos: [UTXO],
        destinationAddress: String, feeRate: Double, isTestnet: Bool
    ) throws -> Data {
        guard contract.type == .htlc, let timeout = contract.timeoutBlocks else {
            throw SpendError.invalidContract
        }
        let ws = try witnessScript(contract)
        return try buildP2WSHSpend(SpendParams(
            witnessScript: ws, utxos: utxos, feeRate: feeRate, isTestnet: isTestnet,
            sequence: seqLocktime, locktime: UInt32(timeout),
            witnessSize: ws.count + 72 + 1 + 10,
            destinations: [(destinationAddress, nil)], changeAddress: nil
        ))
    }

    static func htlcRefundWitness(signature: Data, witnessScript: Data) -> [Data] {
        HTLCBuilder.refundWitness(signature: signature, witnessScript: witnessScript)
    }

    // MARK: - Channel Cooperative Close

    static func buildChannelCooperativeClosePSBT(
        contract: Contract, utxos: [UTXO],
        senderAmount: UInt64, receiverAmount: UInt64,
        senderAddress: String, receiverAddress: String,
        feeRate: Double, isTestnet: Bool
    ) throws -> Data {
        guard contract.type == .channel else { throw SpendError.invalidContract }
        let ws = try witnessScript(contract)
        var dests: [(String, UInt64?)] = []
        if senderAmount >= dustThreshold { dests.append((senderAddress, senderAmount)) }
        if receiverAmount >= dustThreshold { dests.append((receiverAddress, receiverAmount)) }
        return try buildP2WSHSpend(SpendParams(
            witnessScript: ws, utxos: utxos, feeRate: feeRate, isTestnet: isTestnet,
            sequence: seqRBF, locktime: 0,
            witnessSize: ws.count + (72 * 2) + 1 + 1 + 10,
            destinations: dests, changeAddress: nil
        ))
    }

    static func channelCooperativeCloseWitness(
        senderSig: Data, receiverSig: Data, witnessScript: Data
    ) -> [Data] {
        PaymentChannelBuilder.cooperativeCloseWitness(
            senderSig: senderSig, receiverSig: receiverSig, witnessScript: witnessScript
        )
    }

    // MARK: - Channel Unilateral Refund

    static func buildChannelRefundPSBT(
        contract: Contract, utxos: [UTXO],
        destinationAddress: String, feeRate: Double, isTestnet: Bool
    ) throws -> Data {
        guard contract.type == .channel, let timeout = contract.timeoutBlocks else {
            throw SpendError.invalidContract
        }
        let ws = try witnessScript(contract)
        return try buildP2WSHSpend(SpendParams(
            witnessScript: ws, utxos: utxos, feeRate: feeRate, isTestnet: isTestnet,
            sequence: seqLocktime, locktime: UInt32(timeout),
            witnessSize: ws.count + 72 + 1 + 10,
            destinations: [(destinationAddress, nil)], changeAddress: nil
        ))
    }

    static func channelRefundWitness(signature: Data, witnessScript: Data) -> [Data] {
        PaymentChannelBuilder.refundWitness(senderSig: signature, witnessScript: witnessScript)
    }

    // MARK: - Taproot Key-Path Spend

    static func buildTaprootKeyPathSpendPSBT(
        contract: Contract, utxos: [UTXO],
        destinationAddress: String, feeRate: Double, isTestnet: Bool
    ) throws -> Data {
        guard PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet) != nil else {
            throw SpendError.invalidAddress
        }
        guard !utxos.isEmpty else { throw SpendError.insufficientFunds }

        let totalInput = utxos.reduce(UInt64(0)) { $0 + $1.value }
        let fee = estimateTaprootKeyPathFee(inputCount: utxos.count, outputCount: 1, feeRate: feeRate)
        guard totalInput > fee else { throw SpendError.insufficientFunds }
        let outputAmount = totalInput - fee
        guard outputAmount >= dustThreshold else { throw SpendError.belowDust }

        let destScript = PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet)!
        let xOnlyKey = contract.taprootInternalKey.flatMap { Data(hex: $0) }.flatMap { $0.count == 32 ? $0 : nil }
        let spk = Data(hex: contract.scriptPubKey ?? "")
            ?? PSBTBuilder.scriptPubKeyFromAddress(contract.address, isTestnet: isTestnet) ?? Data()

        let inputs: [PSBTBuilder.TxInput] = utxos.map { utxo in
            var input = PSBTBuilder.TxInput(
                txid: txidToInternalOrder(utxo.txid),
                vout: UInt32(utxo.vout), sequence: seqRBF,
                witnessUtxo: PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk)
            )
            input.tapInternalKey = xOnlyKey
            return input
        }

        return PSBTBuilder.buildPSBT(
            inputs: inputs,
            outputs: [PSBTBuilder.TxOutput(value: outputAmount, scriptPubKey: destScript)],
            locktime: 0
        )
    }

    static func taprootKeyPathWitness(signature: Data) -> [Data] {
        TaprootBuilder.keyPathWitness(signature: signature)
    }

    // MARK: - Taproot Script-Path Spend

    static func buildTaprootScriptPathSpendPSBT(
        contract: Contract, utxos: [UTXO],
        destinationAddress: String, feeRate: Double, isTestnet: Bool,
        locktime: UInt32 = 0, sequence: UInt32 = seqLocktime
    ) throws -> Data {
        guard PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet) != nil else {
            throw SpendError.invalidAddress
        }
        guard !utxos.isEmpty else { throw SpendError.insufficientFunds }
        let ws = try witnessScript(contract)

        let totalInput = utxos.reduce(UInt64(0)) { $0 + $1.value }
        let controlBlockSize = 33 + (contract.taprootScripts?.count ?? 1 > 1 ? 32 : 0)
        let witnessSize = ws.count + 64 + controlBlockSize + 10
        let inputVsize = 41 + (witnessSize + 3) / 4
        let vsize = 11 + (inputVsize * utxos.count) + 43
        let fee = UInt64(ceil(Double(vsize) * feeRate))
        guard totalInput > fee else { throw SpendError.insufficientFunds }
        let outputAmount = totalInput - fee
        guard outputAmount >= dustThreshold else { throw SpendError.belowDust }

        let destScript = PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet)!
        let xOnlyKey = contract.taprootInternalKey.flatMap { Data(hex: $0) }.flatMap { $0.count == 32 ? $0 : nil }
        let merkleRoot = contract.taprootMerkleRoot.flatMap { Data(hex: $0) }.flatMap { $0.count == 32 ? $0 : nil }
        let spk = Data(hex: contract.scriptPubKey ?? "")
            ?? PSBTBuilder.scriptPubKeyFromAddress(contract.address, isTestnet: isTestnet) ?? Data()

        let inputs: [PSBTBuilder.TxInput] = utxos.map { utxo in
            var input = PSBTBuilder.TxInput(
                txid: txidToInternalOrder(utxo.txid),
                vout: UInt32(utxo.vout), sequence: sequence,
                witnessUtxo: PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk),
                witnessScript: ws
            )
            input.tapInternalKey = xOnlyKey
            input.tapMerkleRoot = merkleRoot
            return input
        }

        return PSBTBuilder.buildPSBT(
            inputs: inputs,
            outputs: [PSBTBuilder.TxOutput(value: outputAmount, scriptPubKey: destScript)],
            locktime: locktime
        )
    }

    static func taprootScriptPathWitness(signature: Data, script: Data, controlBlock: Data) -> [Data] {
        TaprootBuilder.scriptPathWitness(stack: [signature], script: script, controlBlock: controlBlock)
    }

    // MARK: - Fee Estimation

    static func estimateTaprootKeyPathFee(inputCount: Int, outputCount: Int, feeRate: Double) -> UInt64 {
        UInt64(ceil(Double(11 + (57 * inputCount) + (43 * outputCount)) * feeRate))
    }

    static func estimateP2WSHVsize(witnessScriptSize: Int) -> Int {
        41 + (witnessScriptSize + 72 + 10 + 3) / 4
    }

    static func estimateFee(contract: Contract, utxoCount: Int, outputCount: Int, feeRate: Double) -> UInt64 {
        CoinSelection.estimateP2WSHFee(
            inputCount: utxoCount, outputCount: outputCount,
            witnessSize: contract.script.count / 2 + 72 + 10, feeRate: feeRate
        )
    }

    // MARK: - PSBT Finalization

    static func finalizePSBT(psbtData: Data, witnessStacks: [[Data]]) -> Data? {
        guard let parsed = PSBTBuilder.parsePSBT(psbtData),
              let unsignedTx = parsed.unsignedTx else { return nil }

        var tx = Data()
        tx.append(Data(unsignedTx[0..<4]))  // version
        tx.append(contentsOf: [0x00, 0x01]) // segwit marker

        var offset = 4
        guard let (inputCount, icBytes) = VarInt.decode(unsignedTx, offset: offset) else { return nil }
        offset += icBytes
        tx.append(VarInt.encode(inputCount))

        // Copy inputs (empty scriptSig for segwit)
        for _ in 0..<Int(inputCount) {
            guard offset + 36 <= unsignedTx.count else { return nil }
            tx.append(Data(unsignedTx[offset..<(offset + 36)])) // txid + vout
            offset += 36
            guard let (scriptLen, slBytes) = VarInt.decode(unsignedTx, offset: offset) else { return nil }
            offset += slBytes + Int(scriptLen)
            tx.append(0x00) // empty scriptSig
            guard offset + 4 <= unsignedTx.count else { return nil }
            tx.append(Data(unsignedTx[offset..<(offset + 4)])) // sequence
            offset += 4
        }

        // Copy outputs
        guard let (outputCount, ocBytes) = VarInt.decode(unsignedTx, offset: offset) else { return nil }
        offset += ocBytes
        tx.append(VarInt.encode(outputCount))

        for _ in 0..<Int(outputCount) {
            guard offset + 8 <= unsignedTx.count else { return nil }
            tx.append(Data(unsignedTx[offset..<(offset + 8)])) // value
            offset += 8
            guard let (spkLen, spkBytes) = VarInt.decode(unsignedTx, offset: offset) else { return nil }
            tx.append(VarInt.encode(spkLen))
            offset += spkBytes
            guard offset + Int(spkLen) <= unsignedTx.count else { return nil }
            tx.append(Data(unsignedTx[offset..<(offset + Int(spkLen))]))
            offset += Int(spkLen)
        }

        // Witness data
        for i in 0..<Int(inputCount) {
            if i < witnessStacks.count {
                let stack = witnessStacks[i]
                tx.append(VarInt.encode(UInt64(stack.count)))
                for item in stack {
                    tx.append(VarInt.encode(UInt64(item.count)))
                    tx.append(item)
                }
            } else {
                tx.append(0x00)
            }
        }

        // Locktime
        tx.append(Data(unsignedTx[(unsignedTx.count - 4)...]))
        return tx
    }

    static func extractTransactionHex(_ txData: Data) -> String { txData.hex }
    static func exportPSBTBase64(_ psbtData: Data) -> String { psbtData.base64EncodedString() }

    // MARK: - Transaction Validation

    static func validateTransaction(_ txData: Data) -> (valid: Bool, reason: String) {
        guard txData.count > 60 else { return (false, "Transaction too small") }
        guard txData.count < 400_000 else { return (false, "Transaction too large") }

        let version = UInt32(txData[0]) | (UInt32(txData[1]) << 8) | (UInt32(txData[2]) << 16) | (UInt32(txData[3]) << 24)
        guard version == 1 || version == 2 else { return (false, "Invalid version \(version)") }
        guard txData[4] == 0x00 && txData[5] == 0x01 else { return (false, "Missing segwit marker") }

        guard let (inputCount, _) = VarInt.decode(txData, offset: 6), inputCount >= 1 else {
            return (false, "No inputs")
        }

        // Walk inputs to find outputs
        var offset = 6
        guard let (inCount, icBytes) = VarInt.decode(txData, offset: offset) else { return (false, "Bad input count") }
        offset += icBytes
        for _ in 0..<Int(inCount) {
            guard offset + 36 <= txData.count else { return (false, "Truncated inputs") }
            offset += 36
            guard let (sl, slb) = VarInt.decode(txData, offset: offset) else { return (false, "Bad scriptSig") }
            offset += slb + Int(sl) + 4
            guard offset <= txData.count else { return (false, "Truncated inputs") }
        }

        guard let (outputCount, _) = VarInt.decode(txData, offset: offset), outputCount >= 1 else {
            return (false, "No outputs")
        }

        return (true, "OK")
    }

    // MARK: - Broadcast

    static func broadcast(txHex: String) async throws -> String {
        if !NetworkConfig.shared.isTestnet { throw SpendError.mainnetDisabled }
        guard let txData = Data(hex: txHex) else { throw SpendError.invalidTransaction("Bad hex") }
        let v = validateTransaction(txData)
        guard v.valid else { throw SpendError.invalidTransaction(v.reason) }
        return try await MempoolAPI.shared.broadcastTransaction(hex: txHex)
    }

    // MARK: - Helpers

    static func txidToInternalOrder(_ txid: String) -> Data {
        guard let data = Data(hex: txid) else { return Data(count: 32) }
        return Data(data.reversed())
    }

    private static func witnessScript(_ contract: Contract) throws -> Data {
        guard let ws = Data(hex: contract.script) else { throw SpendError.invalidContract }
        return ws
    }

    // MARK: - Errors

    enum SpendError: LocalizedError {
        case insufficientFunds, invalidContract, invalidAddress
        case belowDust, timelockNotReached, missingPreimage
        case signingFailed, mainnetDisabled, invalidTransaction(String)

        var errorDescription: String? {
            switch self {
            case .insufficientFunds: return "Insufficient funds"
            case .invalidContract: return "Invalid contract"
            case .invalidAddress: return "Invalid destination address"
            case .belowDust: return "Amount below dust threshold (546 sats)"
            case .timelockNotReached: return "Timelock not yet reached"
            case .missingPreimage: return "Missing or invalid preimage"
            case .signingFailed: return "Signing failed"
            case .mainnetDisabled: return "Mainnet broadcast disabled — use testnet for testing"
            case .invalidTransaction(let r): return "Invalid transaction: \(r)"
            }
        }
    }
}
