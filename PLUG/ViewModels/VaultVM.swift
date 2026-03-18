import Foundation

@MainActor
final class VaultVM: ObservableObject {

    @Published var name: String = ""
    @Published var lockBlockHeight: String = ""
    @Published var amount: String = ""
    @Published var useTaproot: Bool = false
    @Published var keyIndex: UInt32 = 0
    @Published var contracts: [Contract] = []
    @Published var currentBlockHeight: Int = 0
    @Published var isLoading = false
    @Published var error: String?
    @Published var createdContract: Contract?

    // Spend properties
    /// Funded balances for each contract address (fetched on refresh)
    @Published var fundedAmounts: [String: UInt64] = [:]  // address → balance in sats
    /// Minimum confirmation count for each contract address
    @Published var confirmations: [String: Int] = [:]  // address → min confirmations

    @Published var spendAddress: String = ""
    @Published var spendFeeRate: Double = 2.0
    @Published var spendResult: String?
    @Published var spendError: String?
    @Published var isSpending = false
    @Published var selectedContract: Contract?
    @Published var spendUTXOs: [UTXO] = []
    @Published var estimatedFee: UInt64 = 0

    // Pre-broadcast review properties
    @Published var psbtForReview: String?   // base64 PSBT for export
    @Published var txForReview: String?     // hex transaction ready to broadcast

    var isTestnet: Bool { NetworkConfig.shared.isTestnet }

    var vaults: [Contract] {
        ContractStore.shared.vaults.filter { $0.isTestnet == isTestnet }
    }

