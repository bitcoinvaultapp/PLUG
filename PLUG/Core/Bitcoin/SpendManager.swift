import Foundation

// MARK: - Spend Manager
// Central engine for spending from all contract types.
// Handles PSBT construction, witness stack building, finalization, and broadcast.

struct SpendManager {

    // MARK: - Constants

    static let dustThreshold: UInt64 = 546

    // MARK: - Vault Spend

    /// Build PSBT for spending from a vault (CLTV timelock).
    /// Witness stack: [signature, witnessScript]
    /// nLockTime = contract.lockBlockHeight, sequence = 0xFFFFFFFE
    static func buildVaultSpendPSBT(
        contract: Contract,
        utxos: [UTXO],
        destinationAddress: String,
        feeRate: Double,
        isTestnet: Bool
    ) throws -> Data {
        guard contract.type == .vault else {
            throw SpendError.invalidContract
        }
        guard let lockHeight = contract.lockBlockHeight else {
            throw SpendError.invalidContract
        }
        guard let witnessScriptData = Data(hex: contract.script) else {
            throw SpendError.invalidContract
        }
        guard PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet) != nil else {
            throw SpendError.invalidAddress
        }
        guard !utxos.isEmpty else {
            throw SpendError.insufficientFunds
        }

        let totalInput = utxos.reduce(UInt64(0)) { $0 + $1.value }
        let witnessSize = witnessScriptData.count + 72 + 10 // script + sig + overhead
        let fee = CoinSelection.estimateP2WSHFee(
            inputCount: utxos.count,
            outputCount: 1,
            witnessSize: witnessSize,
            feeRate: feeRate
        )

        guard totalInput > fee else {
            throw SpendError.insufficientFunds
        }

        let outputAmount = totalInput - fee
        guard outputAmount >= dustThreshold else {
            throw SpendError.belowDust
        }

