import Foundation

// MARK: - Batch Sending (Multi-Recipient Transactions)
// Build a single transaction paying multiple recipients at once.
// Saves fees compared to individual transactions.
// Implements BIP69 lexicographic output sorting for privacy.

struct BatchSend {

    // MARK: - Recipient model

    struct Recipient {
        let address: String
        let amount: UInt64
    }

    // MARK: - Batch PSBT construction

    /// Build a PSBT paying multiple recipients in a single transaction
    ///
    /// Uses coin selection for the total of all outputs plus fee.
    /// Outputs are sorted per BIP69 for privacy (lexicographic by scriptPubKey, then value).
    ///
    /// - Parameters:
    ///   - recipients: array of (address, amount) pairs
    ///   - utxos: available UTXOs for funding
    ///   - feeRate: target fee rate in sat/vB
    ///   - changeAddress: address for change output
    ///   - isTestnet: network flag
    /// - Returns: serialized PSBT data, or nil on failure
    static func buildBatchPSBT(
        recipients: [Recipient],
        utxos: [UTXO],
        feeRate: Double,
        changeAddress: String,
        isTestnet: Bool
    ) -> Data? {
        guard !recipients.isEmpty else { return nil }

        // Validate all recipient addresses and compute total
        var paymentOutputs: [PSBTBuilder.TxOutput] = []
        var totalAmount: UInt64 = 0

        for recipient in recipients {
            guard recipient.amount > 0 else { return nil }
            guard let scriptPubKey = PSBTBuilder.scriptPubKeyFromAddress(recipient.address, isTestnet: isTestnet) else {
                return nil
            }
            paymentOutputs.append(PSBTBuilder.TxOutput(value: recipient.amount, scriptPubKey: scriptPubKey))
            totalAmount += recipient.amount
        }

        // Coin selection targeting the sum of all recipient amounts
        guard let selection = CoinSelection.select(
            from: utxos,
            target: totalAmount,
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

        // Recalculate fee with actual input/output counts
        let outputCount = paymentOutputs.count + (selection.hasChange ? 1 : 0)
        let fee = CoinSelection.estimateFee(
            inputCount: inputs.count,
            outputCount: outputCount,
            feeRate: feeRate
        )

        guard selection.totalInput >= totalAmount + fee else { return nil }

        // Build all outputs
        var outputs = paymentOutputs

        // Add change output if needed
        let change = selection.totalInput - totalAmount - fee
        if change >= CoinSelection.dustThreshold {
            guard let changeScript = PSBTBuilder.scriptPubKeyFromAddress(changeAddress, isTestnet: isTestnet) else {
                return nil
            }
            outputs.append(PSBTBuilder.TxOutput(value: change, scriptPubKey: changeScript))
        }

        // BIP69: sort outputs lexicographically for privacy
        outputs = bip69SortOutputs(outputs)

        return PSBTBuilder.buildPSBT(inputs: inputs, outputs: outputs)
    }

    // MARK: - BIP69 output sorting

    /// Sort outputs per BIP69: by value first, then by scriptPubKey lexicographically
    ///
    /// This deterministic ordering prevents address/change output identification
    /// based on position alone.
    ///
    /// - Parameter outputs: unsorted outputs
    /// - Returns: BIP69-sorted outputs
    static func bip69SortOutputs(_ outputs: [PSBTBuilder.TxOutput]) -> [PSBTBuilder.TxOutput] {
        outputs.sorted { a, b in
            if a.value != b.value {
                return a.value < b.value
            }
            return a.scriptPubKey.hex < b.scriptPubKey.hex
        }
    }

    /// Sort inputs per BIP69: by txid first, then by vout
    ///
    /// - Parameter inputs: unsorted inputs
    /// - Returns: BIP69-sorted inputs
    static func bip69SortInputs(_ inputs: [PSBTBuilder.TxInput]) -> [PSBTBuilder.TxInput] {
        inputs.sorted { a, b in
            let aTxid = a.txid.hex
            let bTxid = b.txid.hex
            if aTxid != bTxid {
                return aTxid < bTxid
            }
            return a.vout < b.vout
        }
    }

    // MARK: - Private helpers

    private static func txidToInternalOrder(_ txid: String) -> Data {
        guard let data = Data(hex: txid) else { return Data(count: 32) }
        return Data(data.reversed())
    }
}
