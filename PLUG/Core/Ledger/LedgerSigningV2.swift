import Foundation

// MARK: - Ledger Bitcoin App v2 PSBT Signing (Complete Implementation)
// Implements INS=0x04 SIGN_PSBT with merkleized PSBTv2 and multi-round client commands
// Based on Ledger Bitcoin App v2.0.6+ protocol
//
// MerkleTree + MerkleMap → MerkleTree.swift
// PSBTv2 map builders   → PSBTv2Builder.swift

struct LedgerSigningV2 {

    // MARK: - Client Command Interpreter

    class CommandInterpreter {
        var knownPreimages: [Data: Data] = [:] // SHA256(data) → data
        var knownTrees: [Data: MerkleTree] = [:] // root → tree
        var yieldedSignatures: [(Int, Data)] = []
        var queue: [Data] = [] // queued elements for GET_MORE_ELEMENTS

        func addPreimage(_ data: Data) {
            // Store under SHA256(data) for direct lookups
            knownPreimages[Crypto.sha256(data)] = data
            // Also store as Merkle leaf preimage: SHA256(0x00 + data) → (0x00 + data)
            // The Ledger requests preimages by their leaf hash which uses the 0x00 prefix
            let leafData = Data([0x00]) + data
            knownPreimages[Crypto.sha256(leafData)] = leafData
        }

        func addTree(_ tree: MerkleTree) {
            knownTrees[tree.root] = tree
        }

        func addMerkleMap(_ map: MerkleMap) {
            addTree(map.keysTree)
            addTree(map.valuesTree)
            // Add individual key/value data as preimages
            for key in map.sortedKeys { addPreimage(key) }
            for value in map.sortedValues { addPreimage(value) }
            // Add the commitment as preimage
            addPreimage(map.commitment)
        }

