import Foundation

@MainActor
final class VaultVM: ObservableObject, ContractVM {

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

    @Published var fundedAmounts: [String: UInt64] = [:]
    @Published var confirmations: [String: Int] = [:]

    @Published var spendAddress: String = ""
    @Published var spendFeeRate: Double = 2.0
    @Published var spendResult: String?
    @Published var spendError: String?
    @Published var isSpending = false
    @Published var selectedContract: Contract?
    @Published var spendUTXOs: [UTXO] = []
    @Published var estimatedFee: UInt64 = 0
    @Published var psbtForReview: String?
    @Published var txForReview: String?

    var filteredContracts: [Contract] {
        ContractStore.shared.vaults.filter { $0.isTestnet == isTestnet }
    }

    var spendableBalance: UInt64 {
        guard let c = selectedContract else { return 0 }
        return fundedAmount(for: c)
    }

    var netSpendAmount: UInt64 {
        let bal = spendableBalance
        return bal > estimatedFee ? bal - estimatedFee : 0
    }

    func refresh() async { await refreshContracts() }

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
              let lockHeight = Int(lockBlockHeight), lockHeight > currentBlockHeight else {
            error = "Invalid parameters"
            return
        }
        let amountSats = UInt64(amount) ?? 0

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
        let kIdx = keyIndex

        // P2WSH vault only — Taproot single-key vaults not supported by Ledger
        // (is_policy_sane in policy.c rejects duplicate pubkeys in keysInfo)
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

        // Check if another contract already uses this address
        let existingContracts = ContractStore.shared.contractsForNetwork(isTestnet: isTestnet)
        if existingContracts.contains(where: { $0.address == address }) {
            error = "A contract with this address already exists. Use a different key index or lock height."
            isLoading = false
            return
        }

        let contract = Contract.newVault(
            name: name,
            script: scriptData,
            witnessScript: witnessHash,
            address: address,
            lockBlockHeight: lockHeight,
            amount: amountSats,
            isTestnet: isTestnet
        )

        var finalContract = contract
        finalContract.keyIndex = keyIndex
        ContractStore.shared.add(finalContract)
        createdContract = finalContract
        contracts = filteredContracts

        // Reset form
        self.name = ""
        lockBlockHeight = ""
        amount = ""
        isLoading = false
    }

    func delete(id: String) {
        ContractStore.shared.delete(id: id)
        contracts = filteredContracts
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
        defer { isSpending = false }
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
            let keyIdx = contract.keyIndex ?? 0
            let pubkey: Data
            if let xpubStr = KeychainStore.shared.loadXpub(isTestnet: isTestnet),
               let epk = ExtendedPublicKey.fromBase58(xpubStr),
               let child0 = epk.deriveChild(index: 0),
               let derived = child0.deriveChild(index: UInt32(keyIdx)) {
                pubkey = derived.key
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
            // Fetch previous transactions for NON_WITNESS_UTXO (eliminates Ledger warning)
            var inputInfos: [LedgerSigningV2.InputAddressInfo] = []
            for utxo in utxos {
                var prevTx: Data?
                if let rawHex = try? await MempoolAPI.shared.getRawTransaction(txid: utxo.txid),
                   let raw = Data(hex: rawHex) {
                    prevTx = raw
                }
                inputInfos.append(LedgerSigningV2.InputAddressInfo(
                    change: 0, index: UInt32(keyIdx),
                    publicKey: pubkey,
                    value: utxo.value,
                    scriptPubKey: spk,
                    previousTx: prevTx
                ))
            }

            // Sign + finalize + broadcast in one step
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

            // Broadcast immediately after signing
            let txid = try await SpendManager.broadcast(txHex: txHex)
            spendResult = txid

            // Update contract state
            var updated = updatedContract
            updated.isUnlocked = true
            updated.txid = txid
            ContractStore.shared.update(updated)
            contracts = filteredContracts
            selectedContract = updated

        } catch {
            spendError = error.localizedDescription
        }
    }
}
