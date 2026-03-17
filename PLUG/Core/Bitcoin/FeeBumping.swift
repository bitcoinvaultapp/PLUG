import Foundation

// MARK: - Fee Bumping (RBF and CPFP)
// Replace-By-Fee: build a replacement transaction with higher fee (BIP125)
// Child-Pays-For-Parent: spend an unconfirmed output with a high-fee child

struct FeeBumping {

    // MARK: - RBF (Replace-By-Fee)

    /// Build an RBF replacement PSBT with a higher fee rate
    ///
    /// Creates a new transaction spending the same inputs as the original,
    /// but with a higher fee. The sequence numbers are set to enable RBF (< 0xFFFFFFFE).
    ///
    /// - Parameters:
    ///   - originalInputs: inputs from the original transaction (txid:vout pairs with values)
    ///   - originalOutputAddress: destination address of the original transaction
    ///   - originalAmount: original payment amount in satoshis
    ///   - newFeeRate: new fee rate in sat/vB (must be higher than original)
    ///   - utxos: available UTXOs (may include additional UTXOs if needed)
    ///   - changeAddress: address for change output
    ///   - isTestnet: network flag
    /// - Returns: serialized PSBT data, or nil on failure
    static func createRBFReplacement(
        originalInputs: [(txid: String, vout: Int, value: UInt64, scriptPubKey: String)],
        originalOutputAddress: String,
        originalAmount: UInt64,
        newFeeRate: Double,
        utxos: [UTXO],
        changeAddress: String,
        isTestnet: Bool
    ) -> Data? {
        // Calculate total from original inputs
        let totalOriginalInput = originalInputs.reduce(UInt64(0)) { $0 + $1.value }

        // Estimate fee with original input count
        let estimatedFee = CoinSelection.estimateFee(
            inputCount: originalInputs.count,
            outputCount: 2,
            feeRate: newFeeRate
        )

        // Check if original inputs cover the new fee
        var inputs: [PSBTBuilder.TxInput] = originalInputs.map { input in
            let spk = Data(hex: input.scriptPubKey) ?? Data()
            return PSBTBuilder.TxInput(
                txid: txidToInternalOrder(input.txid),
                vout: UInt32(input.vout),
                sequence: 0xFFFFFFFD, // RBF-enabled sequence (BIP125)
                witnessUtxo: PSBTBuilder.TxOutput(value: input.value, scriptPubKey: spk)
            )
        }

        var totalInput = totalOriginalInput

        // If original inputs don't cover new fee, add more UTXOs
        if totalInput < originalAmount + estimatedFee {
            let deficit = originalAmount + estimatedFee - totalInput

            // Filter out UTXOs already used as inputs
            let usedOutpoints = Set(originalInputs.map { "\($0.txid):\($0.vout)" })
            let availableUTXOs = utxos.filter { !usedOutpoints.contains($0.outpoint) }

            guard let extra = CoinSelection.select(
                from: availableUTXOs,
                target: deficit,
                feeRate: newFeeRate
            ) else { return nil }

            for utxo in extra.selectedUTXOs {
                let spk = Data(hex: utxo.scriptPubKey) ?? Data()
                inputs.append(PSBTBuilder.TxInput(
                    txid: txidToInternalOrder(utxo.txid),
                    vout: UInt32(utxo.vout),
                    sequence: 0xFFFFFFFD,
                    witnessUtxo: PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk)
                ))
                totalInput += utxo.value
            }
        }

        // Recalculate fee with final input count
        let finalFee = CoinSelection.estimateFee(
            inputCount: inputs.count,
            outputCount: 2,
            feeRate: newFeeRate
        )

        guard totalInput >= originalAmount + finalFee else { return nil }

        // Build outputs
        guard let destScript = PSBTBuilder.scriptPubKeyFromAddress(originalOutputAddress, isTestnet: isTestnet) else {
            return nil
        }