        /// Handle a client command from the Ledger, return response data
        func handleCommand(_ data: Data) -> Data? {
            guard !data.isEmpty else { return nil }
            let cmd = data[0]

            switch cmd {
            case 0x10: // YIELD
                // Format: [0x10] then device sends data in the response
                // The yielded data format: input_index(varint) + pubkey_augm_len(1) + pubkey_augm + signature
                // But the 0x10 command itself has no payload — the data IS the yield content
                if data.count >= 2 {
                    var offset = 1 // skip command byte
                    // Parse input_index as varint
                    var inputIndex = 0
                    if offset < data.count {
                        if let (idx, idxBytes) = decodeVarint(data, offset: offset) {
                            inputIndex = Int(idx)
                            offset += idxBytes
                        } else {
                            inputIndex = Int(data[offset])
                            offset += 1
                        }
                    }
                    // Parse pubkey_augm_len + pubkey_augm
                    var pubkeyAugm = Data()
                    if offset < data.count {
                        let pkLen = Int(data[offset])
                        offset += 1
                        if offset + pkLen <= data.count {
                            pubkeyAugm = Data(data[offset..<(offset + pkLen)])
                            offset += pkLen
                        }
                    }
                    // Rest is the signature
                    let sig = offset < data.count ? Data(data[offset...]) : Data()
                    #if DEBUG
                    print("[LedgerSign] YIELD: input \(inputIndex), pubkey \(pubkeyAugm.count)B, sig \(sig.count) bytes")
                    #endif
                    if !sig.isEmpty {
                        yieldedSignatures.append((inputIndex, sig))
                    }
                }
                return Data() // empty response to continue

            case 0x40: // GET_PREIMAGE
                guard data.count >= 34 else { return nil }
                let hash = Data(data[2..<34])
                #if DEBUG
                print("[LedgerSign] GET_PREIMAGE: \(hash.hex.prefix(16))...")
                #endif
                if let preimage = knownPreimages[hash] {
                    var resp = Data()
                    resp.append(encodeVarint(UInt64(preimage.count)))
                    let chunk = min(preimage.count, 250)
                    resp.append(UInt8(chunk))
                    resp.append(preimage.prefix(chunk))
                    if chunk < preimage.count {
                        // Queue remaining bytes as single-byte elements per Ledger spec
                        for i in chunk..<preimage.count {
                            queue.append(Data([preimage[preimage.startIndex + i]]))
                        }
                    }
                    return resp
                } else {
                    #if DEBUG
                    print("[LedgerSign] WARNING: preimage not found!")
                    #endif
                    var resp = Data()
                    resp.append(encodeVarint(0))
                    resp.append(0)
                    return resp
                }

            case 0x41: // GET_MERKLE_LEAF_PROOF
                guard data.count >= 33 else { return nil }
                let rootHash = Data(data[1..<33])
                var offset = 33
                guard let (_, tsBytesRead) = decodeVarint(data, offset: offset) else { return nil }
                offset += tsBytesRead
                guard let (leafIndex, _) = decodeVarint(data, offset: offset) else { return nil }

                #if DEBUG
                print("[LedgerSign] GET_MERKLE_LEAF_PROOF: root=\(rootHash.hex.prefix(16))... idx=\(leafIndex)")
                #endif

                if let tree = knownTrees[rootHash], Int(leafIndex) < tree.hashedLeaves.count {
                    let leafHash = tree.hashedLeaves[Int(leafIndex)]
                    let proof = tree.proof(forIndex: Int(leafIndex))

                    var resp = Data()
                    resp.append(leafHash) // 32 bytes
                    resp.append(UInt8(proof.count))
                    let inResp = min(proof.count, 7)
                    resp.append(UInt8(inResp))
                    for i in 0..<inResp {
                        resp.append(proof[i])
                    }
                    // Queue remaining proof elements
                    if proof.count > 7 {
                        for i in 7..<proof.count {
                            queue.append(proof[i])
                        }
                    }
                    return resp
                }
                // Fallback
                var resp = Data(repeating: 0, count: 32)
                resp.append(0)
                resp.append(0)
                return resp

            case 0x42: // GET_MERKLE_LEAF_INDEX
                guard data.count >= 65 else { return nil }
                let rootHash = Data(data[1..<33])
                let leafHash = Data(data[33..<65])

                #if DEBUG
                print("[LedgerSign] GET_MERKLE_LEAF_INDEX: root=\(rootHash.hex.prefix(16))...")
                #endif

                if let tree = knownTrees[rootHash],
                   let idx = tree.hashedLeaves.firstIndex(of: leafHash) {
                    var resp = Data([0x01])
                    resp.append(encodeVarint(UInt64(idx)))
                    return resp
                }
                return Data([0x00]) + encodeVarint(0)

            case 0xA0: // GET_MORE_ELEMENTS
                if queue.isEmpty {
                    return Data([0x00, 0x00])
                }
                let elementSize = queue.first?.count ?? 0
                // Send as many same-sized elements as fit in one response (max 255)
                let maxElements = min(queue.count, elementSize > 0 ? min(255, 253 / elementSize) : 0)
                var resp = Data()
                resp.append(UInt8(maxElements))
                resp.append(UInt8(elementSize))
                for _ in 0..<maxElements {
                    resp.append(queue.removeFirst())
                }
                return resp

            default:
                #if DEBUG
                print("[LedgerSign] Unknown command: 0x\(String(format: "%02X", cmd))")
                #endif
                return nil
            }
        }
    }

    // MARK: - Input address info for per-input BIP32 derivation

    struct InputAddressInfo {
        let change: UInt32   // 0 = receive, 1 = change
        let index: UInt32    // address index
        let publicKey: Data  // 33-byte compressed pubkey
        let value: UInt64    // UTXO value in satoshis
        let scriptPubKey: Data // scriptPubKey of the UTXO being spent
    }

    // MARK: - Wallet Policy Registration (V2)