        let destScript = PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet)!

        // Build inputs with sequence 0xFFFFFFFE to enable nLockTime
        let inputs: [PSBTBuilder.TxInput] = utxos.map { utxo in
            let txidInternal = txidToInternalOrder(utxo.txid)
            let spk = Data(hex: utxo.scriptPubKey) ?? PSBTBuilder.p2wshScriptPubKey(scriptHash: Crypto.sha256(witnessScriptData))
            return PSBTBuilder.TxInput(
                txid: txidInternal,
                vout: UInt32(utxo.vout),
                sequence: 0xFFFFFFFE,
                witnessUtxo: PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk),
                witnessScript: witnessScriptData
            )
        }

        let outputs = [
            PSBTBuilder.TxOutput(value: outputAmount, scriptPubKey: destScript)
        ]

        return PSBTBuilder.buildPSBT(
            inputs: inputs,
            outputs: outputs,
            locktime: UInt32(lockHeight)
        )
    }

    /// Build witness stack for vault spend
    static func vaultWitness(signature: Data, witnessScript: Data) -> [Data] {
        [signature, witnessScript]
    }

    // MARK: - Inheritance Keep-Alive (Owner)

    /// Build PSBT for inheritance keep-alive (owner resets CSV timer).
    /// Witness stack: [signature, 0x01, witnessScript]
    /// Spends back to SAME inheritance address. sequence = 0xFFFFFFFD (RBF enabled).
    static func buildInheritanceKeepAlivePSBT(
        contract: Contract,
        utxos: [UTXO],
        feeRate: Double,
        isTestnet: Bool
    ) throws -> Data {
        guard contract.type == .inheritance else {
            throw SpendError.invalidContract
        }
        guard let witnessScriptData = Data(hex: contract.script) else {
            throw SpendError.invalidContract
        }
        guard !utxos.isEmpty else {
            throw SpendError.insufficientFunds
        }

        let totalInput = utxos.reduce(UInt64(0)) { $0 + $1.value }
        let witnessSize = witnessScriptData.count + 72 + 1 + 10
        let fee = CoinSelection.estimateP2WSHFee(
            inputCount: utxos.count,
            outputCount: 1,
            witnessSize: witnessSize,
            feeRate: feeRate
        )

        guard totalInput > fee else {
            throw SpendError.insufficientFunds
        }

        let outputAmount = totalInput - fee
        guard outputAmount >= dustThreshold else {
            throw SpendError.belowDust
        }

        guard let destScript = PSBTBuilder.scriptPubKeyFromAddress(contract.address, isTestnet: isTestnet) else {
            throw SpendError.invalidAddress
        }

        // sequence 0xFFFFFFFD: no CSV enforcement (IF branch) + RBF enabled (BIP125)
        let inputs: [PSBTBuilder.TxInput] = utxos.map { utxo in
            let txidInternal = txidToInternalOrder(utxo.txid)
            let spk = Data(hex: utxo.scriptPubKey) ?? PSBTBuilder.p2wshScriptPubKey(scriptHash: Crypto.sha256(witnessScriptData))
            return PSBTBuilder.TxInput(
                txid: txidInternal,
                vout: UInt32(utxo.vout),
                sequence: 0xFFFFFFFD, // RBF signal per BIP125
                witnessUtxo: PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk),
                witnessScript: witnessScriptData
            )
        }

        let outputs = [
            PSBTBuilder.TxOutput(value: outputAmount, scriptPubKey: destScript)
        ]

        // Anti-fee-sniping: use current block height as locktime
        return PSBTBuilder.buildPSBT(inputs: inputs, outputs: outputs, locktime: 0)
    }

    /// Build witness stack for inheritance owner keep-alive (or_d primary path)
    /// The owner signature satisfies pk(@0) directly — OP_IFDUP sees TRUE, skips NOTIF branch
    static func inheritanceKeepAliveWitness(signature: Data, witnessScript: Data) -> [Data] {
        [signature, witnessScript]
    }

    // MARK: - Inheritance Heir Claim

    /// Build PSBT for inheritance heir claim.
    /// Witness stack: [signature, 0x00, witnessScript]
    /// sequence = contract.csvBlocks (relative timelock)
    static func buildInheritanceHeirClaimPSBT(
        contract: Contract,
        utxos: [UTXO],
        destinationAddress: String,
        feeRate: Double,
        isTestnet: Bool
    ) throws -> Data {
        guard contract.type == .inheritance else {
            throw SpendError.invalidContract
        }
        guard let csvBlocks = contract.csvBlocks else {
            throw SpendError.invalidContract
        }
        guard let witnessScriptData = Data(hex: contract.script) else {
            throw SpendError.invalidContract
        }
        guard PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet) != nil else {
            throw SpendError.invalidAddress
        }
        guard !utxos.isEmpty else {
            throw SpendError.insufficientFunds
        }

        let totalInput = utxos.reduce(UInt64(0)) { $0 + $1.value }
        let witnessSize = witnessScriptData.count + 72 + 1 + 10
        let fee = CoinSelection.estimateP2WSHFee(
            inputCount: utxos.count,
            outputCount: 1,
            witnessSize: witnessSize,
            feeRate: feeRate
        )

        guard totalInput > fee else {
            throw SpendError.insufficientFunds
        }

        let outputAmount = totalInput - fee
        guard outputAmount >= dustThreshold else {
            throw SpendError.belowDust
        }

        let destScript = PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet)!

        // sequence = csvBlocks masked per BIP68 (16-bit value for relative timelock)
        let maskedCSV = UInt32(csvBlocks) & 0x0000FFFF // BIP68: only 16 LSB used
        let inputs: [PSBTBuilder.TxInput] = utxos.map { utxo in
            let txidInternal = txidToInternalOrder(utxo.txid)
            let spk = Data(hex: utxo.scriptPubKey) ?? PSBTBuilder.p2wshScriptPubKey(scriptHash: Crypto.sha256(witnessScriptData))
            return PSBTBuilder.TxInput(
                txid: txidInternal,
                vout: UInt32(utxo.vout),
                sequence: maskedCSV, // BIP68 masked relative timelock
                witnessUtxo: PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk),
                witnessScript: witnessScriptData
            )
        }

        let outputs = [
            PSBTBuilder.TxOutput(value: outputAmount, scriptPubKey: destScript)
        ]

        return PSBTBuilder.buildPSBT(inputs: inputs, outputs: outputs, locktime: 0)
    }

    /// Build witness stack for inheritance heir claim (or_d fallback path)
    /// Empty owner sig (0) causes OP_IFDUP to not dup, OP_NOTIF enters heir branch
    static func inheritanceHeirClaimWitness(signature: Data, witnessScript: Data) -> [Data] {
        [signature, Data(), witnessScript]
    }

    // MARK: - Pool Spend (Multisig)

    /// Build PSBT for pool multisig spend (first signer).
    /// Other signers import the PSBT and add their signatures.
    static func buildPoolSpendPSBT(
        contract: Contract,
        utxos: [UTXO],
        destinationAddress: String,
        amount: UInt64,
        feeRate: Double,
        isTestnet: Bool
    ) throws -> Data {
        guard contract.type == .pool else {
            throw SpendError.invalidContract
        }
        guard let witnessScriptData = Data(hex: contract.script) else {
            throw SpendError.invalidContract
        }
        guard PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet) != nil else {
            throw SpendError.invalidAddress
        }
        guard !utxos.isEmpty else {
            throw SpendError.insufficientFunds
        }
        guard amount >= dustThreshold else {
            throw SpendError.belowDust
        }

        let totalInput = utxos.reduce(UInt64(0)) { $0 + $1.value }
        let m = contract.multisigM ?? 2
        let witnessSize = witnessScriptData.count + (72 * m) + m + 10 // script + m sigs + OP_0 + overhead
        let fee = CoinSelection.estimateP2WSHFee(
            inputCount: utxos.count,
            outputCount: 2,
            witnessSize: witnessSize,
            feeRate: feeRate
        )

        guard totalInput >= amount + fee else {
            throw SpendError.insufficientFunds
        }

        let destScript = PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet)!

        // sequence 0xFFFFFFFD: RBF enabled (BIP125) for fee-bumping stuck txs
        let inputs: [PSBTBuilder.TxInput] = utxos.map { utxo in
            let txidInternal = txidToInternalOrder(utxo.txid)
            let spk = Data(hex: utxo.scriptPubKey) ?? PSBTBuilder.p2wshScriptPubKey(scriptHash: Crypto.sha256(witnessScriptData))
            return PSBTBuilder.TxInput(
                txid: txidInternal,
                vout: UInt32(utxo.vout),
                sequence: 0xFFFFFFFD, // RBF signal per BIP125
                witnessUtxo: PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk),
                witnessScript: witnessScriptData
            )
        }

        var outputs: [PSBTBuilder.TxOutput] = [
            PSBTBuilder.TxOutput(value: amount, scriptPubKey: destScript)
        ]

        let change = totalInput - amount - fee
        if change >= dustThreshold {
            guard let changeScript = PSBTBuilder.scriptPubKeyFromAddress(contract.address, isTestnet: isTestnet) else {
                throw SpendError.invalidAddress
            }
            outputs.append(PSBTBuilder.TxOutput(value: change, scriptPubKey: changeScript))
        }

        // BIP69: sort outputs lexicographically for privacy
        outputs.sort { (a: PSBTBuilder.TxOutput, b: PSBTBuilder.TxOutput) in a.scriptPubKey.hex < b.scriptPubKey.hex }

        return PSBTBuilder.buildPSBT(inputs: inputs, outputs: outputs, locktime: 0)
    }

    // MARK: - HTLC Claim (Receiver)

    /// Build PSBT for HTLC claim with preimage (receiver).
    /// Witness stack: [signature, preimage, 0x01, witnessScript]
    /// nLockTime = 0, sequence = 0xFFFFFFFF
    static func buildHTLCClaimPSBT(
        contract: Contract,
        preimage: Data,
        utxos: [UTXO],
        destinationAddress: String,
        feeRate: Double,
        isTestnet: Bool
    ) throws -> Data {
        guard contract.type == .htlc else {
            throw SpendError.invalidContract
        }
        guard let witnessScriptData = Data(hex: contract.script) else {
            throw SpendError.invalidContract
        }
        guard preimage.count == 32 else {
            throw SpendError.missingPreimage
        }
        // Verify preimage matches hash lock
        if let hashLockHex = contract.hashLock {
            let computedHash = Crypto.sha256(preimage)
            guard computedHash.hex == hashLockHex else {
                throw SpendError.missingPreimage
            }
        }
        guard PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet) != nil else {
            throw SpendError.invalidAddress
        }
        guard !utxos.isEmpty else {
            throw SpendError.insufficientFunds
        }

        let totalInput = utxos.reduce(UInt64(0)) { $0 + $1.value }
        let witnessSize = witnessScriptData.count + 72 + 32 + 1 + 10 // script + sig + preimage + OP_TRUE + overhead
        let fee = CoinSelection.estimateP2WSHFee(
            inputCount: utxos.count,
            outputCount: 1,
            witnessSize: witnessSize,
            feeRate: feeRate
        )

        guard totalInput > fee else {
            throw SpendError.insufficientFunds
        }

        let outputAmount = totalInput - fee
        guard outputAmount >= dustThreshold else {
            throw SpendError.belowDust
        }

        let destScript = PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet)!

        // sequence 0xFFFFFFFD: RBF enabled for fee-bumping (BIP125)
        let inputs: [PSBTBuilder.TxInput] = utxos.map { utxo in
            let txidInternal = txidToInternalOrder(utxo.txid)
            let spk = Data(hex: utxo.scriptPubKey) ?? PSBTBuilder.p2wshScriptPubKey(scriptHash: Crypto.sha256(witnessScriptData))
            return PSBTBuilder.TxInput(
                txid: txidInternal,
                vout: UInt32(utxo.vout),
                sequence: 0xFFFFFFFD, // RBF signal per BIP125
                witnessUtxo: PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk),
                witnessScript: witnessScriptData
            )
        }

        let outputs = [
            PSBTBuilder.TxOutput(value: outputAmount, scriptPubKey: destScript)
        ]

        return PSBTBuilder.buildPSBT(inputs: inputs, outputs: outputs, locktime: 0)
    }

    /// Build witness stack for HTLC claim (IF branch)
    static func htlcClaimWitness(signature: Data, preimage: Data, witnessScript: Data) -> [Data] {
        HTLCBuilder.claimWitness(signature: signature, preimage: preimage, witnessScript: witnessScript)
    }

    // MARK: - HTLC Refund (Sender)

    /// Build PSBT for HTLC refund after timeout (sender).
    /// Witness stack: [signature, 0x00, witnessScript]
    /// nLockTime = contract.timeoutBlocks, sequence = 0xFFFFFFFE
    static func buildHTLCRefundPSBT(
        contract: Contract,
        utxos: [UTXO],
        destinationAddress: String,
        feeRate: Double,
        isTestnet: Bool
    ) throws -> Data {
        guard contract.type == .htlc else {
            throw SpendError.invalidContract
        }
        guard let timeoutBlocks = contract.timeoutBlocks else {
            throw SpendError.invalidContract
        }
        guard let witnessScriptData = Data(hex: contract.script) else {
            throw SpendError.invalidContract
        }
        guard PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet) != nil else {
            throw SpendError.invalidAddress
        }
        guard !utxos.isEmpty else {
            throw SpendError.insufficientFunds
        }

        let totalInput = utxos.reduce(UInt64(0)) { $0 + $1.value }
        let witnessSize = witnessScriptData.count + 72 + 1 + 10
        let fee = CoinSelection.estimateP2WSHFee(
            inputCount: utxos.count,
            outputCount: 1,
            witnessSize: witnessSize,
            feeRate: feeRate
        )

        guard totalInput > fee else {
            throw SpendError.insufficientFunds
        }

        let outputAmount = totalInput - fee
        guard outputAmount >= dustThreshold else {
            throw SpendError.belowDust
        }

        let destScript = PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet)!

        // sequence 0xFFFFFFFE to enable nLockTime
        let inputs: [PSBTBuilder.TxInput] = utxos.map { utxo in
            let txidInternal = txidToInternalOrder(utxo.txid)
            let spk = Data(hex: utxo.scriptPubKey) ?? PSBTBuilder.p2wshScriptPubKey(scriptHash: Crypto.sha256(witnessScriptData))
            return PSBTBuilder.TxInput(
                txid: txidInternal,
                vout: UInt32(utxo.vout),
                sequence: 0xFFFFFFFE,
                witnessUtxo: PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk),
                witnessScript: witnessScriptData
            )
        }

        let outputs = [
            PSBTBuilder.TxOutput(value: outputAmount, scriptPubKey: destScript)
        ]

        return PSBTBuilder.buildPSBT(
            inputs: inputs,
            outputs: outputs,
            locktime: UInt32(timeoutBlocks)
        )
    }

    /// Build witness stack for HTLC refund (ELSE branch)
    static func htlcRefundWitness(signature: Data, witnessScript: Data) -> [Data] {
        HTLCBuilder.refundWitness(signature: signature, witnessScript: witnessScript)
    }

    // MARK: - Channel Cooperative Close

    /// Build PSBT for cooperative channel close (2-of-2 multisig).
    /// Witness stack: [OP_0, sig_sender, sig_receiver, 0x01, witnessScript]
    static func buildChannelCooperativeClosePSBT(
        contract: Contract,
        utxos: [UTXO],
        senderAmount: UInt64,
        receiverAmount: UInt64,
        senderAddress: String,
        receiverAddress: String,
        feeRate: Double,
        isTestnet: Bool
    ) throws -> Data {
        guard contract.type == .channel else {
            throw SpendError.invalidContract
        }
        guard let witnessScriptData = Data(hex: contract.script) else {
            throw SpendError.invalidContract
        }
        guard PSBTBuilder.scriptPubKeyFromAddress(senderAddress, isTestnet: isTestnet) != nil else {
            throw SpendError.invalidAddress
        }
        guard PSBTBuilder.scriptPubKeyFromAddress(receiverAddress, isTestnet: isTestnet) != nil else {
            throw SpendError.invalidAddress
        }
        guard !utxos.isEmpty else {
            throw SpendError.insufficientFunds
        }

        let totalInput = utxos.reduce(UInt64(0)) { $0 + $1.value }
        let witnessSize = witnessScriptData.count + (72 * 2) + 1 + 1 + 10 // 2 sigs + OP_0 + OP_TRUE + overhead
        let outputCount = (senderAmount >= dustThreshold ? 1 : 0) + (receiverAmount >= dustThreshold ? 1 : 0)
        let fee = CoinSelection.estimateP2WSHFee(
            inputCount: utxos.count,
            outputCount: max(outputCount, 1),
            witnessSize: witnessSize,
            feeRate: feeRate
        )

        guard totalInput >= senderAmount + receiverAmount + fee else {
            throw SpendError.insufficientFunds
        }

        let senderScript = PSBTBuilder.scriptPubKeyFromAddress(senderAddress, isTestnet: isTestnet)!
        let receiverScript = PSBTBuilder.scriptPubKeyFromAddress(receiverAddress, isTestnet: isTestnet)!

        // sequence 0xFFFFFFFD: RBF enabled (BIP125)
        let inputs: [PSBTBuilder.TxInput] = utxos.map { utxo in
            let txidInternal = txidToInternalOrder(utxo.txid)
            let spk = Data(hex: utxo.scriptPubKey) ?? PSBTBuilder.p2wshScriptPubKey(scriptHash: Crypto.sha256(witnessScriptData))
            return PSBTBuilder.TxInput(
                txid: txidInternal,
                vout: UInt32(utxo.vout),
                sequence: 0xFFFFFFFD, // RBF signal per BIP125
                witnessUtxo: PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk),
                witnessScript: witnessScriptData
            )
        }

        var outputs: [PSBTBuilder.TxOutput] = []
        if senderAmount >= dustThreshold {
            outputs.append(PSBTBuilder.TxOutput(value: senderAmount, scriptPubKey: senderScript))
        }
        if receiverAmount >= dustThreshold {
            outputs.append(PSBTBuilder.TxOutput(value: receiverAmount, scriptPubKey: receiverScript))
        }

        // BIP69: sort outputs lexicographically for privacy
        outputs.sort { (a: PSBTBuilder.TxOutput, b: PSBTBuilder.TxOutput) in a.scriptPubKey.hex < b.scriptPubKey.hex }

        return PSBTBuilder.buildPSBT(inputs: inputs, outputs: outputs, locktime: 0)
    }

    /// Build witness stack for cooperative close (IF branch, 2-of-2 multisig)
    static func channelCooperativeCloseWitness(
        senderSig: Data,
        receiverSig: Data,
        witnessScript: Data
    ) -> [Data] {
        PaymentChannelBuilder.cooperativeCloseWitness(
            senderSig: senderSig,
            receiverSig: receiverSig,
            witnessScript: witnessScript
        )
    }

    // MARK: - Channel Unilateral Refund

    /// Build PSBT for unilateral channel refund after timeout (sender only).
    /// Witness stack: [signature, 0x00, witnessScript]
    /// nLockTime = contract.timeoutBlocks, sequence = 0xFFFFFFFE
    static func buildChannelRefundPSBT(
        contract: Contract,
        utxos: [UTXO],
        destinationAddress: String,
        feeRate: Double,
        isTestnet: Bool
    ) throws -> Data {
        guard contract.type == .channel else {
            throw SpendError.invalidContract
        }
        guard let timeoutBlocks = contract.timeoutBlocks else {
            throw SpendError.invalidContract
        }
        guard let witnessScriptData = Data(hex: contract.script) else {
            throw SpendError.invalidContract
        }
        guard PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet) != nil else {
            throw SpendError.invalidAddress
        }
        guard !utxos.isEmpty else {
            throw SpendError.insufficientFunds
        }

        let totalInput = utxos.reduce(UInt64(0)) { $0 + $1.value }
        let witnessSize = witnessScriptData.count + 72 + 1 + 10
        let fee = CoinSelection.estimateP2WSHFee(
            inputCount: utxos.count,
            outputCount: 1,
            witnessSize: witnessSize,
            feeRate: feeRate
        )

        guard totalInput > fee else {
            throw SpendError.insufficientFunds
        }

        let outputAmount = totalInput - fee
        guard outputAmount >= dustThreshold else {
            throw SpendError.belowDust
        }

        let destScript = PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet)!

        let inputs: [PSBTBuilder.TxInput] = utxos.map { utxo in
            let txidInternal = txidToInternalOrder(utxo.txid)
            let spk = Data(hex: utxo.scriptPubKey) ?? PSBTBuilder.p2wshScriptPubKey(scriptHash: Crypto.sha256(witnessScriptData))
            return PSBTBuilder.TxInput(
                txid: txidInternal,
                vout: UInt32(utxo.vout),
                sequence: 0xFFFFFFFE,
                witnessUtxo: PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk),
                witnessScript: witnessScriptData
            )
        }

        let outputs = [
            PSBTBuilder.TxOutput(value: outputAmount, scriptPubKey: destScript)
        ]

        return PSBTBuilder.buildPSBT(
            inputs: inputs,
            outputs: outputs,
            locktime: UInt32(timeoutBlocks)
        )
    }

    /// Build witness stack for channel unilateral refund (ELSE branch)
    static func channelRefundWitness(signature: Data, witnessScript: Data) -> [Data] {
        PaymentChannelBuilder.refundWitness(senderSig: signature, witnessScript: witnessScript)
    }

    // MARK: - Taproot Key-Path Spend

    /// Build PSBT for a Taproot key-path spend (Schnorr signature, no scripts).
    /// Witness: [64-byte Schnorr signature]
    /// This is the most efficient spend — looks like a normal single-sig on chain.
    static func buildTaprootKeyPathSpendPSBT(
        contract: Contract,
        utxos: [UTXO],
        destinationAddress: String,
        feeRate: Double,
        isTestnet: Bool
    ) throws -> Data {
        guard PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet) != nil else {
            throw SpendError.invalidAddress
        }
        guard !utxos.isEmpty else {
            throw SpendError.insufficientFunds
        }

        let totalInput = utxos.reduce(UInt64(0)) { $0 + $1.value }
        // P2TR key-path: 57.5 vbytes per input (1 Schnorr sig in witness)
        let inputVsize = 57
        let outputVsize = 43 // P2TR output
        let overheadVsize = 11
        let vsize = overheadVsize + (inputVsize * utxos.count) + outputVsize
        let fee = UInt64(ceil(Double(vsize) * feeRate))

        guard totalInput > fee else {
            throw SpendError.insufficientFunds
        }

        let outputAmount = totalInput - fee
        guard outputAmount >= dustThreshold else {
            throw SpendError.belowDust
        }

        let destScript = PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet)!

        // Extract x-only internal key from contract
        let xOnlyKey: Data?
        if let ik = contract.taprootInternalKey, let ikData = Data(hex: ik), ikData.count == 32 {
            xOnlyKey = ikData
        } else {
            xOnlyKey = nil
        }

        let spk = Data(hex: contract.scriptPubKey ?? "") ?? PSBTBuilder.scriptPubKeyFromAddress(contract.address, isTestnet: isTestnet) ?? Data()

        let inputs: [PSBTBuilder.TxInput] = utxos.map { utxo in
            let txidInternal = txidToInternalOrder(utxo.txid)
            var input = PSBTBuilder.TxInput(
                txid: txidInternal,
                vout: UInt32(utxo.vout),
                sequence: 0xFFFFFFFD, // RBF enabled
                witnessUtxo: PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk)
            )
            input.tapInternalKey = xOnlyKey
            return input
        }

        let outputs = [
            PSBTBuilder.TxOutput(value: outputAmount, scriptPubKey: destScript)
        ]

        return PSBTBuilder.buildPSBT(inputs: inputs, outputs: outputs, locktime: 0)
    }

    /// Witness for Taproot key-path spend: just the Schnorr signature
    static func taprootKeyPathWitness(signature: Data) -> [Data] {
        TaprootBuilder.keyPathWitness(signature: signature)
    }

    // MARK: - Taproot Script-Path Spend

    /// Build PSBT for a Taproot script-path spend.
    /// Witness: [...stack, script, controlBlock]
    static func buildTaprootScriptPathSpendPSBT(
        contract: Contract,
        utxos: [UTXO],
        destinationAddress: String,
        feeRate: Double,
        isTestnet: Bool,
        locktime: UInt32 = 0,
        sequence: UInt32 = 0xFFFFFFFE
    ) throws -> Data {
        guard PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet) != nil else {
            throw SpendError.invalidAddress
        }
        guard !utxos.isEmpty else {
            throw SpendError.insufficientFunds
        }
        guard let witnessScriptData = Data(hex: contract.script) else {
            throw SpendError.invalidContract
        }

        let totalInput = utxos.reduce(UInt64(0)) { $0 + $1.value }
        // Script-path: ~100-150 vbytes per input depending on script + control block
        let controlBlockSize = 33 + (contract.taprootScripts?.count ?? 1 > 1 ? 32 : 0)
        let witnessSize = witnessScriptData.count + 64 + controlBlockSize + 10
        let inputVsize = 41 + (witnessSize + 3) / 4
        let outputVsize = 43
        let overheadVsize = 11
        let vsize = overheadVsize + (inputVsize * utxos.count) + outputVsize
        let fee = UInt64(ceil(Double(vsize) * feeRate))

        guard totalInput > fee else {
            throw SpendError.insufficientFunds
        }

        let outputAmount = totalInput - fee
        guard outputAmount >= dustThreshold else {
            throw SpendError.belowDust
        }

        let destScript = PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet)!

        let xOnlyKey: Data?
        if let ik = contract.taprootInternalKey, let ikData = Data(hex: ik), ikData.count == 32 {
            xOnlyKey = ikData
        } else {
            xOnlyKey = nil
        }

        let merkleRoot: Data?
        if let mr = contract.taprootMerkleRoot, let mrData = Data(hex: mr), mrData.count == 32 {
            merkleRoot = mrData
        } else {
            merkleRoot = nil
        }

        let spk = Data(hex: contract.scriptPubKey ?? "") ?? PSBTBuilder.scriptPubKeyFromAddress(contract.address, isTestnet: isTestnet) ?? Data()

        let inputs: [PSBTBuilder.TxInput] = utxos.map { utxo in
            let txidInternal = txidToInternalOrder(utxo.txid)
            var input = PSBTBuilder.TxInput(
                txid: txidInternal,
                vout: UInt32(utxo.vout),
                sequence: sequence,
                witnessUtxo: PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk),
                witnessScript: witnessScriptData
            )
            input.tapInternalKey = xOnlyKey
            input.tapMerkleRoot = merkleRoot
            return input
        }

        let outputs = [
            PSBTBuilder.TxOutput(value: outputAmount, scriptPubKey: destScript)
        ]

        return PSBTBuilder.buildPSBT(inputs: inputs, outputs: outputs, locktime: locktime)
    }

    /// Witness for Taproot script-path spend
    static func taprootScriptPathWitness(signature: Data, script: Data, controlBlock: Data) -> [Data] {
        TaprootBuilder.scriptPathWitness(stack: [signature], script: script, controlBlock: controlBlock)
    }

    // MARK: - Taproot Fee Estimation

    /// Estimate fee for a P2TR key-path spend (most efficient)
    static func estimateTaprootKeyPathFee(inputCount: Int, outputCount: Int, feeRate: Double) -> UInt64 {
        let vsize = 11 + (57 * inputCount) + (43 * outputCount)
        return UInt64(ceil(Double(vsize) * feeRate))
    }

    // MARK: - PSBT Finalization

    /// Add witness data to a signed PSBT, producing a finalized PSBT.
    /// witnessStacks contains one witness stack per input.
    static func finalizePSBT(
        psbtData: Data,
        witnessStacks: [[Data]]
    ) -> Data? {
        // Parse the PSBT to get the unsigned tx
        guard let parsed = PSBTBuilder.parsePSBT(psbtData),
              let unsignedTx = parsed.unsignedTx else {
            return nil
        }

        // Build the signed transaction with witness data
        var tx = Data()

        // Version (first 4 bytes of unsigned tx)
        tx.append(Data(unsignedTx[0..<4]))

        // Segwit marker and flag
        tx.append(0x00) // marker
        tx.append(0x01) // flag

        // Parse inputs/outputs from unsigned tx
        var offset = 4
        guard let (inputCount, inputCountBytes) = VarInt.decode(unsignedTx, offset: offset) else {
            return nil
        }
        offset += inputCountBytes

        // Copy input count
        tx.append(VarInt.encode(inputCount))

        // Copy inputs (with empty scriptSig)
        for _ in 0..<Int(inputCount) {
            // txid (32) + vout (4)
            guard offset + 36 <= unsignedTx.count else { return nil }
            tx.append(Data(unsignedTx[offset..<(offset + 36)]))
            offset += 36

            // scriptSig length
            guard let (scriptLen, scriptLenBytes) = VarInt.decode(unsignedTx, offset: offset) else {
                return nil
            }
            offset += scriptLenBytes + Int(scriptLen)

            // Empty scriptSig for segwit
            tx.append(0x00)

            // sequence (4 bytes)
            guard offset + 4 <= unsignedTx.count else { return nil }
            tx.append(Data(unsignedTx[offset..<(offset + 4)]))
            offset += 4
        }

        // Parse and copy outputs
        guard let (outputCount, outputCountBytes) = VarInt.decode(unsignedTx, offset: offset) else {
            return nil
        }
        offset += outputCountBytes
        tx.append(VarInt.encode(outputCount))

        for _ in 0..<Int(outputCount) {
            // value (8 bytes)
            guard offset + 8 <= unsignedTx.count else { return nil }
            tx.append(Data(unsignedTx[offset..<(offset + 8)]))
            offset += 8

            // scriptPubKey
            guard let (spkLen, spkLenBytes) = VarInt.decode(unsignedTx, offset: offset) else {
                return nil
            }
            tx.append(VarInt.encode(spkLen))
            offset += spkLenBytes
            guard offset + Int(spkLen) <= unsignedTx.count else { return nil }
            tx.append(Data(unsignedTx[offset..<(offset + Int(spkLen))]))
            offset += Int(spkLen)
        }

        // Witness data for each input
        for i in 0..<Int(inputCount) {
            if i < witnessStacks.count {
                let stack = witnessStacks[i]
                tx.append(VarInt.encode(UInt64(stack.count)))
                for item in stack {
                    tx.append(VarInt.encode(UInt64(item.count)))
                    tx.append(item)
                }
            } else {
                // No witness for this input
                tx.append(0x00)
            }
        }

        // Locktime (last 4 bytes of unsigned tx)
        let locktimeOffset = unsignedTx.count - 4
        tx.append(Data(unsignedTx[locktimeOffset..<unsignedTx.count]))

        return tx
    }

    /// Extract raw transaction hex from a finalized transaction
    static func extractTransactionHex(_ txData: Data) -> String {
        txData.hex
    }

    // MARK: - PSBT Export

    /// Export PSBT data as base64 string for external signing tools (Sparrow, Bitcoin Core, etc.)
    static func exportPSBTBase64(_ psbtData: Data) -> String {
        psbtData.base64EncodedString()
    }

    // MARK: - Transaction Validation

    /// Validate a raw transaction before broadcast.
    /// Returns (true, "OK") if valid, or (false, reason) if invalid.
    static func validateTransaction(_ txData: Data) -> (valid: Bool, reason: String) {
        // Minimum valid transaction size
        guard txData.count > 60 else {
            return (false, "Transaction too small (\(txData.count) bytes, minimum 60)")
        }

        // Maximum standard transaction size
        guard txData.count < 400_000 else {
            return (false, "Transaction too large (\(txData.count) bytes, maximum 400000)")
        }

        // Check version (first 4 bytes, little-endian)
        guard txData.count >= 4 else {
            return (false, "Truncated transaction")
        }
        let version = UInt32(txData[0]) | (UInt32(txData[1]) << 8) | (UInt32(txData[2]) << 16) | (UInt32(txData[3]) << 24)
        guard version == 1 || version == 2 else {
            return (false, "Invalid transaction version (\(version)), expected 1 or 2")
        }

        // Check for segwit marker (0x00 0x01 after version)
        guard txData.count >= 6 else {
            return (false, "Truncated transaction")
        }
        guard txData[4] == 0x00 && txData[5] == 0x01 else {
            return (false, "Missing segwit marker (expected 0x00 0x01 after version)")
        }

        // Check at least 1 input
        guard txData.count >= 7 else {
            return (false, "Truncated transaction")
        }
        guard let (inputCount, _) = VarInt.decode(txData, offset: 6) else {
            return (false, "Unable to decode input count")
        }
        guard inputCount >= 1 else {
            return (false, "Transaction must have at least 1 input")
        }

        // Skip inputs to find output count
        var offset = 6
        guard let (inCount, inCountBytes) = VarInt.decode(txData, offset: offset) else {
            return (false, "Unable to decode input count")
        }
        offset += inCountBytes

        for _ in 0..<Int(inCount) {
            // txid(32) + vout(4) + scriptSig(varint+data) + sequence(4)
            guard offset + 36 <= txData.count else {
                return (false, "Transaction truncated at inputs")
            }
            offset += 36 // txid + vout
            guard let (scriptLen, scriptLenBytes) = VarInt.decode(txData, offset: offset) else {
                return (false, "Unable to decode scriptSig")
            }
            offset += scriptLenBytes + Int(scriptLen) + 4 // scriptSig + sequence
            guard offset <= txData.count else {
                return (false, "Transaction truncated at inputs")
            }
        }

        // Check at least 1 output
        guard offset < txData.count else {
            return (false, "Transaction truncated before outputs")
        }
        guard let (outputCount, _) = VarInt.decode(txData, offset: offset) else {
            return (false, "Unable to decode output count")
        }
        guard outputCount >= 1 else {
            return (false, "Transaction must have at least 1 output")
        }

        return (true, "OK")
    }

    // MARK: - Broadcast

    /// Broadcast a raw transaction, checking demo mode, mainnet guard, and validation first
    static func broadcast(txHex: String) async throws -> String {
        if DemoMode.shared.isActive {
            throw SpendError.demoModeBlocked
        }

        // Safety guard: block mainnet broadcasts during testing phase
        if NetworkConfig.shared.isTestnet == false {
            throw SpendError.mainnetDisabled
        }

        // Validate the transaction before broadcasting
        guard let txData = Data(hex: txHex) else {
            throw SpendError.invalidTransaction("Unable to decode transaction hex")
        }

        let validation = validateTransaction(txData)
        guard validation.valid else {
            throw SpendError.invalidTransaction(validation.reason)
        }

        return try await MempoolAPI.shared.broadcastTransaction(hex: txHex)
    }

    // MARK: - Fee estimation

    /// Estimate vsize for a P2WSH input (varies by witness script size)
    static func estimateP2WSHVsize(witnessScriptSize: Int) -> Int {
        let witnessSize = witnessScriptSize + 72 + 10
        return 41 + (witnessSize + 3) / 4
    }

    /// Estimate total fee for a contract spend
    static func estimateFee(
        contract: Contract,
        utxoCount: Int,
        outputCount: Int,
        feeRate: Double
    ) -> UInt64 {
        let witnessScriptSize = (contract.script.count) / 2 // hex to bytes
        let witnessSize = witnessScriptSize + 72 + 10
        return CoinSelection.estimateP2WSHFee(
            inputCount: utxoCount,
            outputCount: outputCount,
            witnessSize: witnessSize,
            feeRate: feeRate
        )
    }

    // MARK: - Private helpers

    private static func txidToInternalOrder(_ txid: String) -> Data {
        guard let data = Data(hex: txid) else { return Data(count: 32) }
        return Data(data.reversed())
    }

    // MARK: - Errors

    enum SpendError: LocalizedError {
        case demoModeBlocked
        case insufficientFunds
        case invalidContract
        case invalidAddress
        case belowDust
        case timelockNotReached
        case missingPreimage
        case signingFailed
        case mainnetDisabled
        case invalidTransaction(String)

        var errorDescription: String? {
            switch self {
            case .demoModeBlocked: return "Broadcast blocked in demo mode"
            case .insufficientFunds: return "Insufficient funds"
            case .invalidContract: return "Invalid contract"
            case .invalidAddress: return "Invalid destination address"
            case .belowDust: return "Amount below dust threshold (546 sats)"
            case .timelockNotReached: return "Timelock not yet reached"
            case .missingPreimage: return "Missing or invalid preimage"
            case .signingFailed: return "Signing failed"
            case .mainnetDisabled: return "Mainnet broadcast disabled — use testnet for testing"
            case .invalidTransaction(let reason): return "Invalid transaction: \(reason)"
            }
        }
    }
}
