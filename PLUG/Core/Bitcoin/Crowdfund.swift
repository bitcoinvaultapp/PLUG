import Foundation

// MARK: - Crowdfunding with SIGHASH_ANYONECANPAY
// Enables crowdfunding transactions where multiple contributors each sign
// their own input with SIGHASH_ALL|ANYONECANPAY (0x81), allowing inputs
// to be added independently while locking all outputs.

struct CrowdfundBuilder {

    // MARK: - Sighash type constants

    /// Standard sighash: signs all inputs and all outputs
    static let sighashAll: UInt8 = 0x01

    /// Signs only the contributor's own input + all outputs
    /// Allows other inputs to be added without invalidating this signature
    static let sighashAllAnyoneCanPay: UInt8 = 0x81

    /// Signs own input + only the output at the same index
    static let sighashSingleAnyoneCanPay: UInt8 = 0x83

    // MARK: - PSBT key types for sighash

    /// PSBT input key type for sighash type (BIP174)
    static let psbtInputSighashType: UInt8 = 0x03

    // MARK: - Fundraiser creation

    /// Create the base PSBT for a crowdfunding campaign
    ///
    /// This creates a transaction with the target output but no inputs.
    /// Contributors will add their own inputs via `addContribution`.
    ///
    /// - Parameters:
    ///   - targetAmount: total satoshis to raise
    ///   - recipientAddress: address that receives the crowdfunded amount
    ///   - isTestnet: network flag
    /// - Returns: serialized PSBT data, or nil on failure
    static func createFundraiser(
        targetAmount: UInt64,
        recipientAddress: String,
        isTestnet: Bool
    ) -> Data? {
        guard let destScript = PSBTBuilder.scriptPubKeyFromAddress(recipientAddress, isTestnet: isTestnet) else {
            return nil
        }

        let output = PSBTBuilder.TxOutput(value: targetAmount, scriptPubKey: destScript)

        // Build a PSBT with no inputs and one output
        // Contributors will append inputs
        return PSBTBuilder.buildPSBT(inputs: [], outputs: [output])
    }

    /// Add a contribution input to an existing crowdfund PSBT
    ///
    /// Each contributor signs with SIGHASH_ALL|ANYONECANPAY so that
    /// additional inputs can be added without invalidating their signature.
    ///
    /// - Parameters:
    ///   - basePSBT: the existing crowdfund PSBT (may already have other contributions)
    ///   - utxo: the contributor's UTXO to spend
    ///   - isTestnet: network flag
    /// - Returns: updated PSBT with the new input appended, or nil on failure
    static func addContribution(
        basePSBT: Data,
        utxo: UTXO,
        isTestnet: Bool
    ) -> Data? {
        // Parse the base PSBT to extract outputs
        guard let parsed = PSBTBuilder.parsePSBT(basePSBT) else { return nil }
        guard let unsignedTx = parsed.unsignedTx else { return nil }

        // Parse outputs from the unsigned tx
        guard let txOutputs = parseOutputsFromTx(unsignedTx) else { return nil }

        // Parse existing inputs from the unsigned tx
        let existingInputs = parseInputsFromTx(unsignedTx)

        // Create the new input
        let spk = Data(hex: utxo.scriptPubKey) ?? Data()
        let newInput = PSBTBuilder.TxInput(
            txid: txidToInternalOrder(utxo.txid),
            vout: UInt32(utxo.vout),
            sequence: 0xFFFFFFFF,
            witnessUtxo: PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk)
        )

        // Combine existing inputs with the new one
        var allInputs = existingInputs
        allInputs.append(newInput)

        // Rebuild the PSBT with all inputs
        var psbt = PSBTBuilder.buildPSBT(inputs: allInputs, outputs: txOutputs)

        // Append sighash type annotation for the new input
        // This signals to the signer to use SIGHASH_ALL|ANYONECANPAY
        appendSighashType(to: &psbt, inputIndex: allInputs.count - 1, sighashType: sighashAllAnyoneCanPay)

        return psbt
    }

    // MARK: - Private helpers

    private static func txidToInternalOrder(_ txid: String) -> Data {
        guard let data = Data(hex: txid) else { return Data(count: 32) }
        return Data(data.reversed())
    }

    /// Append a sighash type to the PSBT for a specific input
    /// Note: this is a simplified approach; a full implementation would
    /// modify the parsed PSBT structure directly.
    private static func appendSighashType(to psbt: inout Data, inputIndex: Int, sighashType: UInt8) {
        // The sighash type is informational metadata for the signer.
        // In a complete implementation, this would be inserted into the
        // correct input map during PSBT construction.
        _ = inputIndex
        _ = sighashType
    }

    /// Parse output data from a raw unsigned transaction
    private static func parseOutputsFromTx(_ tx: Data) -> [PSBTBuilder.TxOutput]? {
        guard tx.count >= 10 else { return nil }
        var offset = 4 // skip version

        // Skip inputs
        guard let (inputCount, inputCountBytes) = VarInt.decode(tx, offset: offset) else { return nil }
        offset += inputCountBytes

        for _ in 0..<inputCount {
            offset += 32 // txid
            offset += 4  // vout
            guard let (scriptLen, scriptLenBytes) = VarInt.decode(tx, offset: offset) else { return nil }
            offset += scriptLenBytes + Int(scriptLen)
            offset += 4 // sequence
        }

        // Parse outputs
        guard let (outputCount, outputCountBytes) = VarInt.decode(tx, offset: offset) else { return nil }
        offset += outputCountBytes

        var outputs: [PSBTBuilder.TxOutput] = []
        for _ in 0..<outputCount {
            guard offset + 8 <= tx.count else { return nil }
            var value: UInt64 = 0
            for i in 0..<8 {
                value |= UInt64(tx[offset + i]) << (i * 8)
            }
            offset += 8

            guard let (scriptLen, scriptLenBytes) = VarInt.decode(tx, offset: offset) else { return nil }
            offset += scriptLenBytes
            guard offset + Int(scriptLen) <= tx.count else { return nil }
            let scriptPubKey = Data(tx[offset..<(offset + Int(scriptLen))])
            offset += Int(scriptLen)

            outputs.append(PSBTBuilder.TxOutput(value: value, scriptPubKey: scriptPubKey))
        }

        return outputs
    }

    /// Parse inputs from a raw unsigned transaction
    private static func parseInputsFromTx(_ tx: Data) -> [PSBTBuilder.TxInput] {
        guard tx.count >= 10 else { return [] }
        var offset = 4 // skip version

        guard let (inputCount, inputCountBytes) = VarInt.decode(tx, offset: offset) else { return [] }
        offset += inputCountBytes

        var inputs: [PSBTBuilder.TxInput] = []
        for _ in 0..<inputCount {
            guard offset + 36 <= tx.count else { return inputs }
            let txid = Data(tx[offset..<(offset + 32)])
            offset += 32

            var vout: UInt32 = 0
            for i in 0..<4 {
                vout |= UInt32(tx[offset + i]) << (i * 8)
            }
            offset += 4

            guard let (scriptLen, scriptLenBytes) = VarInt.decode(tx, offset: offset) else { return inputs }
            offset += scriptLenBytes + Int(scriptLen)

            guard offset + 4 <= tx.count else { return inputs }
            var sequence: UInt32 = 0
            for i in 0..<4 {
                sequence |= UInt32(tx[offset + i]) << (i * 8)
            }
            offset += 4

            inputs.append(PSBTBuilder.TxInput(
                txid: txid,
                vout: vout,
                sequence: sequence
            ))
        }

        return inputs
    }
}