    /// Register a wallet policy on the Ledger device.
    /// Returns (wallet_id, wallet_hmac). The HMAC must be stored for future signing.
    static func registerWallet(policy: WalletPolicyBuilder.Policy) async throws -> (walletId: Data, walletHmac: Data) {
        let interpreter = CommandInterpreter()

        // Build serialized wallet policy
        let serialized = serializeWalletPolicy(policy: policy)
        let walletId = Crypto.sha256(serialized)

        // Register preimages
        interpreter.addPreimage(serialized)
        interpreter.addPreimage(Data(policy.descriptorTemplate.utf8))

        // Build key info Merkle tree
        let keyInfoDatas = policy.keysInfo.map { Data($0.utf8) }
        let keyTree = MerkleTree(leaves: keyInfoDatas)
        interpreter.addTree(keyTree)
        for ki in keyInfoDatas { interpreter.addPreimage(ki) }

        // Build APDU: CLA=E1, INS=02, P1=00, P2=01
        var apduData = Data()
        apduData.append(encodeVarint(UInt64(serialized.count)))
        apduData.append(serialized)

        let apdu = LedgerProtocol.APDU(
            cla: LedgerV2.CLA,
            ins: 0x02,  // REGISTER_WALLET
            p1: 0x00,
            p2: 0x01,
            data: apduData
        )

        #if DEBUG
        print("[LedgerSign] Registering wallet: \(policy.name), descriptor: \(policy.descriptorTemplate)")
        #endif
        var response = try await LedgerManager.shared.sendAPDU(apdu, timeout: 120)

        // Multi-round client command loop (same as signPSBT)
        var rounds = 0
        while rounds < 500 {
            rounds += 1
            if response.isEmpty { break }

            guard let cmdResponse = interpreter.handleCommand(response) else {
                #if DEBUG
                print("[LedgerSign] Registration: failed to handle command at round \(rounds)")
                #endif
                break
            }

            let contAPDU = LedgerProtocol.APDU(
                cla: LedgerV2.CLA_CONTINUE,
                ins: LedgerV2.FrameworkINS.continueInterrupted.rawValue,
                p1: 0x00, p2: 0x00,
                data: cmdResponse
            )
            response = try await LedgerManager.shared.sendAPDU(contAPDU, timeout: 120)
        }

        // Response should be 64 bytes: wallet_id(32) + wallet_hmac(32)
        guard response.count >= 64 else {
            throw SignError.registrationFailed
        }
        let returnedId = Data(response[0..<32])
        let hmac = Data(response[32..<64])

        #if DEBUG
        print("[LedgerSign] Wallet registered! id=\(returnedId.hex.prefix(16))..., hmac=\(hmac.hex.prefix(16))...")
        #endif
        return (returnedId, hmac)
    }

    /// Compute wallet_id (SHA256 of serialized policy)
    static func computeWalletId(policy: WalletPolicyBuilder.Policy) -> Data {
        Crypto.sha256(serializeWalletPolicy(policy: policy))
    }

    /// Serialize wallet policy per V2 spec
    private static func serializeWalletPolicy(policy: WalletPolicyBuilder.Policy) -> Data {
        var data = Data()
        // Version byte
        data.append(0x02)
        // Name length + name
        let nameBytes = Data(policy.name.utf8)
        data.append(UInt8(nameBytes.count))
        data.append(nameBytes)
        // Descriptor template: length (varint) + SHA256 hash
        let descBytes = Data(policy.descriptorTemplate.utf8)
        data.append(encodeVarint(UInt64(descBytes.count)))
        data.append(Crypto.sha256(descBytes))
        // Number of keys (varint)
        data.append(encodeVarint(UInt64(policy.keysInfo.count)))
        // Merkle root of key info list
        let keyInfoDatas = policy.keysInfo.map { Data($0.utf8) }
        let keyTree = MerkleTree(leaves: keyInfoDatas)
        data.append(keyTree.root)
        return data
    }

    // MARK: - Sign PSBT with Registered Policy (P2WSH)

