import Foundation

// MARK: - Unidirectional Payment Channel
// 2-of-2 multisig for cooperative close, CLTV timeout for unilateral refund.
// Script: OP_IF OP_2 <sender_pk> <receiver_pk> OP_2 OP_CHECKMULTISIG
//         OP_ELSE <timeout> OP_CHECKLOCKTIMEVERIFY OP_DROP <sender_pk> OP_CHECKSIG OP_ENDIF

struct PaymentChannelBuilder {

    // MARK: - Script construction

    /// Build the payment channel witness script
    ///
    /// Cooperative path (OP_IF): 2-of-2 multisig between sender and receiver
    /// Refund path (OP_ELSE): sender can reclaim after CLTV timeout
    ///
    /// - Parameters:
    ///   - senderPubkey: 33-byte compressed pubkey of the channel funder
    ///   - receiverPubkey: 33-byte compressed pubkey of the channel recipient
    ///   - timeoutBlocks: absolute block height for CLTV refund
    /// - Returns: ScriptBuilder with the assembled channel script
    /// Payment Channel: 2-of-2 cooperative close or CLTV refund
    /// Miniscript: or_d(multi(2,@0,@1),and_v(v:pk(@0),after(N)))
    /// Script: <2> <SENDER> <RECEIVER> <2> OP_CHECKMULTISIG OP_IFDUP OP_NOTIF <SENDER> OP_CHECKSIGVERIFY <N> OP_CLTV OP_ENDIF
    /// This format matches the Ledger's miniscript compiler output exactly.
    static func channelScript(
        senderPubkey: Data,
        receiverPubkey: Data,
        timeoutBlocks: Int64
    ) -> ScriptBuilder {
        ScriptBuilder()
            .pushNumber(2)
            .pushData(senderPubkey)
            .pushData(receiverPubkey)
            .pushNumber(2)
            .addOp(.op_checkmultisig)
            .addOp(.op_ifdup)
            .addOp(.op_notif)
                .pushData(senderPubkey)
                .addOp(.op_checksigverify)
                .pushNumber(timeoutBlocks)
                .addOp(.op_checklocktimeverify)
            .addOp(.op_endif)
    }

    // MARK: - Witness stack helpers

    /// Build the witness stack for a cooperative close (2-of-2 multisig path)
    ///
    /// Witness: <OP_0> <sig_sender> <sig_receiver> <OP_TRUE> <witness_script>
    /// Note: OP_0 is required due to the OP_CHECKMULTISIG off-by-one bug
    ///
    /// - Parameters:
    ///   - senderSig: DER-encoded signature from the sender
    ///   - receiverSig: DER-encoded signature from the receiver
    ///   - witnessScript: the serialized channel script
    /// - Returns: witness stack items
    /// Build witness stack for cooperative close (or_d primary: multi path)
    /// multi(2,@0,@1) satisfies → TRUE → OP_IFDUP dups → OP_NOTIF skips
    /// Witness: <empty> <senderSig> <receiverSig> <witnessScript>
    static func cooperativeCloseWitness(
        senderSig: Data,
        receiverSig: Data,
        witnessScript: Data
    ) -> [Data] {
        [Data(), senderSig, receiverSig, witnessScript]
    }

    /// Build witness stack for unilateral refund (or_d fallback: pk + after)
    /// multi fails → 0 → OP_IFDUP no dup → OP_NOTIF enters → sender sig + CLTV
    /// Witness: <senderSig> <empty> <witnessScript>
    static func refundWitness(
        senderSig: Data,
        witnessScript: Data
    ) -> [Data] {
        [senderSig, Data(), witnessScript]
    }

    // MARK: - PSBT construction

    /// Build an unsigned PSBT to open (fund) a payment channel
    ///
    /// - Parameters:
    ///   - senderPubkey: sender's compressed pubkey
    ///   - receiverPubkey: receiver's compressed pubkey
    ///   - timeoutBlocks: CLTV timeout block height
    ///   - amount: satoshis to lock in the channel
    ///   - utxos: available UTXOs for funding
    ///   - feeRate: target fee rate in sat/vB
    ///   - changeAddress: address for change output
    ///   - isTestnet: network flag
    /// - Returns: serialized PSBT data, or nil on failure
    static func buildFundingPSBT(
        senderPubkey: Data,
        receiverPubkey: Data,
        timeoutBlocks: Int64,
        amount: UInt64,
        utxos: [UTXO],
        feeRate: Double,
        changeAddress: String,
        isTestnet: Bool
    ) -> Data? {
        let script = channelScript(
            senderPubkey: senderPubkey,
            receiverPubkey: receiverPubkey,
            timeoutBlocks: timeoutBlocks
        )

        let scriptHash = script.witnessScriptHash
        let p2wshScript = PSBTBuilder.p2wshScriptPubKey(scriptHash: scriptHash)

        // Coin selection
        guard let selection = CoinSelection.select(
            from: utxos,
            target: amount,
            feeRate: feeRate
        ) else { return nil }

        // Build inputs
        let inputs: [PSBTBuilder.TxInput] = selection.selectedUTXOs.map { utxo in
            let spk = Data(hex: utxo.scriptPubKey) ?? Data()
            return PSBTBuilder.TxInput(
                txid: txidToInternalOrder(utxo.txid),
                vout: UInt32(utxo.vout),
                sequence: 0xFFFFFFFE,
                witnessUtxo: PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk)
            )
        }

        // Build outputs
        var outputs: [PSBTBuilder.TxOutput] = [
            PSBTBuilder.TxOutput(value: amount, scriptPubKey: p2wshScript)
        ]

        if selection.hasChange {
            guard let changeScript = PSBTBuilder.scriptPubKeyFromAddress(changeAddress, isTestnet: isTestnet) else {
                return nil
            }
            outputs.append(PSBTBuilder.TxOutput(value: selection.change, scriptPubKey: changeScript))
        }

        return PSBTBuilder.buildPSBT(inputs: inputs, outputs: outputs)
    }

    // MARK: - Private helpers

    private static func txidToInternalOrder(_ txid: String) -> Data {
        guard let data = Data(hex: txid) else { return Data(count: 32) }
        return Data(data.reversed())
    }
}
