import Foundation

// MARK: - PSBTv2 Map Building Functions
// Extracted from LedgerSigningV2.swift

extension LedgerSigningV2 {

    // MARK: - Build PSBTv2 Global Map

    static func buildPSBTv2GlobalMap(txInfo: TxInfo) -> MerkleMap {
        var keys: [Data] = []
        var values: [Data] = []

        // TX_VERSION (0x02)
        keys.append(Data([0x02]))
        values.append(uint32LEData(txInfo.version))

        // FALLBACK_LOCKTIME (0x03)
        keys.append(Data([0x03]))
        values.append(uint32LEData(txInfo.locktime))

        // INPUT_COUNT (0x04)
        keys.append(Data([0x04]))
        values.append(VarInt.encode(UInt64(txInfo.inputs.count)))

        // OUTPUT_COUNT (0x05)
        keys.append(Data([0x05]))
        values.append(VarInt.encode(UInt64(txInfo.outputs.count)))

        // PSBT_GLOBAL_VERSION (0xfb) = 2
        keys.append(Data([0xFB]))
        values.append(uint32LEData(2))

        return MerkleMap(keys: keys, values: values)
    }

    // MARK: - Build PSBTv2 Input Maps (P2WPKH — standard)

    static func buildPSBTv2InputMaps(
        txInfo: TxInfo, psbt: Data, masterFP: Data,
        keyOrigin: String, xpub: String,
        inputAddressInfos: [InputAddressInfo] = []
    ) -> [MerkleMap] {
        // Parse the PSBT to extract witness UTXOs from input sections
        let parsed = PSBTBuilder.parsePSBT(psbt)

        // Fallback: derive pubkey at m/84'/0'/0'/0/0 if no per-input info provided
        var fallbackPubkey = Data()
        if inputAddressInfos.isEmpty {
            if let epk = ExtendedPublicKey.fromBase58(xpub),
               let change0 = epk.deriveChild(index: 0),
               let addr0 = change0.deriveChild(index: 0) {
                fallbackPubkey = addr0.key
            }
        }

        // Parse coin_type from keyOrigin once (not per-input)
        let originParts = keyOrigin.split(separator: "/")
        let coinType: UInt32 = originParts.count >= 2 ? (UInt32(originParts[1].replacingOccurrences(of: "'", with: "")) ?? 0) : 0

        return txInfo.inputs.enumerated().map { (i, input) in
            var keys: [Data] = []
            var values: [Data] = []

            // TODO: Add NON_WITNESS_UTXO (key 0x00) with the full previous transaction
            // for BIP-174 compliance. Ledger shows a warning without it for segwit v0.
            // Required for P2WSH contract spending (Vault, Inheritance, etc.)

            // WITNESS_UTXO (0x01) — CRITICAL: Ledger needs this to validate input amount
            // Format: value(8 bytes LE) + scriptPubKey(varint_len + script)
            var witnessUtxo = Data()
            if i < inputAddressInfos.count && !inputAddressInfos[i].scriptPubKey.isEmpty {
                // Build from InputAddressInfo (preferred — has correct value + scriptPubKey)
                let info = inputAddressInfos[i]
                witnessUtxo.append(uint64LEData(info.value))
                witnessUtxo.append(VarInt.encode(UInt64(info.scriptPubKey.count)))
                witnessUtxo.append(info.scriptPubKey)
                #if DEBUG
                print("[LedgerSign] Input[\(i)] WITNESS_UTXO: value=\(info.value) sats, spk=\(info.scriptPubKey.hex)")
                #endif
            } else if parsed != nil {
                // Fallback: try to extract from PSBTv1
                witnessUtxo = extractWitnessUtxoFromPSBT(psbt, inputIndex: i)
            }

            if !witnessUtxo.isEmpty {
                keys.append(Data([0x01]))
                values.append(witnessUtxo)
            } else {
                #if DEBUG
                print("[LedgerSign] WARNING: Input[\(i)] missing WITNESS_UTXO — Ledger will reject!")
                #endif
            }

            // BIP32_DERIVATION (0x06) + pubkey — tells Ledger which key to sign with
            // Use per-input address info if available, otherwise fallback to index 0
            let pubkey: Data
            let change: UInt32
            let addrIndex: UInt32

            if i < inputAddressInfos.count {
                let info = inputAddressInfos[i]
                pubkey = info.publicKey
                change = info.change
                addrIndex = info.index
            } else {
                pubkey = fallbackPubkey
                change = 0
                addrIndex = 0
            }

            if !pubkey.isEmpty {
                var bip32Key = Data([0x06])
                bip32Key.append(pubkey)
                keys.append(bip32Key)

                // Value: master_fingerprint(4) + path_elements(4 each, LE per BIP174)
                // Full path: m/84'/coin_type'/0'/change/index
                let pathComponents: [UInt32] = [
                    84 | 0x80000000,        // 84'
                    coinType | 0x80000000,   // coin_type'
                    0 | 0x80000000,          // 0'
                    change,                  // 0 (receive) or 1 (change)
                    addrIndex                // address index
                ]

                var bip32Value = masterFP
                for component in pathComponents {
                    var le = component.littleEndian
                    bip32Value.append(Data(bytes: &le, count: 4))
                }
                values.append(bip32Value)
                #if DEBUG
                print("[LedgerSign] Input[\(i)] BIP32: pubkey=\(pubkey.hex.prefix(16))..., path=m/84'/\(coinType)'/0'/\(change)/\(addrIndex)")
                #endif
            }

            // PREVIOUS_TXID (0x0e)
            keys.append(Data([0x0E]))
            values.append(input.txid)

            // OUTPUT_INDEX (0x0f)
            keys.append(Data([0x0F]))
            values.append(uint32LEData(input.vout))

            // SEQUENCE (0x10)
            keys.append(Data([0x10]))
            values.append(uint32LEData(input.sequence))

            return MerkleMap(keys: keys, values: values)
        }
    }