    /// Sign a PSBT using a registered wallet policy (for P2WSH contracts).
    /// Unlike signPSBT() which uses default wpkh(@0/**), this uses a custom policy + HMAC.
    static func signPSBTWithPolicy(
        psbt: Data,
        walletPolicy: WalletPolicyBuilder.Policy,
        walletId: Data,
        walletHmac: Data,
        witnessScript: Data,
        masterFP: Data,
        keyOrigin: String,
        inputAddressInfos: [InputAddressInfo] = [],
        isTestnet: Bool
    ) async throws -> [(index: Int, signature: Data)] {

        guard let parsed = PSBTBuilder.parsePSBT(psbt),
              let unsignedTx = parsed.unsignedTx else {
            throw SignError.invalidPSBT
        }

        let txInfo = parseTxDetails(unsignedTx)
        guard !txInfo.inputs.isEmpty else { throw SignError.invalidPSBT }

        let protocolVersion: UInt8 = 0x01
        let interpreter = CommandInterpreter()

        // Register the wallet policy serialization as preimage
        let walletPolicyData = serializeWalletPolicy(policy: walletPolicy)
        interpreter.addPreimage(walletPolicyData)

        // Register descriptor template
        interpreter.addPreimage(Data(walletPolicy.descriptorTemplate.utf8))

        // Register key info
        let keyInfoDatas = walletPolicy.keysInfo.map { Data($0.utf8) }
        let keyTree = MerkleTree(leaves: keyInfoDatas)
        interpreter.addTree(keyTree)
        for ki in keyInfoDatas { interpreter.addPreimage(ki) }

        // Build PSBTv2 maps
        let globalMap = buildPSBTv2GlobalMap(txInfo: txInfo)
        let isTaproot = walletPolicy.descriptorTemplate.hasPrefix("tr(")
        let inputMaps: [MerkleMap]
        if isTaproot {
            inputMaps = buildPSBTv2InputMapsForP2TR(
                txInfo: txInfo, psbt: psbt, masterFP: masterFP,
                keyOrigin: keyOrigin, keysInfo: walletPolicy.keysInfo,
                inputAddressInfos: inputAddressInfos
            )
        } else {
            inputMaps = buildPSBTv2InputMapsForP2WSH(
                txInfo: txInfo, psbt: psbt, masterFP: masterFP,
                keyOrigin: keyOrigin, keysInfo: walletPolicy.keysInfo,
                witnessScript: witnessScript,
                inputAddressInfos: inputAddressInfos
            )
        }
        let outputMaps = buildPSBTv2OutputMaps(txInfo: txInfo)

        // Register all maps
        interpreter.addMerkleMap(globalMap)
        for m in inputMaps { interpreter.addMerkleMap(m) }
        for m in outputMaps { interpreter.addMerkleMap(m) }

        // Build commitments
        let inputTree = MerkleTree(leaves: inputMaps.map { $0.commitment })
        interpreter.addTree(inputTree)
        for m in inputMaps { interpreter.addPreimage(m.commitment) }

        let outputTree = MerkleTree(leaves: outputMaps.map { $0.commitment })
        interpreter.addTree(outputTree)
        for m in outputMaps { interpreter.addPreimage(m.commitment) }

        // Build APDU
        var apduData = Data()
        apduData.append(encodeVarint(UInt64(globalMap.sortedKeys.count)))
        apduData.append(globalMap.keysTree.root)
        apduData.append(globalMap.valuesTree.root)
        apduData.append(encodeVarint(UInt64(inputMaps.count)))
        apduData.append(inputTree.root)
        apduData.append(encodeVarint(UInt64(outputMaps.count)))
        apduData.append(outputTree.root)
        apduData.append(walletId)
        apduData.append(walletHmac)  // NOT zeros — registered wallet

        let apdu = LedgerProtocol.APDU(
            cla: LedgerV2.CLA,
            ins: 0x04,  // SIGN_PSBT
            p1: 0x00,
            p2: protocolVersion,
            data: apduData
        )

        #if DEBUG
        print("[LedgerSign] Signing \(isTaproot ? "P2TR" : "P2WSH") with policy: \(walletPolicy.descriptorTemplate)")
        #endif
        var response = try await LedgerManager.shared.sendAPDU(apdu, timeout: 120)

        var rounds = 0
        while rounds < 500 {
            rounds += 1
            if response.isEmpty { break }

            guard let cmdResponse = interpreter.handleCommand(response) else {
                #if DEBUG
                print("[LedgerSign] P2WSH sign: failed at round \(rounds)")
                #endif
                break
            }

            let contAPDU = LedgerProtocol.APDU(
                cla: LedgerV2.CLA_CONTINUE,
                ins: LedgerV2.FrameworkINS.continueInterrupted.rawValue,
                p1: 0x00, p2: 0x00,
                data: cmdResponse
            )
            response = try await LedgerManager.shared.sendAPDU(contAPDU, timeout: 120)
        }

        guard !interpreter.yieldedSignatures.isEmpty else {
            throw SignError.noSignatures
        }

        #if DEBUG
        print("[LedgerSign] P2WSH: got \(interpreter.yieldedSignatures.count) signatures")
        #endif
        return interpreter.yieldedSignatures
    }

    // MARK: - Sign PSBT (standard P2WPKH — existing)

