import Foundation

@MainActor
final class ChannelVM: ObservableObject, ContractVM {

    @Published var name: String = ""
    @Published var receiverPubkey: String = ""
    @Published var timeoutBlocks: String = ""
    @Published var amount: String = ""
    @Published var keyIndex: UInt32 = 0
    @Published var contracts: [Contract] = []
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
    @Published var refundDestination: String = ""
    @Published var closesSenderAmount: String = ""
    @Published var closesReceiverAmount: String = ""
    @Published var closeSenderAddress: String = ""
    @Published var closeReceiverAddress: String = ""
    @Published var spendFeeRate: Double = 2.0

    var filteredContracts: [Contract] {
        ContractStore.shared.channels.filter { $0.isTestnet == isTestnet }
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

    /// Create a new payment channel
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
        guard let result = await Task.detached(priority: .userInitiated) { () -> (Data, Data, String, Data, Data)? in
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

            // Build channel script
            let script = PaymentChannelBuilder.channelScript(
                senderPubkey: senderPubkey,
                receiverPubkey: receiverKey,
                timeoutBlocks: tb
            )
            guard let address = script.p2wshAddress(isTestnet: isTest) else { return nil }
            return (script.script, script.witnessScriptHash, address, senderPubkey, receiverKey)
        }.value else {
            error = "Unable to generate channel"
            isLoading = false
            return
        }

        let (scriptData, witnessHash, address, senderKey, receiverKey) = result

        var contract = Contract.newChannel(
            name: name,
            script: scriptData,
            witnessScript: witnessHash,
            address: address,
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

    // MARK: - Cooperative Close

    /// Close the channel cooperatively (requires both sender and receiver signatures).
    func cooperativeClose(
        contract: Contract,
        senderAmount: UInt64,
        receiverAmount: UInt64,
        senderAddress: String,
        receiverAddress: String
    ) async {
        guard !senderAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !receiverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            spendError = SpendManager.SpendError.invalidAddress.localizedDescription
            return
        }

        isSpending = true
        defer { isSpending = false }
        spendError = nil
        spendResult = nil

        do {
            let utxos = try await MempoolAPI.shared.getAddressUTXOs(address: contract.address)
            guard !utxos.isEmpty else {
                throw SpendManager.SpendError.insufficientFunds
            }

            // Dust output warning on cooperative close amounts
            if senderAmount > 0 && senderAmount < 546 {
                throw ContractSpendCoordinator.DustThresholdError(netAmount: senderAmount)
            }
            if receiverAmount > 0 && receiverAmount < 546 {
                throw ContractSpendCoordinator.DustThresholdError(netAmount: receiverAmount)
            }

            let sAddr = senderAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            let rAddr = receiverAddress.trimmingCharacters(in: .whitespacesAndNewlines)

            let psbtData = try SpendManager.buildChannelCooperativeClosePSBT(
                contract: contract,
                utxos: utxos,
                senderAmount: senderAmount,
                receiverAmount: receiverAmount,
                senderAddress: sAddr,
                receiverAddress: rAddr,
                feeRate: spendFeeRate,
                isTestnet: isTestnet
            )

            // Sign as sender (our key)
            let witnessScriptData = Data(hex: contract.script) ?? Data()
            let (senderSignatures, updatedContract) = try await ContractSigner.signContractSpend(
                psbtData: psbtData,
                contract: contract,
                spendPath: .channelCooperativeClose,
                witnessScript: witnessScriptData,
                isTestnet: isTestnet
            )

            // For cooperative close, we need both signatures.
            // In production, the receiver would sign and return their sigs via PSBT sharing.
            // For now, use the sender sigs as placeholder (PSBT sharing needed).
            let receiverSignatures = senderSignatures

            var witnessStacks: [[Data]] = []
            for i in 0..<senderSignatures.count {
                let rSig = i < receiverSignatures.count ? receiverSignatures[i] : senderSignatures[i]
                let stack = SpendManager.channelCooperativeCloseWitness(
                    senderSig: senderSignatures[i],
                    receiverSig: rSig,
                    witnessScript: witnessScriptData
                )
                witnessStacks.append(stack)
            }

            guard let finalTx = SpendManager.finalizePSBT(
                psbtData: psbtData,
                witnessStacks: witnessStacks
            ) else {
                spendError = SpendManager.SpendError.signingFailed.localizedDescription
                isSpending = false
                return
            }

            let txHex = SpendManager.extractTransactionHex(finalTx)
            let txid = try await SpendManager.broadcast(txHex: txHex)
            spendResult = txid

        } catch {
            spendError = error.localizedDescription
        }

    }

    // MARK: - Unilateral Refund

    /// Sender refunds unilaterally after timeout.
    func unilateralRefund(contract: Contract, destination: String) async {
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
            let psbtData = try SpendManager.buildChannelRefundPSBT(
                contract: contract, utxos: utxos,
                destinationAddress: addr,
                feeRate: spendFeeRate, isTestnet: isTestnet
            )

            let (txid, _) = try await ContractSpendCoordinator.signFinalizeAndBroadcast(
                psbtData: psbtData, contract: contract,
                spendPath: .channelRefund,
                buildWitness: SpendManager.channelRefundWitness,
                isTestnet: isTestnet
            )
            spendResult = txid

        } catch {
            spendError = error.localizedDescription
        }

    }
}
