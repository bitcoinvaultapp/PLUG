import Foundation

// MARK: - Contract Spend Coordinator
// Factorizes the common build→sign→finalize→broadcast pipeline
// shared across all contract ViewModels.

enum ContractSpendCoordinator {

    // MARK: - Errors

    struct DustThresholdError: LocalizedError {
        let netAmount: UInt64
        var errorDescription: String? {
            "The net amount (\(netAmount) sats) is below the dust threshold (546 sats). The transaction would be rejected."
        }
    }

    // MARK: - UTXO Fetch + Validation

    /// Fetch UTXOs for a contract address and validate: non-empty + dust check.
    static func fetchAndValidateUTXOs(
        contract: Contract,
        outputCount: Int = 1,
        feeRate: Double
    ) async throws -> [UTXO] {
        let utxos = try await MempoolAPI.shared.getAddressUTXOs(address: contract.address)
        guard !utxos.isEmpty else {
            throw SpendManager.SpendError.insufficientFunds
        }

        let totalInput = utxos.reduce(UInt64(0)) { $0 + $1.value }
        let estFee = SpendManager.estimateFee(
            contract: contract, utxoCount: utxos.count,
            outputCount: outputCount, feeRate: feeRate
        )
        let netAmount = totalInput > estFee ? totalInput - estFee : 0
        if netAmount > 0 && netAmount < 546 {
            throw DustThresholdError(netAmount: netAmount)
        }

        return utxos
    }

    // MARK: - Sign + Finalize

    /// Sign a PSBT via Ledger, build witness stacks, and finalize the transaction.
    /// Returns the raw transaction hex (NOT broadcast).
    static func signAndFinalize(
        psbtData: Data,
        contract: Contract,
        spendPath: ContractSigner.SpendPath,
        inputAddressInfos: [LedgerSigningV2.InputAddressInfo] = [],
        buildWitness: (_ signature: Data, _ witnessScript: Data) -> [Data],
        isTestnet: Bool
    ) async throws -> (txHex: String, updatedContract: Contract) {
        let witnessScriptData = Data(hex: contract.script) ?? Data()

        let (signatures, updatedContract) = try await ContractSigner.signContractSpend(
            psbtData: psbtData,
            contract: contract,
            spendPath: spendPath,
            witnessScript: witnessScriptData,
            inputAddressInfos: inputAddressInfos,
            isTestnet: isTestnet
        )

        let witnessStacks: [[Data]] = signatures.map { sig in
            buildWitness(sig, witnessScriptData)
        }

        guard let finalTx = SpendManager.finalizePSBT(
            psbtData: psbtData,
            witnessStacks: witnessStacks
        ) else {
            throw SpendManager.SpendError.signingFailed
        }

        let txHex = SpendManager.extractTransactionHex(finalTx)
        return (txHex, updatedContract)
    }

    // MARK: - Sign + Finalize + Broadcast (full pipeline)

    /// Full pipeline: sign → finalize → broadcast. Returns the txid.
    static func signFinalizeAndBroadcast(
        psbtData: Data,
        contract: Contract,
        spendPath: ContractSigner.SpendPath,
        inputAddressInfos: [LedgerSigningV2.InputAddressInfo] = [],
        buildWitness: (_ signature: Data, _ witnessScript: Data) -> [Data],
        isTestnet: Bool
    ) async throws -> (txid: String, updatedContract: Contract) {
        let (txHex, updatedContract) = try await signAndFinalize(
            psbtData: psbtData,
            contract: contract,
            spendPath: spendPath,
            inputAddressInfos: inputAddressInfos,
            buildWitness: buildWitness,
            isTestnet: isTestnet
        )
        let txid = try await SpendManager.broadcast(txHex: txHex)
        return (txid, updatedContract)
    }

    // MARK: - Balance Refresh

    /// Fetch funded amounts and confirmation depths for a list of contracts.
    /// Call from any VM's `refresh()` to avoid duplicating the TaskGroup boilerplate.
    static func refreshBalances(
        contracts: [Contract],
        blockHeight: Int
    ) async -> (amounts: [String: UInt64], confirmations: [String: Int]) {
        var amounts: [String: UInt64] = [:]
        var confs: [String: Int] = [:]

        await withTaskGroup(of: (String, UInt64, Int).self) { group in
            for contract in contracts {
                group.addTask {
                    let utxos = (try? await MempoolAPI.shared.getAddressUTXOs(address: contract.address)) ?? []
                    let balance = utxos.reduce(UInt64(0)) { $0 + $1.value }
                    let minConfs: Int
                    if utxos.isEmpty {
                        minConfs = 0
                    } else {
                        minConfs = utxos.map { utxo in
                            if utxo.status.confirmed, let h = utxo.status.blockHeight, blockHeight > 0 {
                                return blockHeight - h + 1
                            }
                            return 0
                        }.min() ?? 0
                    }
                    return (contract.address, balance, minConfs)
                }
            }
            for await (address, balance, c) in group {
                amounts[address] = balance
                confs[address] = c
            }
        }

        return (amounts, confs)
    }
}
