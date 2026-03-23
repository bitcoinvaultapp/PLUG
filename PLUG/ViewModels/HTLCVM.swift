import Foundation

@MainActor
final class HTLCVM: ObservableObject, ContractVM {

    @Published var name: String = ""
    @Published var receiverPubkey: String = ""
    @Published var timeoutBlocks: String = ""
    @Published var amount: String = ""
    @Published var keyIndex: UInt32 = 0
    @Published var contracts: [Contract] = []
    @Published var generatedPreimage: String = ""
    @Published var hashLock: String = ""
    @Published var currentBlockHeight: Int = 0
    @Published var isLoading = false
    @Published var error: String?
    @Published var createdContract: Contract?
    @Published var fundedAmounts: [String: UInt64] = [:]
    @Published var confirmations: [String: Int] = [:]
    @Published var isSpending = false
    @Published var spendError: String?
    @Published var spendResult: String?
    @Published var selectedContract: Contract?
    @Published var claimPreimage: String = ""
    @Published var claimDestination: String = ""
    @Published var refundDestination: String = ""
    @Published var spendFeeRate: Double = 2.0

    var filteredContracts: [Contract] {
        ContractStore.shared.htlcs.filter { $0.isTestnet == isTestnet }
    }

    func refresh() async { await refreshContracts() }

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
        guard let timeout = contract.timeoutBlocks else { return 0 }
        return max(0, timeout - currentBlockHeight)
    }

    func isRefundable(_ contract: Contract) -> Bool {
        guard let timeout = contract.timeoutBlocks else { return false }
        return currentBlockHeight >= timeout
    }

    /// Create a new HTLC contract
    func create() async {
        guard !isLoading else { return }
        guard !name.isEmpty,
              let timeout = Int(timeoutBlocks), timeout > currentBlockHeight,
              !receiverPubkey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Invalid parameters"
            return
        }
        let amountSats = UInt64(amount) ?? 0

        isLoading = true

        // Get sender key from xpub
        guard let xpubStr = KeychainStore.shared.loadXpub(isTestnet: isTestnet),
              let xpub = ExtendedPublicKey.fromBase58(xpubStr) else {
            error = "Unable to derive public key"
            isLoading = false
            return
        }

        let receiverInput = receiverPubkey.trimmingCharacters(in: .whitespacesAndNewlines)
        let isTest = isTestnet
        let tb = Int64(timeout)
        let kIdx = keyIndex

        // Derive keys and build script off main thread
        guard let result = await Task.detached(priority: .userInitiated) { () -> (Data, Data, String, Data, Data, Data, Data)? in
            // Derive sender pubkey
            guard let derivedKey = xpub.derivePath([0, kIdx]) else { return nil }
            let senderPubkey = derivedKey.key

            // Parse receiver pubkey (hex or xpub)
            let receiverKey: Data
            if let rxpub = ExtendedPublicKey.fromBase58(receiverInput),
               let derived = rxpub.derivePath([0, 0]) {
                receiverKey = derived.key
            } else if let hexData = Data(hex: receiverInput), hexData.count == 33 {
                receiverKey = hexData
            } else {
                return nil
            }

            // Generate preimage using cryptographically secure randomness (SecRandomCopyBytes).
            // Preimages are always 32 bytes of CSPRNG entropy — never user-supplied.
            guard let preimage = HTLCBuilder.generatePreimage() else { return nil }
            let hashLockData = HTLCBuilder.hashPreimage(preimage)

            // Build HTLC script
            let script = HTLCBuilder.htlcScript(
                receiverPubkey: receiverKey,
                senderPubkey: senderPubkey,
                hashLock: hashLockData,
                timeoutBlocks: tb
            )
            guard let address = script.p2wshAddress(isTestnet: isTest) else { return nil }
            return (script.script, script.witnessScriptHash, address, senderPubkey, receiverKey, preimage, hashLockData)
        }.value else {
            error = "Unable to generate contract"
            isLoading = false
            return
        }

        let (scriptData, witnessHash, address, senderKey, receiverKey, preimage, hashLockData) = result

        // Store preimage and hash lock for display
        generatedPreimage = preimage.hex
        hashLock = hashLockData.hex

        var contract = Contract.newHTLC(
            name: name,
            script: scriptData,
            witnessScript: witnessHash,
            address: address,
            hashLock: hashLockData,
            senderPubkey: senderKey,
            receiverPubkey: receiverKey,
            timeoutBlocks: timeout,
            amount: amountSats,
            isTestnet: isTestnet
        )

        // Store the receiver xpub if provided (needed for V2 Ledger signing)
        if ExtendedPublicKey.fromBase58(receiverInput) != nil {
            contract.receiverXpub = receiverInput
        }

        if isDuplicateAddress(contract.address) {
            error = "A contract with this address already exists."
            isLoading = false
            return
        }

        // Save preimage to keychain as backup before it's lost
        let _ = KeychainStore.shared.saveString(preimage.hex, forKey: "htlc_preimage_\(contract.id)")

        ContractStore.shared.add(contract)
        createdContract = contract
        contracts = filteredContracts

        // Reset form
        self.name = ""
        self.receiverPubkey = ""
        timeoutBlocks = ""
        self.amount = ""
        isLoading = false
    }

    func delete(id: String) {
        ContractStore.shared.delete(id: id)
        contracts = filteredContracts
    }

    /// Retrieve a preimage from keychain backup
    func loadPreimage(for contract: Contract) -> String? {
        KeychainStore.shared.loadString(forKey: "htlc_preimage_\(contract.id)")
    }

    // MARK: - Claim with Preimage (Receiver)

    /// Receiver claims the HTLC by providing the preimage.
    func claimWithPreimage(contract: Contract, preimage: String, destination: String) async {
        guard !preimage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            spendError = SpendManager.SpendError.missingPreimage.localizedDescription
            return
        }
        guard !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            spendError = SpendManager.SpendError.invalidAddress.localizedDescription
            return
        }
        guard let preimageData = Data(hex: preimage.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            spendError = "Invalid preimage hex"
            return
        }

        isSpending = true
        defer { isSpending = false }
        spendError = nil
        spendResult = nil

        do {
            let utxos = try await ContractSpendCoordinator.fetchAndValidateUTXOs(
                contract: contract, feeRate: spendFeeRate
            )

            let addr = destination.trimmingCharacters(in: .whitespacesAndNewlines)
            let psbtData = try SpendManager.buildHTLCClaimPSBT(
                contract: contract, preimage: preimageData,
                utxos: utxos, destinationAddress: addr,
                feeRate: spendFeeRate, isTestnet: isTestnet
            )

            let (txid, _) = try await ContractSpendCoordinator.signFinalizeAndBroadcast(
                psbtData: psbtData, contract: contract,
                spendPath: contract.isTaproot ? .taprootHTLCClaim : .htlcClaim,
                buildWitness: { sig, ws in
                    SpendManager.htlcClaimWitness(signature: sig, preimage: preimageData, witnessScript: ws)
                },
                isTestnet: isTestnet
            )
            spendResult = txid

        } catch {
            spendError = error.localizedDescription
        }

    }

    // MARK: - Refund (Sender)

    /// Sender reclaims the HTLC after the timeout has passed.
    func refund(contract: Contract, destination: String) async {
        guard !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            spendError = SpendManager.SpendError.invalidAddress.localizedDescription
            return
        }
        guard isRefundable(contract) else {
            spendError = SpendManager.SpendError.timelockNotReached.localizedDescription
            return
        }

        isSpending = true
        defer { isSpending = false }
        spendError = nil
        spendResult = nil

        do {
            let utxos = try await ContractSpendCoordinator.fetchAndValidateUTXOs(
                contract: contract, feeRate: spendFeeRate
            )

            let addr = destination.trimmingCharacters(in: .whitespacesAndNewlines)
            let psbtData = try SpendManager.buildHTLCRefundPSBT(
                contract: contract, utxos: utxos,
                destinationAddress: addr,
                feeRate: spendFeeRate, isTestnet: isTestnet
            )

            let (txid, _) = try await ContractSpendCoordinator.signFinalizeAndBroadcast(
                psbtData: psbtData, contract: contract,
                spendPath: contract.isTaproot ? .taprootHTLCRefund : .htlcRefund,
                buildWitness: SpendManager.htlcRefundWitness,
                isTestnet: isTestnet
            )
            spendResult = txid

        } catch {
            spendError = error.localizedDescription
        }

    }
}