    func refresh() async {
        isLoading = true
        do {
            currentBlockHeight = try await MempoolAPI.shared.getBlockHeight()
            contracts = vaults
            let result = await ContractSpendCoordinator.refreshBalances(
                contracts: contracts, blockHeight: currentBlockHeight
            )
            fundedAmounts = result.amounts
            confirmations = result.confirmations
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Get funded amount for a contract (0 if not yet fetched)
    func fundedAmount(for contract: Contract) -> UInt64 {
        fundedAmounts[contract.address] ?? 0
    }

    /// Progress toward target (0.0 to 1.0)
    func progress(for contract: Contract) -> Double {
        guard contract.amount > 0 else { return 0 }
        return min(1.0, Double(fundedAmount(for: contract)) / Double(contract.amount))
    }

    func blocksRemaining(for contract: Contract) -> Int {
        guard let lockHeight = contract.lockBlockHeight else { return 0 }
        return max(0, lockHeight - currentBlockHeight)
    }

    func isUnlocked(_ contract: Contract) -> Bool {
        guard let lockHeight = contract.lockBlockHeight else { return false }
        return currentBlockHeight >= lockHeight
    }

    /// Create a new vault contract
    func create() async {
        // Prevent double creation
        guard !isLoading else { return }

        guard !name.isEmpty,
              let lockHeight = Int(lockBlockHeight), lockHeight > currentBlockHeight,
              let amountSats = UInt64(amount), amountSats > 0 else {
            error = "Invalid parameters"
            return
        }

        isLoading = true

        // Get public key from xpub
        guard let xpubStr = KeychainStore.shared.loadXpub(isTestnet: isTestnet),
              let xpub = ExtendedPublicKey.fromBase58(xpubStr) else {
            error = "Unable to derive public key"
            isLoading = false
            return
        }

        // Derive key off main thread (EC arithmetic)
        let isTest = isTestnet
        let lh = lockHeight
        let taproot = useTaproot
        let kIdx = keyIndex

        let contract: Contract

        if taproot {
            // Taproot (P2TR) vault — key-path + script-path with CLTV
            guard let trResult = await Task.detached(priority: .userInitiated) { () -> (Data, Data, Data, String)? in
                guard let derivedKey = xpub.derivePath([0, kIdx]) else { return nil }
                let internalKey = Secp256k1.xOnly(derivedKey.key)
                let script = ScriptBuilder.vaultScript(locktime: Int64(lh), pubkey: derivedKey.key)
                let merkleRoot = TaprootBuilder.computeMerkleRoot(scripts: [script.script])
                guard let tweakedKey = TaprootBuilder.tweakPublicKey(internalKey: internalKey, merkleRoot: merkleRoot),
                      let address = TaprootBuilder.taprootAddress(internalKey: internalKey, scripts: [script.script], isTestnet: isTest)
                else { return nil }
                return (internalKey, tweakedKey, script.script, address)
            }.value else {
                error = "Unable to generate Taproot address"
                isLoading = false
                return
            }

            let (internalKey, tweakedKey, scriptData, address) = trResult
            let merkleRoot = TaprootBuilder.computeMerkleRoot(scripts: [scriptData])
            contract = Contract.newTaprootVault(
                name: name,
                internalKey: internalKey,
                tweakedKey: tweakedKey,
                address: address,
                lockBlockHeight: lockHeight,
                amount: amountSats,
                isTestnet: isTestnet,
                script: scriptData,
                merkleRoot: merkleRoot,
                scripts: [scriptData]
            )
        } else {
            // P2WSH vault (legacy SegWit)
            guard let result = await Task.detached(priority: .userInitiated) { () -> (Data, Data, String)? in
                guard let derivedKey = xpub.derivePath([0, kIdx]) else { return nil }
                let script = ScriptBuilder.vaultScript(locktime: Int64(lh), pubkey: derivedKey.key)
                guard let address = script.p2wshAddress(isTestnet: isTest) else { return nil }
                return (script.script, script.witnessScriptHash, address)
            }.value else {
                error = "Unable to generate address"
                isLoading = false
                return
            }

            let (scriptData, witnessHash, address) = result
            contract = Contract.newVault(
                name: name,
                script: scriptData,
                witnessScript: witnessHash,
                address: address,
                lockBlockHeight: lockHeight,
                amount: amountSats,
                isTestnet: isTestnet
            )
        }

        ContractStore.shared.add(contract)
        createdContract = contract
        contracts = vaults

        // Reset form
        self.name = ""
        lockBlockHeight = ""
        amount = ""
        isLoading = false
    }

    func delete(id: String) {
        ContractStore.shared.delete(id: id)
        contracts = vaults
    }

    // MARK: - Spend

    /// Load UTXOs for a contract and estimate fee
    func prepareSpend(contract: Contract) async {
        selectedContract = contract
        spendError = nil
        spendResult = nil
        spendAddress = ""

        do {
            spendUTXOs = try await MempoolAPI.shared.getAddressUTXOs(address: contract.address)
            updateEstimatedFee()
        } catch {
            spendError = error.localizedDescription
        }
    }

    /// Update fee estimate when fee rate changes
    func updateEstimatedFee() {
        guard let contract = selectedContract, !spendUTXOs.isEmpty else {
            estimatedFee = 0
            return
        }
        estimatedFee = SpendManager.estimateFee(
            contract: contract,
            utxoCount: spendUTXOs.count,
            outputCount: 1,
            feeRate: spendFeeRate
        )
    }

    var spendableBalance: UInt64 {
        spendUTXOs.reduce(0) { $0 + $1.value }
    }

    var netSpendAmount: UInt64 {
        let balance = spendableBalance
        return balance > estimatedFee ? balance - estimatedFee : 0
    }

    /// Spend from a vault contract.
    /// Builds, signs, and finalizes the transaction but does NOT broadcast.
    /// Sets `txForReview` and `psbtForReview` so the user can review before calling `confirmBroadcast()`.
    func spendVault() async {
        guard let contract = selectedContract else {
            spendError = "No contract selected"
            return
        }
        guard !spendAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            spendError = "Destination address required"
            return
        }
        guard isUnlocked(contract) else {
            spendError = SpendManager.SpendError.timelockNotReached.localizedDescription
            return
        }

        isSpending = true
        spendError = nil
        spendResult = nil
        txForReview = nil
        psbtForReview = nil

        do {
            let utxos = try await ContractSpendCoordinator.fetchAndValidateUTXOs(
                contract: contract, feeRate: spendFeeRate
            )

            let address = spendAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            let psbtData: Data

            if contract.isTaproot {
                // Taproot key-path: build simple PSBT without witnessScript or locktime
                psbtData = try SpendManager.buildTaprootKeyPathSpendPSBT(
                    contract: contract, utxos: utxos,
                    destinationAddress: address,
                    feeRate: spendFeeRate, isTestnet: isTestnet
                )
            } else {
                psbtData = try SpendManager.buildVaultSpendPSBT(
                    contract: contract, utxos: utxos,
                    destinationAddress: address,
                    feeRate: spendFeeRate, isTestnet: isTestnet
                )
            }

            psbtForReview = SpendManager.exportPSBTBase64(psbtData)

            // Build input address info for BIP32 derivation in PSBT
            let witnessScriptData = Data(hex: contract.script) ?? Data()
            let pubkey: Data
            if let xpubStr = KeychainStore.shared.loadXpub(isTestnet: isTestnet),
               let epk = ExtendedPublicKey.fromBase58(xpubStr),
               let child0 = epk.deriveChild(index: 0),
               let child00 = child0.deriveChild(index: 0) {
                pubkey = child00.key
            } else {
                pubkey = Data()
            }

            let spk: Data
            if contract.isTaproot,
               let scriptPubKeyHex = contract.scriptPubKey,
               let scriptPubKeyData = Data(hex: scriptPubKeyHex) {
                // P2TR: use the actual scriptPubKey from the contract (OP_1 <tweaked-key>)
                spk = scriptPubKeyData
            } else if contract.isTaproot {
                // Fallback: derive P2TR scriptPubKey from address
                spk = PSBTBuilder.scriptPubKeyFromAddress(contract.address, isTestnet: isTestnet) ?? Data()
            } else {
                // P2WSH: OP_0 <SHA256(witnessScript)>
                spk = PSBTBuilder.p2wshScriptPubKey(scriptHash: Crypto.sha256(witnessScriptData))
            }
            let inputInfos = utxos.map { utxo in
                LedgerSigningV2.InputAddressInfo(
                    change: 0, index: 0,
                    publicKey: pubkey,
                    value: utxo.value,
                    scriptPubKey: spk
                )
            }

            // Sign + finalize but do NOT broadcast (2-stage review)
            let txHex: String
            let updatedContract: Contract

            if contract.isTaproot {
                // Taproot key-path spend: use default tr(@0/**) policy (no registration needed).
                // Key-path bypasses all script conditions (timelock doesn't apply).
                let result = try await LedgerSigningV2.signPSBT(
                    psbt: psbtData,
                    walletPolicy: "tr(@0/**)",
                    keyOrigin: "84'/\(KeychainStore.shared.loadString(forKey: KeychainStore.KeychainKey.ledgerCoinType.rawValue) ?? "1")'/0'",
                    xpub: KeychainStore.shared.loadString(forKey: KeychainStore.KeychainKey.ledgerOriginalXpub.rawValue)
                        ?? KeychainStore.shared.loadXpub(isTestnet: isTestnet) ?? "",
                    inputAddressInfos: inputInfos
                )

                let signatures = result.map { $0.signature }
                // Taproot key-path witness: just the 64-byte Schnorr signature
                let witnessStacks: [[Data]] = signatures.map { sig in
                    SpendManager.taprootKeyPathWitness(signature: sig)
                }

                guard let finalTx = SpendManager.finalizePSBT(
                    psbtData: psbtData,
                    witnessStacks: witnessStacks
                ) else {
                    throw SpendManager.SpendError.signingFailed
                }

                txHex = SpendManager.extractTransactionHex(finalTx)
                updatedContract = contract
            } else {
                // P2WSH script-path spend
                let result = try await ContractSpendCoordinator.signAndFinalize(
                    psbtData: psbtData, contract: contract,
                    spendPath: .vaultSpend,
                    inputAddressInfos: inputInfos,
                    buildWitness: SpendManager.vaultWitness,
                    isTestnet: isTestnet
                )
                txHex = result.txHex
                updatedContract = result.updatedContract
            }

            if updatedContract.walletPolicyHmac != contract.walletPolicyHmac {
                selectedContract = updatedContract
            }

            txForReview = txHex

        } catch {
            spendError = error.localizedDescription
        }

        isSpending = false
    }

    /// Broadcast the previously signed transaction after user confirmation.
    func confirmBroadcast() async {
        guard let txHex = txForReview else {
            spendError = "No transaction to broadcast"
            return
        }

        isSpending = true
        spendError = nil

        do {
            let txid = try await SpendManager.broadcast(txHex: txHex)
            spendResult = txid
            txForReview = nil
            psbtForReview = nil

            // Update contract state
            if var contract = selectedContract {
                contract.isUnlocked = true
                contract.txid = txid
                ContractStore.shared.update(contract)
                contracts = vaults
            }
        } catch {
            spendError = error.localizedDescription
        }

        isSpending = false
    }
}