    // MARK: - Build PSBTv2 Input Maps for P2WSH

    /// Build PSBTv2 input maps for P2WSH (includes WITNESS_SCRIPT key 0x05)
    static func buildPSBTv2InputMapsForP2WSH(
        txInfo: TxInfo, psbt: Data, masterFP: Data,
        keyOrigin: String, keysInfo: [String],
        witnessScript: Data,
        inputAddressInfos: [InputAddressInfo] = []
    ) -> [MerkleMap] {
        let originParts = keyOrigin.split(separator: "/")
        let coinType: UInt32 = originParts.count >= 2 ? (UInt32(originParts[1].replacingOccurrences(of: "'", with: "")) ?? 0) : 0

        return txInfo.inputs.enumerated().map { (i, input) in
            var keys: [Data] = []
            var values: [Data] = []

            // WITNESS_UTXO (0x01)
            if i < inputAddressInfos.count && !inputAddressInfos[i].scriptPubKey.isEmpty {
                let info = inputAddressInfos[i]
                var witnessUtxo = Data()
                witnessUtxo.append(uint64LEData(info.value))
                witnessUtxo.append(VarInt.encode(UInt64(info.scriptPubKey.count)))
                witnessUtxo.append(info.scriptPubKey)
                keys.append(Data([0x01]))
                values.append(witnessUtxo)
            }

            // WITNESS_SCRIPT (0x05) — P2WSH specific
            keys.append(Data([0x05]))
            values.append(witnessScript)

            // BIP32_DERIVATION (0x06) for internal key
            if i < inputAddressInfos.count {
                let info = inputAddressInfos[i]
                if !info.publicKey.isEmpty {
                    var bip32Key = Data([0x06])
                    bip32Key.append(info.publicKey)
                    keys.append(bip32Key)

                    var bip32Value = masterFP
                    let pathComponents: [UInt32] = [
                        84 | 0x80000000,
                        coinType | 0x80000000,
                        0 | 0x80000000,
                        info.change,
                        info.index
                    ]
                    for component in pathComponents {
                        var le = component.littleEndian
                        bip32Value.append(Data(bytes: &le, count: 4))
                    }
                    values.append(bip32Value)
                }
            }

            // PREVIOUS_TXID (0x0E)
            keys.append(Data([0x0E]))
            values.append(input.txid)

            // OUTPUT_INDEX (0x0F)
            keys.append(Data([0x0F]))
            values.append(uint32LEData(input.vout))

            // SEQUENCE (0x10)
            keys.append(Data([0x10]))
            values.append(uint32LEData(input.sequence))

            return MerkleMap(keys: keys, values: values)
        }
    }

    // MARK: - PSBTv2 Input Maps for Taproot (P2TR)

