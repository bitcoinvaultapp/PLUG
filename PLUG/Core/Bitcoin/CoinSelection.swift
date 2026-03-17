import Foundation

// MARK: - Coin Selection Strategies
// 3 strategies: largestFirst, smallestFirst, exact
// Handles dust threshold and frozen UTXOs

enum CoinSelectionStrategy {
    case largestFirst
    case smallestFirst
    case exact
}

struct CoinSelection {

    static let dustThreshold: UInt64 = 546 // sats

    /// Input size estimate for P2WPKH (in vbytes)
    static let p2wpkhInputVSize: Int = 68
    /// Output size estimate for P2WPKH
    static let p2wpkhOutputVSize: Int = 31
    /// Transaction overhead
    static let txOverheadVSize: Int = 11

    struct SelectionResult {
        let selectedUTXOs: [UTXO]
        let totalInput: UInt64
        let fee: UInt64
        let change: UInt64
        let hasChange: Bool

        var totalOutput: UInt64 {
            totalInput - fee
        }
    }

    /// Select UTXOs for a transaction
    static func select(
        from utxos: [UTXO],
        target: UInt64,
        feeRate: Double, // sat/vbyte
        strategy: CoinSelectionStrategy = .largestFirst,
        frozenOutpoints: Set<String> = []
    ) -> SelectionResult? {

        // Filter out frozen and dust UTXOs
        let available = utxos.filter { utxo in
            !frozenOutpoints.contains(utxo.outpoint) && utxo.value > dustThreshold
        }

        guard !available.isEmpty else { return nil }

        // Sort based on strategy
        let sorted: [UTXO]
        switch strategy {
        case .largestFirst:
            sorted = available.sorted { $0.value > $1.value }
        case .smallestFirst:
            sorted = available.sorted { $0.value < $1.value }
        case .exact:
            // Try to find an exact match (or close to target + estimated fee)
            return selectExact(from: available, target: target, feeRate: feeRate)
        }

        return selectGreedy(from: sorted, target: target, feeRate: feeRate)
    }

    private static func selectGreedy(
        from sortedUTXOs: [UTXO],
        target: UInt64,
        feeRate: Double
    ) -> SelectionResult? {
        var selected: [UTXO] = []
        var totalInput: UInt64 = 0

        for utxo in sortedUTXOs {
            selected.append(utxo)
            totalInput += utxo.value

            // Calculate fee with current selection
            let fee = estimateFee(
                inputCount: selected.count,
                outputCount: 2, // payment + change
                feeRate: feeRate
            )

            if totalInput >= target + fee {
                let change = totalInput - target - fee

                // If change is dust, don't create change output
                if change < dustThreshold {
                    let feeNoChange = estimateFee(
                        inputCount: selected.count,
                        outputCount: 1,
                        feeRate: feeRate
                    )
                    // Absorb dust into fee
                    return SelectionResult(
                        selectedUTXOs: selected,
                        totalInput: totalInput,
                        fee: totalInput - target,
                        change: 0,
                        hasChange: false
                    )
                }

                return SelectionResult(
                    selectedUTXOs: selected,
                    totalInput: totalInput,
                    fee: fee,
                    change: change,
                    hasChange: true
                )
            }
        }

        return nil // Insufficient funds
    }

    private static func selectExact(
        from utxos: [UTXO],
        target: UInt64,
        feeRate: Double
    ) -> SelectionResult? {
        // Try single UTXO first
        let feeOneInput = estimateFee(inputCount: 1, outputCount: 1, feeRate: feeRate)
        let feeTwoOutputs = estimateFee(inputCount: 1, outputCount: 2, feeRate: feeRate)

        // Look for exact match (no change needed)
        for utxo in utxos {
            let diff = Int64(utxo.value) - Int64(target) - Int64(feeOneInput)
            if diff >= 0 && diff < Int64(dustThreshold) {
                return SelectionResult(
                    selectedUTXOs: [utxo],
                    totalInput: utxo.value,
                    fee: utxo.value - target,
                    change: 0,
                    hasChange: false
                )
            }
        }

        // Fall back to largest first
        let sorted = utxos.sorted { $0.value > $1.value }
        return selectGreedy(from: sorted, target: target, feeRate: feeRate)
    }

    /// Estimate transaction fee in satoshis
    static func estimateFee(inputCount: Int, outputCount: Int, feeRate: Double) -> UInt64 {
        let vsize = txOverheadVSize +
                    (inputCount * p2wpkhInputVSize) +
                    (outputCount * p2wpkhOutputVSize)
        return UInt64(ceil(Double(vsize) * feeRate))
    }

    /// Estimate fee for a P2WSH input (larger witness)
    static func estimateP2WSHFee(inputCount: Int, outputCount: Int, witnessSize: Int, feeRate: Double) -> UInt64 {
        let p2wshInputVSize = 41 + (witnessSize + 3) / 4 // witness discount
        let vsize = txOverheadVSize +
                    (inputCount * p2wshInputVSize) +
                    (outputCount * p2wpkhOutputVSize)
        return UInt64(ceil(Double(vsize) * feeRate))
    }
}