    static func signPSBT(
        psbt: Data,
        walletPolicy: String,
        keyOrigin: String,
        xpub: String,
        inputAddressInfos: [InputAddressInfo] = [],
        useProtocolV1: Bool = true
    ) async throws -> [(index: Int, signature: Data)] {

        // Parse our PSBTv1 to extract transaction data
        guard let parsed = PSBTBuilder.parsePSBT(psbt),
              let unsignedTx = parsed.unsignedTx else {
            throw SignError.invalidPSBT
        }

        // Extract transaction details
        let txInfo = parseTxDetails(unsignedTx)
        guard !txInfo.inputs.isEmpty else { throw SignError.invalidPSBT }

        // Get master fingerprint (saved during xpub retrieval)
        let masterFP: Data
        if let savedFP = KeychainStore.shared.load(forKey: KeychainStore.KeychainKey.ledgerMasterFingerprint.rawValue), savedFP.count >= 4 {
            masterFP = Data(savedFP.prefix(4))
            #if DEBUG
            print("[LedgerSign] Master fingerprint: \(masterFP.hex)")
            #endif
        } else {
            masterFP = getMasterFingerprint(xpub: xpub)
            #if DEBUG
            print("[LedgerSign] Master fingerprint (derived fallback): \(masterFP.hex)")
            #endif
        }

        let protocolVersion: UInt8 = useProtocolV1 ? 0x01 : 0x00
        #if DEBUG
        print("[LedgerSign] Using protocol v\(useProtocolV1 ? "1" : "0") (P2=0x\(String(format: "%02X", protocolVersion)))")
        #endif

        // Build the descriptor — v0: "wpkh(@0)", v1: "wpkh(@0/**)"
        let descriptor: String
        if useProtocolV1 {
            // Protocol v1: /** goes in descriptor template, NOT in key info
            descriptor = walletPolicy.hasSuffix("/**)") ? walletPolicy : walletPolicy.replacingOccurrences(of: "(@0)", with: "(@0/**)")
        } else {
            // Protocol v0: no /** in descriptor, it goes in key info instead
            descriptor = walletPolicy.replacingOccurrences(of: "/**)", with: ")")
        }
        #if DEBUG
        print("[LedgerSign] Descriptor template: \(descriptor)")
        #endif

        // Build PSBTv2 maps
        let globalMap = buildPSBTv2GlobalMap(txInfo: txInfo)
        let inputMaps = buildPSBTv2InputMaps(
            txInfo: txInfo, psbt: psbt, masterFP: masterFP,
            keyOrigin: keyOrigin, xpub: xpub,
            inputAddressInfos: inputAddressInfos
        )
        let outputMaps = buildPSBTv2OutputMaps(txInfo: txInfo)

        // Build wallet policy
        let walletPolicyData = buildWalletPolicyV2(
            descriptor: descriptor, keyOrigin: keyOrigin,
            xpub: xpub, masterFP: masterFP,
            useProtocolV1: useProtocolV1
        )
        let walletId = Crypto.sha256(walletPolicyData)

        // Set up command interpreter
        let interpreter = CommandInterpreter()

        // Register global map
        interpreter.addMerkleMap(globalMap)

        // Register input maps and their commitment tree
        let inputCommitments = inputMaps.map { $0.commitment }
        let inputCommitTree = MerkleTree(leaves: inputCommitments)
        interpreter.addTree(inputCommitTree)
        for map in inputMaps {
            interpreter.addMerkleMap(map)
            interpreter.addPreimage(map.commitment)
        }

        // Register output maps and their commitment tree
        let outputCommitments = outputMaps.map { $0.commitment }
        let outputCommitTree = MerkleTree(leaves: outputCommitments)
        interpreter.addTree(outputCommitTree)
        for map in outputMaps {
            interpreter.addMerkleMap(map)
            interpreter.addPreimage(map.commitment)
        }

        // Register wallet policy and its components as preimages
        interpreter.addPreimage(walletPolicyData)

        // Register the descriptor template string (Ledger requests it via GET_PREIMAGE)
        let descTemplateBytes = Data(descriptor.utf8)
        interpreter.addPreimage(descTemplateBytes)

        // Register the key info string
        let keyInfo = buildKeyInfo(
            masterFP: masterFP, keyOrigin: keyOrigin,
            xpub: xpub, useProtocolV1: useProtocolV1
        )
        interpreter.addPreimage(keyInfo)

        // Register the key info merkle tree
        let keyTree = MerkleTree(leaves: [keyInfo])
        interpreter.addTree(keyTree)

        // Build initial APDU data per official spec
        var apduData = Data()

        // Global map: size + keys merkle root + values merkle root
        apduData.append(encodeVarint(UInt64(globalMap.sortedKeys.count)))
        apduData.append(globalMap.keysTree.root)
        apduData.append(globalMap.valuesTree.root)

        // Input count + merkle root of input map commitments
        apduData.append(encodeVarint(UInt64(txInfo.inputs.count)))
        apduData.append(inputCommitTree.root)

        // Output count + merkle root of output map commitments
        apduData.append(encodeVarint(UInt64(txInfo.outputs.count)))
        apduData.append(outputCommitTree.root)

        // Wallet ID + HMAC (32 zero bytes for default wallet, no registration needed)
        apduData.append(walletId)
        apduData.append(Data(repeating: 0, count: 32))

        // Send initial SIGN_PSBT — P2 = protocol version (0x00 for v0, 0x01 for v1)
        let initialAPDU = LedgerProtocol.APDU(
            cla: LedgerV2.CLA,
            ins: LedgerV2.INS.signPSBT.rawValue,
            p1: 0x00,
            p2: protocolVersion,
            data: apduData
        )

        #if DEBUG
        print("[LedgerSign] === SIGN_PSBT DEBUG ===")
        #endif
        #if DEBUG
        print("[LedgerSign] Protocol: v\(useProtocolV1 ? "1" : "0"), descriptor: \(descriptor)")
        #endif
        #if DEBUG
        print("[LedgerSign] Global map: \(globalMap.sortedKeys.count) keys")
        #endif
        for (i, k) in globalMap.sortedKeys.enumerated() {
            #if DEBUG
            print("[LedgerSign]   key[\(i)]: \(k.hex) → val: \(globalMap.sortedValues[i].hex.prefix(20))...")
            #endif
        }
        #if DEBUG
        print("[LedgerSign] Global keys root: \(globalMap.keysTree.root.hex.prefix(16))...")
        #endif
        #if DEBUG
        print("[LedgerSign] Global vals root: \(globalMap.valuesTree.root.hex.prefix(16))...")
        #endif
        #if DEBUG
        print("[LedgerSign] Input maps: \(inputMaps.count)")
        #endif
        for (i, map) in inputMaps.enumerated() {
            #if DEBUG
            print("[LedgerSign]   input[\(i)]: \(map.sortedKeys.count) keys, commitment: \(map.commitment.hex.prefix(16))...")
            #endif
            for (j, k) in map.sortedKeys.enumerated() {
                #if DEBUG
                print("[LedgerSign]     key[\(j)]: \(k.hex) → val: \(map.sortedValues[j].hex.prefix(32))...")
                #endif
            }
        }
        #if DEBUG
        print("[LedgerSign] Input commit root: \(inputCommitTree.root.hex.prefix(16))...")
        #endif
        #if DEBUG
        print("[LedgerSign] Output maps: \(outputMaps.count)")
        #endif
        for (i, map) in outputMaps.enumerated() {
            #if DEBUG
            print("[LedgerSign]   output[\(i)]: \(map.sortedKeys.count) keys")
            #endif
        }
        #if DEBUG
        print("[LedgerSign] Output commit root: \(outputCommitTree.root.hex.prefix(16))...")
        #endif
        #if DEBUG
        print("[LedgerSign] Wallet ID: \(walletId.hex)")
        #endif
        #if DEBUG
        print("[LedgerSign] Key info: \(String(data: keyInfo, encoding: .ascii) ?? "?")")
        #endif
        #if DEBUG
        print("[LedgerSign] APDU total: \(apduData.count) bytes")
        #endif
        #if DEBUG
        print("[LedgerSign] Known preimages: \(interpreter.knownPreimages.count)")
        #endif
        for (hash, preimage) in interpreter.knownPreimages {
            let label = String(data: preimage, encoding: .ascii).map { "ASCII: \($0.prefix(60))" } ?? "hex: \(preimage.hex.prefix(40))"
            #if DEBUG
            print("[LedgerSign]   SHA256:\(hash.hex.prefix(16))... → \(label)")
            #endif
        }
        #if DEBUG
        print("[LedgerSign] Known trees: \(interpreter.knownTrees.count)")
        #endif
        #if DEBUG
        print("[LedgerSign] === END DEBUG ===")
        #endif

        // Use 120s timeout — user must confirm the transaction on the Ledger screen
        #if DEBUG
        print("[LedgerSign] Waiting for Ledger response (confirm on device)...")
        #endif
        var response = try await LedgerManager.shared.sendAPDU(initialAPDU, timeout: 120)

        // Multi-round client command loop
        var rounds = 0
        let maxRounds = 500

        while rounds < maxRounds {
            rounds += 1

            if response.isEmpty {
                // 0x9000 with empty data = done
                #if DEBUG
                print("[LedgerSign] Complete after \(rounds) rounds")
                #endif
                break
            }

            // Handle client command
            guard let cmdResponse = interpreter.handleCommand(response) else {
                #if DEBUG
                print("[LedgerSign] Failed to handle command at round \(rounds), response: \(response.hex)")
                #endif
                break
            }

            // Send continuation APDU
            let contAPDU = LedgerProtocol.APDU(
                cla: LedgerV2.CLA_CONTINUE,
                ins: LedgerV2.FrameworkINS.continueInterrupted.rawValue,
                p1: 0x00,
                p2: 0x00,
                data: cmdResponse
            )

            response = try await LedgerManager.shared.sendAPDU(contAPDU, timeout: 120)
        }

        guard !interpreter.yieldedSignatures.isEmpty else {
            throw SignError.noSignatures
        }

        #if DEBUG
        print("[LedgerSign] Got \(interpreter.yieldedSignatures.count) signatures")
        #endif
        return interpreter.yieldedSignatures
    }

