import Foundation

@MainActor
final class InheritanceVM: ObservableObject {

    @Published var name: String = ""
    @Published var csvBlocks: String = "" // relative timelock in blocks
    @Published var heirXpub: String = "" // heir's xpub or pubkey hex
    @Published var amount: String = ""
    @Published var useTaproot: Bool = false
    @Published var keyIndex: UInt32 = 0
    @Published var contracts: [Contract] = []
    @Published var currentBlockHeight: Int = 0
    @Published var isLoading = false
    @Published var error: String?
    @Published var createdContract: Contract?

    /// Funded balances for each contract address (fetched on refresh)
    @Published var fundedAmounts: [String: UInt64] = [:]  // address → balance in sats
    /// Minimum confirmation count for each contract address
    @Published var confirmations: [String: Int] = [:]  // address → min confirmations

    // Spend properties
    @Published var isSpending = false
    @Published var spendError: String?
    @Published var spendResult: String?
    @Published var selectedContract: Contract?
    @Published var heirClaimAddress: String = ""
    @Published var spendFeeRate: Double = 2.0

    var isTestnet: Bool { NetworkConfig.shared.isTestnet }

    var inheritances: [Contract] {
        ContractStore.shared.inheritances.filter { $0.isTestnet == isTestnet }
    }

    func refresh() async {
        isLoading = true
        do {
            currentBlockHeight = try await MempoolAPI.shared.getBlockHeight()
            contracts = inheritances
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

    /// Create a new inheritance contract
    func create() async {
        guard !isLoading else { return }
        guard !name.isEmpty,
              let csv = Int(csvBlocks), csv > 0,
              let amountSats = UInt64(amount), amountSats > 0 else {
            error = "Invalid parameters"
            return
        }

        isLoading = true

        // Owner public key from xpub
        guard let xpubStr = KeychainStore.shared.loadXpub(isTestnet: isTestnet),
              let xpub = ExtendedPublicKey.fromBase58(xpubStr) else {
            error = "Unable to derive owner public key"
            isLoading = false
            return
        }

        // Parse heir key input
        let heirInput = heirXpub
        let isTest = isTestnet
        let csvVal = csv
        let taproot = useTaproot
        let kIdx = keyIndex

        // Derive keys off main thread
        struct InheritanceResult {
            let scriptData: Data; let witnessHash: Data; let address: String
            let ownerPk: Data; let heirPk: Data
            // Taproot fields (only set when taproot == true)
            let internalKey: Data?; let tweakedKey: Data?; let merkleRoot: Data?; let scripts: [Data]?
        }
        guard let result: InheritanceResult = await Task.detached(priority: .userInitiated) { () -> InheritanceResult? in
            guard let ownerKey = xpub.derivePath([0, kIdx]) else { return nil }

            let heirPubkey: Data
            if let heirXpubParsed = ExtendedPublicKey.fromBase58(heirInput),
               let heirDerived = heirXpubParsed.derivePath([0, 0]) {
                heirPubkey = heirDerived.key
            } else if let hexData = Data(hex: heirInput), hexData.count == 33 {
                heirPubkey = hexData
            } else {
                return nil
            }

            if taproot {
                // Taproot: owner key-path + script tree {owner, heir+CSV}
                let internalKey = Secp256k1.xOnly(ownerKey.key)
                let ownerScript = ScriptBuilder().pushData(ownerKey.key).addOp(.op_checksig).script
                let heirScript = ScriptBuilder.inheritanceScript(
                    ownerPubkey: ownerKey.key, heirPubkey: heirPubkey, csvBlocks: Int64(csvVal)
                ).script
                let scripts = [ownerScript, heirScript]
                let merkleRoot = TaprootBuilder.computeMerkleRoot(scripts: scripts)
                guard let tweakedKey = TaprootBuilder.tweakPublicKey(internalKey: internalKey, merkleRoot: merkleRoot),
                      let address = TaprootBuilder.taprootAddress(internalKey: internalKey, scripts: scripts, isTestnet: isTest)
                else { return nil }
                return InheritanceResult(
                    scriptData: heirScript, witnessHash: Data(), address: address,
                    ownerPk: ownerKey.key, heirPk: heirPubkey,
                    internalKey: internalKey, tweakedKey: tweakedKey, merkleRoot: merkleRoot, scripts: scripts
                )
            } else {
                let script = ScriptBuilder.inheritanceScript(
                    ownerPubkey: ownerKey.key, heirPubkey: heirPubkey, csvBlocks: Int64(csvVal)
                )
                guard let address = script.p2wshAddress(isTestnet: isTest) else { return nil }
                return InheritanceResult(
                    scriptData: script.script, witnessHash: script.witnessScriptHash,
                    address: address, ownerPk: ownerKey.key, heirPk: heirPubkey,
                    internalKey: nil, tweakedKey: nil, merkleRoot: nil, scripts: nil
                )
            }
        }.value else {
            error = "Unable to derive keys or generate address"
            isLoading = false
            return
        }

        var contract: Contract
        if taproot, let ik = result.internalKey, let tk = result.tweakedKey {
            contract = Contract.newTaprootInheritance(
                name: name,
                internalKey: ik,
                tweakedKey: tk,
                address: result.address,
                csvBlocks: csv,
                ownerPubkey: result.ownerPk,
                heirPubkey: result.heirPk,
                amount: amountSats,
                isTestnet: isTestnet,
                scripts: result.scripts,
                merkleRoot: result.merkleRoot
            )
        } else {
            contract = Contract.newInheritance(
                name: name,
                script: result.scriptData,
                witnessScript: result.witnessHash,
                address: result.address,
                csvBlocks: csv,
                ownerPubkey: result.ownerPk,
                heirPubkey: result.heirPk,
                amount: amountSats,
                isTestnet: isTestnet
            )
        }
        // Store heir xpub for V2 Ledger signing (if provided as xpub)
        if ExtendedPublicKey.fromBase58(heirInput) != nil {
            contract.heirXpub = heirInput
        }

        contract.keyIndex = keyIndex
        ContractStore.shared.add(contract)
        createdContract = contract
        contracts = inheritances

        // Reset form
        self.name = ""
        csvBlocks = ""
        heirXpub = ""
        amount = ""
        isLoading = false
    }

    func delete(id: String) {
        ContractStore.shared.delete(id: id)
        contracts = inheritances
    }

    // MARK: - Keep Alive (Owner)

    /// Owner spends back to the same address to reset the CSV timer.
    func keepAlive(contract: Contract) async {
        isSpending = true
        spendError = nil
        spendResult = nil

        do {
            let utxos = try await ContractSpendCoordinator.fetchAndValidateUTXOs(
                contract: contract, feeRate: spendFeeRate
            )

            let psbtData = try SpendManager.buildInheritanceKeepAlivePSBT(
                contract: contract, utxos: utxos,
                feeRate: spendFeeRate, isTestnet: isTestnet
            )

            let (txid, _) = try await ContractSpendCoordinator.signFinalizeAndBroadcast(
                psbtData: psbtData, contract: contract,
                spendPath: contract.isTaproot ? .taprootInheritanceOwner : .inheritanceKeepAlive,
                buildWitness: SpendManager.inheritanceKeepAliveWitness,
                isTestnet: isTestnet
            )
            spendResult = txid

            // Track last keep-alive date
            var updated = contract
            updated.lastKeptAlive = Date()
            ContractStore.shared.update(updated)
            contracts = inheritances

        } catch {
            spendError = error.localizedDescription
        }

        isSpending = false
    }

    // MARK: - Heir Claim

    /// Heir claims the inheritance after the CSV timelock has passed.
    func heirClaim(contract: Contract, destinationAddress: String) async {
        guard !destinationAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            spendError = "Destination address required"
            return
        }

        isSpending = true
        spendError = nil
        spendResult = nil

        do {
            let utxos = try await ContractSpendCoordinator.fetchAndValidateUTXOs(
                contract: contract, feeRate: spendFeeRate
            )

            let address = destinationAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            let psbtData = try SpendManager.buildInheritanceHeirClaimPSBT(
                contract: contract, utxos: utxos,
                destinationAddress: address,
                feeRate: spendFeeRate, isTestnet: isTestnet
            )

            let (txid, _) = try await ContractSpendCoordinator.signFinalizeAndBroadcast(
                psbtData: psbtData, contract: contract,
                spendPath: contract.isTaproot ? .taprootInheritanceHeir : .inheritanceHeirClaim,
                buildWitness: SpendManager.inheritanceHeirClaimWitness,
                isTestnet: isTestnet
            )
            spendResult = txid

        } catch {
            spendError = error.localizedDescription
        }

        isSpending = false
    }
}
