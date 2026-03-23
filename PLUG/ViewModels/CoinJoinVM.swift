import Foundation

@MainActor
final class CoinJoinVM: ObservableObject {

    enum Role: String, CaseIterable { case initiator = "Start", joiner = "Join" }
    enum Step { case setup, built, signed, broadcast }

    @Published var role: Role = .initiator
    @Published var step: Step = .setup
    @Published var denomination: UInt64 = 100_000
    @Published var feeRate: Double = 1.0

    // UTXO selection
    @Published var selectedOutpoints: Set<String> = []

    // PSBT exchange
    @Published var exportedPSBT: String?
    @Published var importedPSBT: String = ""

    // Signing
    @Published var isSigning = false
    @Published var broadcastTxid: String?
    @Published var error: String?

    var isTestnet: Bool { NetworkConfig.shared.isTestnet }

    var feePerInput: UInt64 {
        CoinJoinBuilder.estimateFeePerInput(feeRate: feeRate)
    }

    var selectedTotal: UInt64 {
        0 // computed from walletVM in view
    }

    // MARK: - Initiator: create CoinJoin

    func createCoinJoin(walletVM: WalletVM) {
        error = nil

        let selected = walletVM.utxos.filter { selectedOutpoints.contains($0.outpoint) }
        guard !selected.isEmpty else {
            error = "Select at least one UTXO"
            return
        }

        let totalInput = selected.reduce(UInt64(0)) { $0 + $1.value }
        guard totalInput >= denomination + feePerInput else {
            error = "Insufficient funds. Need \(denomination + feePerInput) sats, have \(totalInput)"
            return
        }

        // Fresh receive address for mix output
        let mixAddress = walletVM.currentReceiveAddress
        guard !mixAddress.isEmpty else {
            error = "No receive address available"
            return
        }

        // Change address
        let changeAddresses = walletVM.addresses.filter { $0.isChange }
        let changeAddress = changeAddresses.first(where: { walletVM.addressStatus(for: $0.address) == .fresh })?.address
            ?? changeAddresses.first?.address

        guard let psbt = CoinJoinBuilder.createCoinJoinPSBT(
            utxos: selected,
            denomination: denomination,
            mixAddress: mixAddress,
            changeAddress: changeAddress,
            feePerInput: feePerInput,
            isTestnet: isTestnet
        ) else {
            error = "Failed to build PSBT"
            return
        }

        exportedPSBT = psbt.base64EncodedString()
        step = .built
    }

    // MARK: - Joiner: add to existing CoinJoin

    func joinCoinJoin(walletVM: WalletVM) {
        error = nil

        guard let existingData = Data(base64Encoded: importedPSBT.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "Invalid PSBT (not valid Base64)"
            return
        }

        let selected = walletVM.utxos.filter { selectedOutpoints.contains($0.outpoint) }
        guard !selected.isEmpty else {
            error = "Select at least one UTXO"
            return
        }

        // Detect denomination from imported PSBT
        if let info = CoinJoinBuilder.analyzePSBT(existingData, isTestnet: isTestnet) {
            denomination = info.denomination
        }

        let totalInput = selected.reduce(UInt64(0)) { $0 + $1.value }
        guard totalInput >= denomination + feePerInput else {
            error = "Insufficient funds. Need \(denomination + feePerInput) sats, have \(totalInput)"
            return
        }

        let mixAddress = walletVM.currentReceiveAddress
        guard !mixAddress.isEmpty else {
            error = "No receive address available"
            return
        }

        let changeAddresses = walletVM.addresses.filter { $0.isChange }
        let changeAddress = changeAddresses.first(where: { walletVM.addressStatus(for: $0.address) == .fresh })?.address
            ?? changeAddresses.first?.address

        guard let psbt = CoinJoinBuilder.joinCoinJoin(
            existingPSBT: existingData,
            myUTXOs: selected,
            denomination: denomination,
            mixAddress: mixAddress,
            changeAddress: changeAddress,
            feePerInput: feePerInput,
            isTestnet: isTestnet
        ) else {
            error = "Failed to join CoinJoin"
            return
        }

        exportedPSBT = psbt.base64EncodedString()
        step = .built
    }

    // MARK: - Sign my inputs

