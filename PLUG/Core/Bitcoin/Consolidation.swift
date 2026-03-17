import Foundation

// MARK: - UTXO Consolidation
// Combines multiple UTXOs into a single output to reduce future transaction costs.
// All provided UTXOs become inputs; a single output goes to the destination minus fee.

struct Consolidation {

    // MARK: - Consolidation PSBT construction

    /// Build a PSBT that consolidates all provided UTXOs into a single output
    ///
    /// Every UTXO becomes an input, and the total value minus the fee
    /// is sent to the destination address as a single output.
    ///
    /// - Parameters:
    ///   - utxos: UTXOs to consolidate (all will be spent)
    ///   - destinationAddress: address to receive the consolidated output
    ///   - feeRate: target fee rate in sat/vB
    ///   - isTestnet: network flag
    /// - Returns: serialized PSBT data, or nil on failure
    static func buildConsolidationPSBT(
        utxos: [UTXO],
        destinationAddress: String,
        feeRate: Double,
        isTestnet: Bool
    ) -> Data? {
        guard !utxos.isEmpty else { return nil }

        // Filter out dust UTXOs
        let spendable = utxos.filter { $0.value > CoinSelection.dustThreshold }
        guard !spendable.isEmpty else { return nil }

        // Calculate total input value
        let totalInput = spendable.reduce(UInt64(0)) { $0 + $1.value }

        // Estimate fee: N inputs, 1 output
        let fee = CoinSelection.estimateFee(
            inputCount: spendable.count,
            outputCount: 1,
            feeRate: feeRate
        )

        guard totalInput > fee + CoinSelection.dustThreshold else { return nil }

        let outputValue = totalInput - fee

        // Build destination output
        guard let destScript = PSBTBuilder.scriptPubKeyFromAddress(destinationAddress, isTestnet: isTestnet) else {
            return nil
        }

        // Build inputs
        let inputs: [PSBTBuilder.TxInput] = spendable.map { utxo in
            let spk = Data(hex: utxo.scriptPubKey) ?? Data()
            return PSBTBuilder.TxInput(
                txid: txidToInternalOrder(utxo.txid),
                vout: UInt32(utxo.vout),
                sequence: 0xFFFFFFFE,
                witnessUtxo: PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk)
            )
        }

        let output = PSBTBuilder.TxOutput(value: outputValue, scriptPubKey: destScript)

        return PSBTBuilder.buildPSBT(inputs: inputs, outputs: [output])
    }

    // MARK: - Analysis helpers

    /// Estimate the fee savings from consolidating UTXOs now vs spending them individually later
    ///
    /// - Parameters:
    ///   - utxoCount: number of UTXOs to consolidate
    ///   - currentFeeRate: current fee rate in sat/vB
    ///   - futureFeeRate: expected fee rate when UTXOs would be spent individually
    /// - Returns: estimated satoshi savings (negative if consolidation costs more)
    static func estimateSavings(
        utxoCount: Int,
        currentFeeRate: Double,
        futureFeeRate: Double
    ) -> Int64 {
        // Cost to consolidate now: N inputs, 1 output
        let consolidationFee = CoinSelection.estimateFee(
            inputCount: utxoCount,
            outputCount: 1,
            feeRate: currentFeeRate
        )

        // Future cost without consolidation: each spend uses 1 input
        // vs with consolidation: each spend uses 1 input (but fewer total future spends)
        // The savings come from not needing N-1 extra inputs at futureFeeRate
        let futureInputCost = UInt64(ceil(Double(CoinSelection.p2wpkhInputVSize) * futureFeeRate))
        let futureSavings = futureInputCost * UInt64(utxoCount - 1)

        return Int64(futureSavings) - Int64(consolidationFee)
    }

    // MARK: - Private helpers

    private static func txidToInternalOrder(_ txid: String) -> Data {
        guard let data = Data(hex: txid) else { return Data(count: 32) }
        return Data(data.reversed())
    }
}
