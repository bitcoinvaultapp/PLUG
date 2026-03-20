import Foundation

@MainActor
final class PoolVM: ObservableObject {

    @Published var name: String = ""
    @Published var m: String = "2" // threshold
    @Published var pubkeys: [String] = ["", ""] // hex pubkeys or xpubs
    @Published var amount: String = ""
    @Published var contracts: [Contract] = []
    @Published var currentBlockHeight: Int = 0
    @Published var isLoading = false
    @Published var error: String?
    @Published var createdContract: Contract?

    /// Funded balances for each contract address (fetched on refresh)
    @Published var fundedAmounts: [String: UInt64] = [:]  // address → balance in sats
    /// Minimum confirmation count for each contract address
    @Published var confirmations: [String: Int] = [:]  // address → min confirmations

    // PSBT import for co-signing
    @Published var importedPSBTBase64: String = ""
    @Published var parsedPSBT: PSBTBuilder.ParsedPSBT?

    var isTestnet: Bool { NetworkConfig.shared.isTestnet }

    var pools: [Contract] {
        ContractStore.shared.pools.filter { $0.isTestnet == isTestnet }
    }

    func refresh() async {
        isLoading = true
        do {
            currentBlockHeight = try await MempoolAPI.shared.getBlockHeight()
            contracts = pools
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

    func addPubkeyField() {
        pubkeys.append("")
    }

    func removePubkeyField(at index: Int) {
        guard pubkeys.count > 2 else { return }
        pubkeys.remove(at: index)
    }

    /// Create a new pool (multisig)
    func create() async {
        guard !isLoading else { return }
        guard !name.isEmpty,
              let mInt = Int(m), mInt > 0 else {
            error = "Invalid parameters"
            return
        }
        let amountSats = UInt64(amount) ?? 0

        isLoading = true

        // Parse pubkeys and build script off main thread
        let pkInputs = pubkeys
        let isTest = isTestnet

        struct PoolResult {
            let scriptData: Data; let witnessHash: Data; let address: String
            let keys: [Data]; let errorMsg: String?
        }
        let parseResult: PoolResult = await Task.detached(priority: .userInitiated) {
            var parsedKeys: [Data] = []
            for pkStr in pkInputs {
                let trimmed = pkStr.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if let xpub = ExtendedPublicKey.fromBase58(trimmed),
                   let derived = xpub.derivePath([0, 0]) {
                    parsedKeys.append(derived.key)
                } else if let hexData = Data(hex: trimmed), hexData.count == 33 {
                    parsedKeys.append(hexData)
                } else {
                    return PoolResult(scriptData: Data(), witnessHash: Data(), address: "", keys: [], errorMsg: "Invalid key: \(String(trimmed.prefix(16)))...")
                }
            }

            // Check for duplicate keys
            let uniqueKeys = Set(parsedKeys)
            if uniqueKeys.count != parsedKeys.count {
                return PoolResult(scriptData: Data(), witnessHash: Data(), address: "", keys: [], errorMsg: "Public keys must all be different. Duplicate keys detected.")
            }

            guard mInt <= parsedKeys.count else {
                return PoolResult(scriptData: Data(), witnessHash: Data(), address: "", keys: [], errorMsg: "M (\(mInt)) > N (\(parsedKeys.count))")
            }
            let script = ScriptBuilder.multisigScript(m: mInt, pubkeys: parsedKeys)
            guard let address = script.p2wshAddress(isTestnet: isTest) else {
                return PoolResult(scriptData: Data(), witnessHash: Data(), address: "", keys: [], errorMsg: "Unable to generate address")
            }
            return PoolResult(
                scriptData: script.script, witnessHash: script.witnessScriptHash,
                address: address, keys: parsedKeys, errorMsg: nil
            )
        }.value

        if let errMsg = parseResult.errorMsg {
            error = errMsg
            isLoading = false
            return
        }

        var contract = Contract.newPool(
            name: name,
            script: parseResult.scriptData,
            witnessScript: parseResult.witnessHash,
            address: parseResult.address,
            m: mInt,
            pubkeys: parseResult.keys,
            amount: amountSats,
            isTestnet: isTestnet
        )

        // Store original xpub strings for co-signers (needed for V2 Ledger signing)
        let xpubStrings = pkInputs.compactMap { input -> String? in
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            return ExtendedPublicKey.fromBase58(trimmed) != nil ? trimmed : nil
        }
        if !xpubStrings.isEmpty {
            contract.multisigXpubs = xpubStrings
        }

        let existing = ContractStore.shared.contractsForNetwork(isTestnet: isTestnet)
        if existing.contains(where: { $0.address == contract.address }) {
            error = "A contract with this address already exists."
            isLoading = false
            return
        }

        ContractStore.shared.add(contract)
        createdContract = contract
        contracts = pools

        // Reset
        self.name = ""
        self.m = "2"
        pubkeys = ["", ""]
        amount = ""
        isLoading = false
    }

    /// Import PSBT for co-signing
    func importPSBT() {
        guard let data = Data(base64Encoded: importedPSBTBase64) else {
            error = "Invalid PSBT Base64"
            return
        }

        parsedPSBT = PSBTBuilder.parsePSBT(data)
        if parsedPSBT == nil {
            error = "Invalid PSBT"
        }
    }

    func delete(id: String) {
        ContractStore.shared.delete(id: id)
        contracts = pools
    }
}