    func signMyInputs(walletVM: WalletVM) async {
        guard let psbtBase64 = exportedPSBT ?? (importedPSBT.isEmpty ? nil : importedPSBT),
              let psbtData = Data(base64Encoded: psbtBase64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "No PSBT to sign"
            return
        }

        isSigning = true
        error = nil

        do {
            let coinType = KeychainStore.shared.loadString(forKey: KeychainStore.KeychainKey.ledgerCoinType.rawValue) ?? "1"
            let keyOrigin = "84'/\(coinType)'/0'"
            let xpub = KeychainStore.shared.loadString(forKey: KeychainStore.KeychainKey.ledgerOriginalXpub.rawValue)
                ?? KeychainStore.shared.loadXpub(isTestnet: isTestnet) ?? ""

            // Build input address infos for our UTXOs only
            var inputInfos: [LedgerSigningV2.InputAddressInfo] = []
            let selected = walletVM.utxos.filter { selectedOutpoints.contains($0.outpoint) }

            // Parse PSBT to find which input indices are ours
            if let parsed = PSBTBuilder.parsePSBT(psbtData),
               let unsignedTx = parsed.unsignedTx {
                let txInputs = CoinJoinBuilder.parseInputsFromTx(unsignedTx)
                for (i, txInput) in txInputs.enumerated() {
                    // Check if this input matches one of our selected UTXOs
                    // txInput.txid is internal byte order; convert each UTXO txid to internal for comparison
                    if let myUtxo = selected.first(where: { SpendManager.txidToInternalOrder($0.txid) == txInput.txid && UInt32($0.vout) == txInput.vout }),
                       let walletAddr = walletVM.addresses.first(where: { $0.address == myUtxo.address }),
                       let xpubParsed = ExtendedPublicKey.fromBase58(xpub),
                       let derived = xpubParsed.derivePath([walletAddr.isChange ? 1 : 0, walletAddr.index]) {
                        let spk = PSBTBuilder.scriptPubKeyFromAddress(myUtxo.address, isTestnet: isTestnet) ?? Data()
                        var prevTx: Data?
                        if let rawHex = try? await MempoolAPI.shared.getRawTransaction(txid: myUtxo.txid),
                           let raw = Data(hex: rawHex) { prevTx = raw }
                        inputInfos.append(LedgerSigningV2.InputAddressInfo(
                            change: walletAddr.isChange ? 1 : 0,
                            index: walletAddr.index,
                            publicKey: derived.key,
                            value: myUtxo.value,
                            scriptPubKey: spk,
                            previousTx: prevTx
                        ))
                    } else {
                        // Not our input — add empty info (Ledger will skip it)
                        inputInfos.append(LedgerSigningV2.InputAddressInfo(
                            change: 0, index: 0,
                            publicKey: Data(),
                            value: 0,
                            scriptPubKey: Data(),
                            previousTx: nil
                        ))
                    }
                    _ = i // suppress warning
                }
            }

            let result = try await LedgerSigningV2.signPSBT(
                psbt: psbtData,
                walletPolicy: "wpkh(@0/**)",
                keyOrigin: keyOrigin,
                xpub: xpub,
                inputAddressInfos: inputInfos
            )

            if result.isEmpty {
                error = "No signatures received from Ledger"
            } else {
                // Build witness stacks and finalize
                var perInputPubkeys: [Data] = []
                for info in inputInfos {
                    perInputPubkeys.append(info.publicKey)
                }

                let signatures = result.map { $0.signature }
                var witnessStacks: [[Data]] = Array(repeating: [], count: inputInfos.count)

                for sigResult in result {
                    let idx = sigResult.index
                    if idx < inputInfos.count && !inputInfos[idx].publicKey.isEmpty {
                        witnessStacks[idx] = [sigResult.signature, inputInfos[idx].publicKey]
                    }
                }

                // Check if all inputs are signed (all participants done)
                let allSigned = witnessStacks.allSatisfy { !$0.isEmpty }

                if allSigned {
                    // All inputs signed — finalize and broadcast
                    if let finalTx = SpendManager.finalizePSBT(psbtData: psbtData, witnessStacks: witnessStacks) {
                        let txHex = SpendManager.extractTransactionHex(finalTx)
                        let txid = try await MempoolAPI.shared.broadcastTransaction(hex: txHex)
                        broadcastTxid = txid
                        step = .broadcast
                    } else {
                        // Not all inputs signed yet — export for other participants
                        exportedPSBT = psbtData.base64EncodedString()
                        step = .signed
                        error = "Signed your inputs. Share the PSBT with other participants to sign theirs."
                    }
                } else {
                    exportedPSBT = psbtData.base64EncodedString()
                    step = .signed
                    error = "Signed your inputs. Share the PSBT with other participants to sign theirs."
                }
            }
        } catch {
            self.error = error.localizedDescription
        }

        isSigning = false
    }

    // MARK: - Reset

    func reset() {
        role = .initiator
        step = .setup
        denomination = 100_000
        selectedOutpoints.removeAll()
        exportedPSBT = nil
        importedPSBT = ""
        broadcastTxid = nil
        error = nil
        isSigning = false
    }
}