    // MARK: - Parse unsigned transaction

    struct TxInput {
        let txid: Data     // 32 bytes internal order
        let vout: UInt32
        let sequence: UInt32
        let prevScriptPubKey: Data
        let prevValue: UInt64
    }

    struct TxOutput {
        let value: UInt64
        let scriptPubKey: Data
    }

    struct TxInfo {
        let version: UInt32
        let locktime: UInt32
        let inputs: [TxInput]
        let outputs: [TxOutput]
    }

    static func parseTxDetails(_ tx: Data) -> TxInfo {
        var offset = 0
        let version = readUInt32LE(tx, offset: &offset)

        guard let (inputCount, icBytes) = VarInt.decode(tx, offset: offset) else {
            return TxInfo(version: version, locktime: 0, inputs: [], outputs: [])
        }
        offset += icBytes

        var inputs: [TxInput] = []
        for _ in 0..<Int(inputCount) {
            let txid = Data(tx[offset..<(offset + 32)])
            offset += 32
            let vout = readUInt32LE(tx, offset: &offset)
            guard let (scriptLen, slBytes) = VarInt.decode(tx, offset: offset) else { break }
            offset += slBytes + Int(scriptLen)
            let seq = readUInt32LE(tx, offset: &offset)
            inputs.append(TxInput(txid: txid, vout: vout, sequence: seq, prevScriptPubKey: Data(), prevValue: 0))
        }

        guard let (outputCount, ocBytes) = VarInt.decode(tx, offset: offset) else {
            return TxInfo(version: version, locktime: 0, inputs: inputs, outputs: [])
        }
        offset += ocBytes

        var outputs: [TxOutput] = []
        for _ in 0..<Int(outputCount) {
            let value = readUInt64LE(tx, offset: &offset)
            guard let (spkLen, spkBytes) = VarInt.decode(tx, offset: offset) else { break }
            offset += spkBytes
            let spk = Data(tx[offset..<(offset + Int(spkLen))])
            offset += Int(spkLen)
            outputs.append(TxOutput(value: value, scriptPubKey: spk))
        }

        let locktime = readUInt32LE(tx, offset: &offset)

        return TxInfo(version: version, locktime: locktime, inputs: inputs, outputs: outputs)
    }

