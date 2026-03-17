import Foundation

// MARK: - PSBT (Partially Signed Bitcoin Transactions) - BIP174
// Constructs unsigned transactions for Ledger signing

struct PSBTBuilder {

    // PSBT magic bytes
    static let magic = Data([0x70, 0x73, 0x62, 0x74, 0xFF]) // "psbt\xff"

    // PSBT key types
    enum GlobalKey: UInt8 {
        case unsignedTx = 0x00
    }

    enum InputKey: UInt8 {
        case witnessUtxo = 0x01
        case witnessScript = 0x05
        case bip32Derivation = 0x06
    }

    enum OutputKey: UInt8 {
        case witnessScript = 0x01
        case bip32Derivation = 0x02
    }

    // MARK: - Transaction structure

    struct TxInput {
        let txid: Data          // 32 bytes, internal byte order
        let vout: UInt32
        let sequence: UInt32

        /// Previous output for witness UTXO
        var witnessUtxo: TxOutput?

        /// Witness script (for P2WSH)
        var witnessScript: Data?

        /// BIP32 derivation info
        var bip32Derivation: [(pubkey: Data, fingerprint: Data, path: [UInt32])]?

        var outpoint: String {
            // Display txid in RPC byte order (reversed)
            Data(txid.reversed()).hex + ":\(vout)"
        }
    }

    struct TxOutput {
        let value: UInt64       // satoshis
        let scriptPubKey: Data

        var serialized: Data {
            var data = Data()
            var val = value.littleEndian
            data.append(Data(bytes: &val, count: 8))
            data.append(VarInt.encode(UInt64(scriptPubKey.count)))
            data.append(scriptPubKey)
            return data
        }
    }

    // MARK: - Build unsigned transaction

    static func buildUnsignedTx(
        inputs: [TxInput],
        outputs: [TxOutput],
        locktime: UInt32 = 0
    ) -> Data {
        var tx = Data()

        // Version (2 = segwit)
        var version: UInt32 = 2
        tx.append(Data(bytes: &version, count: 4))

        // Input count
        tx.append(VarInt.encode(UInt64(inputs.count)))

        // Inputs
        for input in inputs {
            tx.append(input.txid) // txid (already internal byte order)
            var vout = input.vout.littleEndian
            tx.append(Data(bytes: &vout, count: 4))
            tx.append(VarInt.encode(0)) // empty scriptSig
            var seq = input.sequence.littleEndian
            tx.append(Data(bytes: &seq, count: 4))
        }

        // Output count
        tx.append(VarInt.encode(UInt64(outputs.count)))

        // Outputs
        for output in outputs {
            tx.append(output.serialized)
        }

        // Locktime
        var lt = locktime.littleEndian
        tx.append(Data(bytes: &lt, count: 4))

        return tx
    }

    // MARK: - Build PSBT

    static func buildPSBT(
        inputs: [TxInput],
        outputs: [TxOutput],
        locktime: UInt32 = 0
    ) -> Data {
        var psbt = Data()
        psbt.append(magic)

        // === Global map ===
        let unsignedTx = buildUnsignedTx(inputs: inputs, outputs: outputs, locktime: locktime)

        // Key: 0x00, Value: unsigned tx
        psbt.append(keyValue(key: Data([GlobalKey.unsignedTx.rawValue]), value: unsignedTx))

        // Separator
        psbt.append(0x00)

        // === Input maps ===
        for input in inputs {
            // Witness UTXO
            if let witnessUtxo = input.witnessUtxo {
                psbt.append(keyValue(
                    key: Data([InputKey.witnessUtxo.rawValue]),
                    value: witnessUtxo.serialized
                ))
            }

            // Witness script (for P2WSH inputs)
            if let ws = input.witnessScript {
                psbt.append(keyValue(
                    key: Data([InputKey.witnessScript.rawValue]),
                    value: ws
                ))
            }

            // BIP32 derivation
            if let derivations = input.bip32Derivation {
                for deriv in derivations {
                    var key = Data([InputKey.bip32Derivation.rawValue])
                    key.append(deriv.pubkey)

                    var value = deriv.fingerprint
                    for idx in deriv.path {
                        var le = idx.littleEndian
                        value.append(Data(bytes: &le, count: 4))
                    }

                    psbt.append(keyValue(key: key, value: value))
                }
            }

            // Separator
            psbt.append(0x00)
        }

        // === Output maps ===
        for output in outputs {
            // For now, empty output maps (can add BIP32 derivation for change)
            psbt.append(0x00)
        }

        return psbt
    }

    // MARK: - Key-Value pair encoding

    private static func keyValue(key: Data, value: Data) -> Data {
        var data = Data()
        data.append(VarInt.encode(UInt64(key.count)))
        data.append(key)
        data.append(VarInt.encode(UInt64(value.count)))
        data.append(value)
        return data
    }

    // MARK: - PSBT parsing

    struct ParsedPSBT {
        var unsignedTx: Data?
        var inputs: [ParsedInput] = []
        var outputs: [ParsedOutput] = []
    }

    struct ParsedInput {
        var witnessUtxo: Data?
        var witnessScript: Data?
        var partialSigs: [(pubkey: Data, sig: Data)] = []
        var bip32Derivations: [(pubkey: Data, fingerprint: Data, path: [UInt32])] = []
    }

    struct ParsedOutput {
        var witnessScript: Data?
        var bip32Derivations: [(pubkey: Data, fingerprint: Data, path: [UInt32])] = []
    }

    static func parsePSBT(_ data: Data) -> ParsedPSBT? {
        guard data.count >= 5 else { return nil }
        guard Data(data[0..<5]) == magic else { return nil }

        var offset = 5
        var result = ParsedPSBT()

        // Parse global map
        while offset < data.count {
            guard let (keyLen, keyLenBytes) = VarInt.decode(data, offset: offset) else { return nil }
            offset += keyLenBytes

            if keyLen == 0 { break } // Separator

            let key = Data(data[offset..<(offset + Int(keyLen))])
            offset += Int(keyLen)

            guard let (valLen, valLenBytes) = VarInt.decode(data, offset: offset) else { return nil }
            offset += valLenBytes

            let value = Data(data[offset..<(offset + Int(valLen))])
            offset += Int(valLen)

            if key[0] == GlobalKey.unsignedTx.rawValue {
                result.unsignedTx = value
            }
        }

        // Count inputs/outputs from unsigned tx
        // (simplified - in production you'd parse the full tx)

        return result
    }

    // MARK: - Script pubkey builders for outputs

    /// P2WPKH output script: OP_0 <20-byte-hash>
    static func p2wpkhScriptPubKey(pubkeyHash: Data) -> Data {
        var script = Data()
        script.append(0x00) // OP_0
        script.append(0x14) // push 20 bytes
        script.append(pubkeyHash)
        return script
    }

    /// P2WSH output script: OP_0 <32-byte-hash>
    static func p2wshScriptPubKey(scriptHash: Data) -> Data {
        var script = Data()
        script.append(0x00) // OP_0
        script.append(0x20) // push 32 bytes
        script.append(scriptHash)
        return script
    }

    /// Create script pubkey from a bech32/bech32m address
    static func scriptPubKeyFromAddress(_ address: String, isTestnet: Bool) -> Data? {
        let hrp = isTestnet ? "tb" : "bc"
        guard let (version, program) = Bech32.segwitDecode(hrp: hrp, addr: address) else { return nil }

        var script = Data()
        if version == 0 {
            script.append(0x00)
        } else {
            script.append(OpCode.op_1.rawValue + UInt8(version - 1))
        }
        script.append(UInt8(program.count))
        script.append(program)
        return script
    }
}
