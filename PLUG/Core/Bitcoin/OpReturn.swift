import Foundation

// MARK: - OP_RETURN Data Embedding
// Embeds arbitrary data (up to 80 bytes) in the blockchain via OP_RETURN outputs.
// Use cases: text memos, proof-of-existence timestamps, protocol markers.

struct OpReturnBuilder {

    /// Maximum data payload for OP_RETURN (consensus limit)
    static let maxDataSize = 80

    // MARK: - Script construction

    /// Build an OP_RETURN output script
    ///
    /// Format: OP_RETURN <push_data>
    /// The output is provably unspendable and won't pollute the UTXO set.
    ///
    /// - Parameter data: arbitrary data payload (max 80 bytes)
    /// - Returns: serialized scriptPubKey, or nil if data exceeds limit
    static func opReturnScript(data: Data) -> Data? {
        guard data.count <= maxDataSize else { return nil }

        var script = Data()
        script.append(OpCode.op_return.rawValue)

        // Push the data with appropriate length prefix
        if data.count <= 75 {
            script.append(UInt8(data.count))
            script.append(data)
        } else {
            script.append(OpCode.op_pushdata1.rawValue)
            script.append(UInt8(data.count))
            script.append(data)
        }

        return script
    }

    /// Build an OP_RETURN script with a UTF-8 text memo
    ///
    /// - Parameter text: text message to embed
    /// - Returns: serialized scriptPubKey, or nil if text exceeds limit
    static func textMemo(_ text: String) -> Data? {
        let payload = Data(text.utf8)
        return opReturnScript(data: payload)
    }

    /// Build an OP_RETURN script with a SHA256 proof-of-existence hash
    ///
    /// Hashes the input data with SHA256 and embeds the 32-byte digest.
    /// This proves the data existed at the time the transaction was mined.
    ///
    /// - Parameter data: data to prove existence of
    /// - Returns: serialized scriptPubKey containing the SHA256 digest
    static func sha256Proof(_ data: Data) -> Data? {
        let hash = Crypto.sha256(data)
        return opReturnScript(data: hash)
    }

    // MARK: - Transaction construction

    /// Build a PSBT with an OP_RETURN output and an optional payment output
    ///
    /// - Parameters:
    ///   - opReturnData: data to embed (must already be a valid OP_RETURN scriptPubKey)
    ///   - paymentAddress: optional destination address for a payment output
    ///   - paymentAmount: optional payment amount in satoshis
    ///   - utxos: available UTXOs for funding
    ///   - feeRate: target fee rate in sat/vB
    ///   - changeAddress: address for change output
    ///   - isTestnet: network flag
    /// - Returns: serialized PSBT data, or nil on failure
    static func buildOpReturnTx(
        opReturnData: Data,
        paymentAddress: String?,
        paymentAmount: UInt64?,
        utxos: [UTXO],
        feeRate: Double,
        changeAddress: String,
        isTestnet: Bool
    ) -> Data? {
        // The OP_RETURN output carries 0 satoshis
        var outputs: [PSBTBuilder.TxOutput] = [
            PSBTBuilder.TxOutput(value: 0, scriptPubKey: opReturnData)
        ]

        var targetAmount: UInt64 = 0

        // Add optional payment output
        if let addr = paymentAddress, let amount = paymentAmount, amount > 0 {
            guard let payScript = PSBTBuilder.scriptPubKeyFromAddress(addr, isTestnet: isTestnet) else {
                return nil
            }
            outputs.append(PSBTBuilder.TxOutput(value: amount, scriptPubKey: payScript))
            targetAmount = amount
        }

        // Coin selection (target is just the payment amount; OP_RETURN is 0 sats)
        // We need at least enough for the fee even if targetAmount is 0
        let minTarget = targetAmount > 0 ? targetAmount : CoinSelection.dustThreshold
        guard let selection = CoinSelection.select(
            from: utxos,
            target: minTarget,
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

        // Recalculate fee with actual output count
        let outputCount = outputs.count + (selection.hasChange ? 1 : 0)
        let fee = CoinSelection.estimateFee(
            inputCount: inputs.count,
            outputCount: outputCount,
            feeRate: feeRate
        )

        guard selection.totalInput >= targetAmount + fee else { return nil }

        // Add change output if needed
        let change = selection.totalInput - targetAmount - fee
        if change >= CoinSelection.dustThreshold {
            guard let changeScript = PSBTBuilder.scriptPubKeyFromAddress(changeAddress, isTestnet: isTestnet) else {
                return nil
            }
            outputs.append(PSBTBuilder.TxOutput(value: change, scriptPubKey: changeScript))
        }

        return PSBTBuilder.buildPSBT(inputs: inputs, outputs: outputs)
    }

    // MARK: - Private helpers

    private static func txidToInternalOrder(_ txid: String) -> Data {
        guard let data = Data(hex: txid) else { return Data(count: 32) }
        return Data(data.reversed())
    }
}