    // MARK: - Wallet Policy

    static func buildWalletPolicyV2(
        descriptor: String, keyOrigin: String,
        xpub: String, masterFP: Data,
        useProtocolV1: Bool = true
    ) -> Data {
        var data = Data()

        if useProtocolV1 {
            // Protocol v1 (firmware >= 2.1.0): version byte = 0x02
            data.append(0x02)

            // Wallet name length: 0 (default wallet, unnamed)
            data.append(0x00)

            // v1: descriptor template length + SHA256 hash (NOT raw string)
            let descBytes = Data(descriptor.utf8)
            data.append(encodeVarint(UInt64(descBytes.count)))
            data.append(Crypto.sha256(descBytes)) // 32-byte hash

            // Number of keys: 1
            data.append(encodeVarint(1))

            // Merkle root of key info list
            let keyInfo = buildKeyInfo(masterFP: masterFP, keyOrigin: keyOrigin, xpub: xpub, useProtocolV1: true)
            let keyTree = MerkleTree(leaves: [keyInfo])
            data.append(keyTree.root)
        } else {
            // Protocol v0 (firmware < 2.1.0): version byte = 0x01
            data.append(0x01)

            // Wallet name length: 0
            data.append(0x00)

            // v0: descriptor template as raw ASCII string
            let descBytes = Data(descriptor.utf8)
            data.append(encodeVarint(UInt64(descBytes.count)))
            data.append(descBytes)

            // Number of keys: 1
            data.append(encodeVarint(1))

            // Merkle root of key info list
            let keyInfo = buildKeyInfo(masterFP: masterFP, keyOrigin: keyOrigin, xpub: xpub, useProtocolV1: false)
            let keyTree = MerkleTree(leaves: [keyInfo])
            data.append(keyTree.root)
        }

        let walletId = Crypto.sha256(data)
        #if DEBUG
        print("[LedgerSign] Wallet policy: version=0x\(String(format: "%02x", data[0])), desc=\"\(descriptor)\", wallet_id=\(walletId.hex.prefix(16))...")
        #endif
        #if DEBUG
        print("[LedgerSign] Wallet policy hex: \(data.hex)")
        #endif

        return data
    }