    static func buildPSBTv2InputMapsForP2TR(
        txInfo: TxInfo, psbt: Data, masterFP: Data,
        keyOrigin: String, keysInfo: [String],
        inputAddressInfos: [InputAddressInfo] = []
    ) -> [MerkleMap] {
        let originParts = keyOrigin.split(separator: "/")
        let purpose: UInt32 = originParts.count >= 1 ? (UInt32(originParts[0].replacingOccurrences(of: "'", with: "")) ?? 84) : 84
        let coinType: UInt32 = originParts.count >= 2 ? (UInt32(originParts[1].replacingOccurrences(of: "'", with: "")) ?? 0) : 0

        return txInfo.inputs.enumerated().map { (i, input) in
            var keys: [Data] = []
            var values: [Data] = []

            // WITNESS_UTXO (0x01)
            if i < inputAddressInfos.count && !inputAddressInfos[i].scriptPubKey.isEmpty {
                let info = inputAddressInfos[i]
                var witnessUtxo = Data()
                witnessUtxo.append(uint64LEData(info.value))
                witnessUtxo.append(VarInt.encode(UInt64(info.scriptPubKey.count)))
                witnessUtxo.append(info.scriptPubKey)
                keys.append(Data([0x01]))
                values.append(witnessUtxo)
            }

            // NO WITNESS_SCRIPT (0x05) for Taproot — the Ledger derives the script from the wallet policy

            // TAP_BIP32_DERIVATION (0x16) — x-only pubkey (32 bytes)
            if i < inputAddressInfos.count {
                let info = inputAddressInfos[i]
                if info.publicKey.count >= 33 {
                    // x-only key = last 32 bytes of compressed pubkey
                    let xOnlyKey = info.publicKey.suffix(32)

                    var tapBip32Key = Data([0x16])
                    tapBip32Key.append(xOnlyKey)
                    keys.append(tapBip32Key)

                    // Value: num_leaf_hashes (varint 0 for key-path) + fingerprint + path
                    var tapBip32Value = Data()
                    tapBip32Value.append(0x00) // 0 leaf hashes (key-path spend)

                    tapBip32Value.append(masterFP)
                    let pathComponents: [UInt32] = [
                        purpose | 0x80000000,
                        coinType | 0x80000000,
                        0 | 0x80000000,
                        info.change,
                        info.index
                    ]
                    for component in pathComponents {
                        var le = component.littleEndian
                        tapBip32Value.append(Data(bytes: &le, count: 4))
                    }
                    values.append(tapBip32Value)
                }
            }

            // PREVIOUS_TXID (0x0E)
            keys.append(Data([0x0E]))
            values.append(input.txid)

            // OUTPUT_INDEX (0x0F)
            keys.append(Data([0x0F]))
            values.append(uint32LEData(input.vout))

            // SEQUENCE (0x10)
            keys.append(Data([0x10]))
            values.append(uint32LEData(input.sequence))

            return MerkleMap(keys: keys, values: values)
        }
    }

    // MARK: - Build PSBTv2 Output Maps

    static func buildPSBTv2OutputMaps(txInfo: TxInfo) -> [MerkleMap] {
        return txInfo.outputs.map { output in
            var keys: [Data] = []
            var values: [Data] = []

            // AMOUNT (0x03)
            keys.append(Data([0x03]))
            values.append(uint64LEData(output.value))

            // SCRIPT (0x04)
            keys.append(Data([0x04]))
            values.append(output.scriptPubKey)

            return MerkleMap(keys: keys, values: values)
        }
    }

    // MARK: - Extract Witness UTXO from PSBTv1

    /// Extract witness UTXO from our PSBTv1 format
    static func extractWitnessUtxoFromPSBT(_ psbt: Data, inputIndex: Int) -> Data {
        // Parse PSBT to find the witnessUtxo for this input
        // Our PSBTBuilder format: after global map (key 0x00 = unsigned tx),
        // then input maps (key 0x01 = witnessUtxo, key 0x05 = witnessScript)
        guard psbt.count >= 5 else { return Data() }

        var offset = 5 // skip magic "psbt\xff"

        // Skip global map
        while offset < psbt.count {
            guard let (keyLen, keyLenBytes) = VarInt.decode(psbt, offset: offset) else { return Data() }
            offset += keyLenBytes
            if keyLen == 0 { break } // separator
            // Skip key
            offset += Int(keyLen)
            // Skip value
            guard let (valLen, valLenBytes) = VarInt.decode(psbt, offset: offset) else { return Data() }
            offset += valLenBytes + Int(valLen)
        }

        // Parse input maps
        for inputIdx in 0...inputIndex {
            while offset < psbt.count {
                guard let (keyLen, keyLenBytes) = VarInt.decode(psbt, offset: offset) else { return Data() }
                offset += keyLenBytes
                if keyLen == 0 { break } // separator between inputs

                let keyStart = offset
                offset += Int(keyLen)

                guard let (valLen, valLenBytes) = VarInt.decode(psbt, offset: offset) else { return Data() }
                offset += valLenBytes

                if inputIdx == inputIndex && psbt[keyStart] == 0x01 && keyLen == 1 {
                    // Found WITNESS_UTXO for our input
                    return Data(psbt[offset..<(offset + Int(valLen))])
                }

                offset += Int(valLen)
            }
        }

        return Data()
    }
}
