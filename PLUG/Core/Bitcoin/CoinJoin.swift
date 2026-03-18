import Foundation

// MARK: - CoinJoin Builder
// Serverless PSBT-based CoinJoin — participants exchange PSBTs manually.
// Each participant signs only their own inputs via Ledger (standard wpkh(@0/**)).

struct CoinJoinBuilder {

    /// Standard denomination tiers (sats)
    static let denominations: [UInt64] = [10_000, 50_000, 100_000, 500_000, 1_000_000]

    // MARK: - Initiator: create base CoinJoin PSBT

    /// Creates the initial PSBT with the initiator's input(s) and mix output.
    static func createCoinJoinPSBT(
        utxos: [UTXO],
        denomination: UInt64,
        mixAddress: String,
        changeAddress: String?,
        feePerInput: UInt64,
        isTestnet: Bool
    ) -> Data? {
        guard !utxos.isEmpty else { return nil }
        guard let mixScript = PSBTBuilder.scriptPubKeyFromAddress(mixAddress, isTestnet: isTestnet) else { return nil }

        let totalInput = utxos.reduce(UInt64(0)) { $0 + $1.value }
        guard totalInput >= denomination + feePerInput else { return nil }

        var outputs: [PSBTBuilder.TxOutput] = []

        // Mix output (fixed denomination)
        outputs.append(PSBTBuilder.TxOutput(value: denomination, scriptPubKey: mixScript))

        // Change output
        let change = totalInput - denomination - feePerInput
        if change >= 546, let changeAddr = changeAddress,
           let changeScript = PSBTBuilder.scriptPubKeyFromAddress(changeAddr, isTestnet: isTestnet) {
            outputs.append(PSBTBuilder.TxOutput(value: change, scriptPubKey: changeScript))
        }

        let inputs: [PSBTBuilder.TxInput] = utxos.map { utxo in
            let txid = SpendManager.txidToInternalOrder(utxo.txid)
            let spk = Data(hex: utxo.scriptPubKey) ?? Data()
            return PSBTBuilder.TxInput(
                txid: txid,
                vout: UInt32(utxo.vout),
                sequence: 0xFFFFFFFD,
                witnessUtxo: PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk)
            )
        }