    static func buildKeyInfo(masterFP: Data, keyOrigin: String, xpub: String, useProtocolV1: Bool = true) -> Data {
        let keyStr: String
        if useProtocolV1 {
            // Protocol v1: "[fingerprint/path]xpub" — NO /** suffix (it's in the descriptor template)
            keyStr = "[\(masterFP.hex)/\(keyOrigin)]\(xpub)"
        } else {
            // Protocol v0: "[fingerprint/path]xpub/**" — WITH /** suffix
            keyStr = "[\(masterFP.hex)/\(keyOrigin)]\(xpub)/**"
        }
        #if DEBUG
        print("[LedgerSign] Key info string: \(keyStr)")
        #endif
        return Data(keyStr.utf8)
    }

    static func getMasterFingerprint(xpub: String) -> Data {
        // Parse xpub to get fingerprint, or derive from public key hash
        if let epk = ExtendedPublicKey.fromBase58(xpub) {
            return epk.fingerprint
        }
        // Fallback: hash the xpub string
        let hash = Crypto.hash160(Data(xpub.utf8))
        return Data(hash.prefix(4))
    }

    // MARK: - Helpers

    static func uint32LEData(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 4)
    }

    static func uint64LEData(_ v: UInt64) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 8)
    }

    static func readUInt32LE(_ data: Data, offset: inout Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let v = UInt32(data[offset]) | (UInt32(data[offset+1]) << 8) |
                (UInt32(data[offset+2]) << 16) | (UInt32(data[offset+3]) << 24)
        offset += 4
        return v
    }

    static func readUInt64LE(_ data: Data, offset: inout Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(data[offset + i]) << (i * 8) }
        offset += 8
        return v
    }

    // MARK: - Errors

    enum SignError: LocalizedError {
        case invalidPSBT
        case noSignatures
        case registrationFailed
        case ledgerError(String)

        var errorDescription: String? {
            switch self {
            case .invalidPSBT: return "Invalid PSBT"
            case .noSignatures: return "No signatures received from Ledger"
            case .registrationFailed: return "Wallet policy registration failed"
            case .ledgerError(let msg): return "Ledger error: \(msg)"
            }
        }
    }
}

// MARK: - Varint helpers (standalone to avoid conflicts)

private func encodeVarint(_ value: UInt64) -> Data {
    VarInt.encode(value)
}

private func decodeVarint(_ data: Data, offset: Int) -> (UInt64, Int)? {
    VarInt.decode(data, offset: offset)
}
