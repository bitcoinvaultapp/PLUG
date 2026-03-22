import Foundation

@MainActor
final class PoolVM: ObservableObject, ContractVM {

    @Published var name: String = ""
    @Published var m: String = "2"
    @Published var pubkeys: [String] = ["", ""]
    @Published var amount: String = ""
    @Published var contracts: [Contract] = []
    @Published var currentBlockHeight: Int = 0
    @Published var isLoading = false
    @Published var error: String?
    @Published var createdContract: Contract?
    @Published var fundedAmounts: [String: UInt64] = [:]
    @Published var confirmations: [String: Int] = [:]
    @Published var importedPSBTBase64: String = ""
    @Published var parsedPSBT: PSBTBuilder.ParsedPSBT?

    var filteredContracts: [Contract] {
        ContractStore.shared.pools.filter { $0.isTestnet == isTestnet }
    }

    func refresh() async { await refreshContracts() }

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

        if isDuplicateAddress(contract.address) {
            error = "A contract with this address already exists."
            isLoading = false
            return
        }

        ContractStore.shared.add(contract)
        createdContract = contract
        contracts = filteredContracts

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
        contracts = filteredContracts
    }
}