        return PSBTBuilder.buildPSBT(inputs: inputs, outputs: outputs, locktime: 0)
    }

    // MARK: - Joiner: add inputs/outputs to existing PSBT

    /// Parses an existing CoinJoin PSBT, adds the joiner's inputs and outputs,
    /// shuffles all outputs, and returns the updated PSBT.
    static func joinCoinJoin(
        existingPSBT: Data,
        myUTXOs: [UTXO],
        denomination: UInt64,
        mixAddress: String,
        changeAddress: String?,
        feePerInput: UInt64,
        isTestnet: Bool
    ) -> Data? {
        guard let parsed = PSBTBuilder.parsePSBT(existingPSBT),
              let unsignedTx = parsed.unsignedTx else { return nil }
        guard !myUTXOs.isEmpty else { return nil }
        guard let mixScript = PSBTBuilder.scriptPubKeyFromAddress(mixAddress, isTestnet: isTestnet) else { return nil }

        let totalInput = myUTXOs.reduce(UInt64(0)) { $0 + $1.value }
        guard totalInput >= denomination + feePerInput else { return nil }

        // Parse existing inputs and outputs from the unsigned tx
        let existingInputs = parseInputsFromTx(unsignedTx)
        let existingOutputs = parseOutputsFromTx(unsignedTx)

        // Build new inputs: existing + joiner's
        var allInputs = existingInputs
        for utxo in myUTXOs {
            let txid = SpendManager.txidToInternalOrder(utxo.txid)
            let spk = Data(hex: utxo.scriptPubKey) ?? Data()
            allInputs.append(PSBTBuilder.TxInput(
                txid: txid,
                vout: UInt32(utxo.vout),
                sequence: 0xFFFFFFFD,
                witnessUtxo: PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk)
            ))
        }

        // Build new outputs: existing + joiner's mix + joiner's change
        var allOutputs = existingOutputs
        allOutputs.append(PSBTBuilder.TxOutput(value: denomination, scriptPubKey: mixScript))

        let change = totalInput - denomination - feePerInput
        if change >= 546, let changeAddr = changeAddress,
           let changeScript = PSBTBuilder.scriptPubKeyFromAddress(changeAddr, isTestnet: isTestnet) {
            allOutputs.append(PSBTBuilder.TxOutput(value: change, scriptPubKey: changeScript))
        }

        // Shuffle outputs for privacy (inputs too)
        let shuffledOutputs = allOutputs.shuffled()
        let shuffledInputs = allInputs.shuffled()

        return PSBTBuilder.buildPSBT(inputs: shuffledInputs, outputs: shuffledOutputs, locktime: 0)
    }

    // MARK: - Validation

    struct CoinJoinInfo {
        let denomination: UInt64
        let participantCount: Int
        let totalInputs: Int
        let totalOutputs: Int
        let mixOutputCount: Int
        let isValid: Bool
    }

    /// Analyzes a PSBT to detect CoinJoin parameters.
    static func analyzePSBT(_ psbtData: Data, isTestnet: Bool) -> CoinJoinInfo? {
        guard let parsed = PSBTBuilder.parsePSBT(psbtData),
              let unsignedTx = parsed.unsignedTx else { return nil }

        let inputs = parseInputsFromTx(unsignedTx)
        let outputs = parseOutputsFromTx(unsignedTx)

        guard !outputs.isEmpty else { return nil }

        // Find the denomination: the most common output value
        var valueCounts: [UInt64: Int] = [:]
        for output in outputs {
            valueCounts[output.value, default: 0] += 1
        }

        // The denomination is the value that appears most (and at least 2x for a real CoinJoin)
        let sorted = valueCounts.sorted { $0.value > $1.value }
        let denomination = sorted.first?.key ?? 0
        let mixCount = sorted.first?.value ?? 0

        return CoinJoinInfo(
            denomination: denomination,
            participantCount: mixCount,
            totalInputs: inputs.count,
            totalOutputs: outputs.count,
            mixOutputCount: mixCount,
            isValid: mixCount >= 1 && denomination > 546
        )
    }

    // MARK: - Parse helpers

    /// Parse inputs from a raw unsigned transaction.
    static func parseInputsFromTx(_ tx: Data) -> [PSBTBuilder.TxInput] {
        var inputs: [PSBTBuilder.TxInput] = []
        var offset = 4 // skip version

        // Input count
        guard let (inputCount, icBytes) = VarInt.decode(tx, offset: offset) else { return [] }
        offset += icBytes

        for _ in 0..<inputCount {
            guard offset + 36 <= tx.count else { return [] }
            let txid = Data(tx[offset..<(offset + 32)])
            offset += 32
            let vout = UInt32(tx[offset]) | (UInt32(tx[offset+1]) << 8) | (UInt32(tx[offset+2]) << 16) | (UInt32(tx[offset+3]) << 24)
            offset += 4

            // scriptSig (should be empty for unsigned)
            guard let (scriptLen, slBytes) = VarInt.decode(tx, offset: offset) else { return [] }
            offset += slBytes + Int(scriptLen)

            // sequence
            guard offset + 4 <= tx.count else { return [] }
            let seq = UInt32(tx[offset]) | (UInt32(tx[offset+1]) << 8) | (UInt32(tx[offset+2]) << 16) | (UInt32(tx[offset+3]) << 24)
            offset += 4

            inputs.append(PSBTBuilder.TxInput(
                txid: txid, vout: vout, sequence: seq,
                witnessUtxo: PSBTBuilder.TxOutput(value: 0, scriptPubKey: Data())
            ))
        }

        return inputs
    }

    /// Parse outputs from a raw unsigned transaction.
    static func parseOutputsFromTx(_ tx: Data) -> [PSBTBuilder.TxOutput] {
        var outputs: [PSBTBuilder.TxOutput] = []
        var offset = 4 // skip version

        // Skip inputs
        guard let (inputCount, icBytes) = VarInt.decode(tx, offset: offset) else { return [] }
        offset += icBytes
        for _ in 0..<inputCount {
            guard offset + 32 + 4 <= tx.count else { return [] }
            offset += 36 // txid + vout
            guard let (scriptLen, slBytes) = VarInt.decode(tx, offset: offset) else { return [] }
            offset += slBytes + Int(scriptLen) + 4 // scriptSig + sequence
        }

        // Output count
        guard let (outputCount, ocBytes) = VarInt.decode(tx, offset: offset) else { return [] }
        offset += ocBytes

        for _ in 0..<outputCount {
            guard offset + 8 <= tx.count else { return [] }
            var value: UInt64 = 0
            for i in 0..<8 {
                value |= UInt64(tx[offset + i]) << (i * 8)
            }
            offset += 8

            guard let (spkLen, spkBytes) = VarInt.decode(tx, offset: offset) else { return [] }
            offset += spkBytes
            guard offset + Int(spkLen) <= tx.count else { return [] }
            let spk = Data(tx[offset..<(offset + Int(spkLen))])
            offset += Int(spkLen)

            outputs.append(PSBTBuilder.TxOutput(value: value, scriptPubKey: spk))
        }

        return outputs
    }

    // MARK: - Fee estimation

    /// Estimated fee per input for a P2WPKH CoinJoin.
    /// Each input adds ~68 vbytes, each output ~31 vbytes, overhead ~11 vbytes.
    static func estimateFeePerInput(feeRate: Double, outputsPerParticipant: Int = 2) -> UInt64 {
        let inputVbytes = 68
        let outputVbytes = 31 * outputsPerParticipant
        let perParticipant = inputVbytes + outputVbytes
        return UInt64(ceil(Double(perParticipant) * feeRate))
    }
}