        var outputs: [PSBTBuilder.TxOutput] = [
            PSBTBuilder.TxOutput(value: originalAmount, scriptPubKey: destScript)
        ]

        let change = totalInput - originalAmount - finalFee
        if change >= CoinSelection.dustThreshold {
            guard let changeScript = PSBTBuilder.scriptPubKeyFromAddress(changeAddress, isTestnet: isTestnet) else {
                return nil
            }
            outputs.append(PSBTBuilder.TxOutput(value: change, scriptPubKey: changeScript))
        }

        return PSBTBuilder.buildPSBT(inputs: inputs, outputs: outputs)
    }

    // MARK: - CPFP (Child-Pays-For-Parent)

    /// Build a CPFP child transaction that spends an unconfirmed parent output
    ///
    /// The child's fee is set high enough to incentivize miners to confirm
    /// both the parent and child together.
    ///
    /// - Parameters:
    ///   - parentTxid: txid of the unconfirmed parent transaction
    ///   - parentVout: output index in the parent to spend
    ///   - parentValue: value of the parent output in satoshis
    ///   - parentScriptPubKey: scriptPubKey of the parent output
    ///   - childFeeRate: desired effective fee rate in sat/vB for the package
    ///   - destinationAddress: where to send the child output
    ///   - isTestnet: network flag
    /// - Returns: serialized PSBT data, or nil on failure
    static func createCPFP(
        parentTxid: String,
        parentVout: Int,
        parentValue: UInt64,
        parentScriptPubKey: String,
        childFeeRate: Double,
        destinationAddress: String,
        isTestnet: Bool
    ) -> Data? {
        let spk = Data(hex: parentScriptPubKey) ?? Data()

        let input = PSBTBuilder.TxInput(
            txid: txidToInternalOrder(parentTxid),
            vout: UInt32(parentVout),
            sequence: 0xFFFFFFFE,
            witnessUtxo: PSBTBuilder.TxOutput(value: parentValue, scriptPubKey: spk)
        )

        // Estimate child tx fee
        let childFee = CoinSelection.estimateFee(
            inputCount: 1,
            outputCount: 1,
            feeRate: childFeeRate
        )

        guard parentValue > childFee + CoinSelection.dustThreshold else { return nil }

        guard let destScript = PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet) else {
            return nil
        }

        let outputValue = parentValue - childFee
        let output = PSBTBuilder.TxOutput(value: outputValue, scriptPubKey: destScript)

        return PSBTBuilder.buildPSBT(inputs: [input], outputs: [output])
    }

    // MARK: - Fee calculation helpers

    /// Calculate the minimum fee bump needed for RBF (must pay at least 1 sat/vB more)
    static func minimumRBFFee(originalFee: UInt64, originalVSize: Int, newVSize: Int) -> UInt64 {
        // BIP125 rule 4: replacement must pay higher absolute fee
        // Also must pay for the bandwidth of the replacement (rule 3)
        let minIncrementalFee = UInt64(newVSize) // 1 sat/vB relay fee
        return originalFee + minIncrementalFee
    }

    /// Estimate the effective fee rate needed for a CPFP child
    /// to achieve a target package fee rate
    static func cpfpChildFeeRate(
        parentVSize: Int,
        parentFee: UInt64,
        childVSize: Int,
        targetPackageFeeRate: Double
    ) -> Double {
        let totalVSize = Double(parentVSize + childVSize)
        let totalFeeNeeded = totalVSize * targetPackageFeeRate
        let childFeeNeeded = totalFeeNeeded - Double(parentFee)
        guard childFeeNeeded > 0 else { return 1.0 }
        return childFeeNeeded / Double(childVSize)
    }

    // MARK: - Private helpers

    private static func txidToInternalOrder(_ txid: String) -> Data {
        guard let data = Data(hex: txid) else { return Data(count: 32) }
        return Data(data.reversed())
    }
}
