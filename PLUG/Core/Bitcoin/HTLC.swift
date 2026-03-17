import Foundation

// MARK: - Hash Time-Lock Contract (HTLC)
// Enables atomic swaps and payment channels with hash locks and timelocks.
// Script: OP_IF OP_SHA256 <hash> OP_EQUALVERIFY <receiver_pubkey> OP_CHECKSIG
//         OP_ELSE <timeout> OP_CHECKLOCKTIMEVERIFY OP_DROP <sender_pubkey> OP_CHECKSIG OP_ENDIF

struct HTLCBuilder {

    // MARK: - Preimage utilities

    /// Generate a cryptographically secure random 32-byte preimage.
    /// Uses SecRandomCopyBytes (Apple CryptoRandom) — confirmed cryptographically secure entropy source.
    /// Returns nil if the system CSPRNG fails (should never happen on iOS/macOS).
    static func generatePreimage() -> Data? {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        guard status == errSecSuccess else { return nil }
        return bytes
    }

    /// SHA256 hash of a preimage (used as the hash lock)
    static func hashPreimage(_ preimage: Data) -> Data {
        Crypto.sha256(preimage)
    }

    // MARK: - Script construction

    /// Build the HTLC witness script
    ///
    /// Claim path (OP_IF): receiver provides preimage + signature
    /// Refund path (OP_ELSE): sender reclaims after timeout via CLTV
    ///
    /// - Parameters:
    ///   - receiverPubkey: 33-byte compressed pubkey of the receiver
    ///   - senderPubkey: 33-byte compressed pubkey of the sender
    ///   - hashLock: 32-byte SHA256 hash of the preimage
    ///   - timeoutBlocks: absolute block height for CLTV refund
    /// - Returns: ScriptBuilder with the assembled HTLC script
    /// HTLC: Hash Time-Lock Contract
    /// Miniscript: andor(pk(@0),sha256(H),and_v(v:pk(@1),after(N)))
    /// Script: <RECEIVER> OP_CHECKSIG OP_NOTIF <SENDER> OP_CHECKSIGVERIFY <N> OP_CLTV OP_ELSE OP_SIZE <20> OP_EQUALVERIFY OP_SHA256 <H> OP_EQUAL OP_ENDIF
    /// This format matches the Ledger's miniscript compiler output exactly.
    static func htlcScript(
        receiverPubkey: Data,
        senderPubkey: Data,
        hashLock: Data,
        timeoutBlocks: Int64
    ) -> ScriptBuilder {
        ScriptBuilder()
            .pushData(receiverPubkey)
            .addOp(.op_checksig)
            .addOp(.op_notif)
                .pushData(senderPubkey)
                .addOp(.op_checksigverify)
                .pushNumber(timeoutBlocks)
                .addOp(.op_checklocktimeverify)
            .addOp(.op_else)
                .addOp(.op_size)
                .pushNumber(32)
                .addOp(.op_equalverify)
                .addOp(.op_sha256)
                .pushData(hashLock)
                .addOp(.op_equal)
            .addOp(.op_endif)
    }

    // MARK: - Witness stack helpers

    /// Build witness stack for HTLC claim (andor primary + sha256 path)
    /// Miniscript andor: receiver sig satisfies pk(@0), preimage satisfies sha256(H)
    /// Witness: <preimage> <signature> <witnessScript>
    static func claimWitness(
        signature: Data,
        preimage: Data,
        witnessScript: Data
    ) -> [Data] {
        [preimage, signature, witnessScript]
    }

    /// Build witness stack for HTLC refund (andor fallback path)
    /// Empty receiver sig → OP_NOTIF enters → sender sig + CLTV
    /// Witness: <signature> <empty> <witnessScript>
    static func refundWitness(
        signature: Data,
        witnessScript: Data
    ) -> [Data] {
        [signature, Data(), witnessScript]
    }

    // MARK: - PSBT construction

    /// Build an unsigned PSBT to fund an HTLC
    ///
    /// - Parameters:
    ///   - receiverPubkey: receiver's compressed pubkey
    ///   - senderPubkey: sender's compressed pubkey
    ///   - hashLock: SHA256 hash lock
    ///   - timeoutBlocks: CLTV timeout block height
    ///   - amount: satoshis to lock
    ///   - utxos: available UTXOs for funding
    ///   - feeRate: target fee rate in sat/vB
    ///   - changeAddress: address for change output
    ///   - isTestnet: network flag
    /// - Returns: serialized PSBT data, or nil on failure
    static func buildFundingPSBT(
        receiverPubkey: Data,
        senderPubkey: Data,
        hashLock: Data,
        timeoutBlocks: Int64,
        amount: UInt64,
        utxos: [UTXO],
        feeRate: Double,
        changeAddress: String,
        isTestnet: Bool
    ) -> Data? {
        let script = htlcScript(
            receiverPubkey: receiverPubkey,
            senderPubkey: senderPubkey,
            hashLock: hashLock,
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

    /// Convert RPC-order txid hex to internal byte order (reversed)
    private static func txidToInternalOrder(_ txid: String) -> Data {
        guard let data = Data(hex: txid) else { return Data(count: 32) }
        return Data(data.reversed())
    }
}
