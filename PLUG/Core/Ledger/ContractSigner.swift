import Foundation

// MARK: - Wallet Policy Builder
// Generates Ledger V2 wallet policy descriptors for each contract type.

struct WalletPolicyBuilder {

    struct Policy {
        let name: String
        let descriptorTemplate: String
        let keysInfo: [String]  // ["[fp/path]xpub", "xpub_external", ...]
    }

    // MARK: - Vault (CLTV vault)
    // Script: <locktime> OP_CLTV OP_DROP <pk> OP_CHECKSIG
    // Miniscript: and_v(v:pk(@0/**),after(N))

    static func vaultPolicy(lockBlockHeight: Int, masterFP: String, keyOrigin: String, xpub: String) -> Policy {
        Policy(
            name: "Vault",
            descriptorTemplate: "wsh(and_v(v:pk(@0/**),after(\(lockBlockHeight))))",
            keysInfo: ["[\(masterFP)/\(keyOrigin)]\(xpub)"]
        )
    }

    // MARK: - Inheritance (CSV with IF/ELSE)
    // Script: IF <owner_pk> CHECKSIG ELSE <csv> CSV DROP <heir_pk> CHECKSIG ENDIF
    // Miniscript: or_d(pk(@0/**),and_v(v:pk(@1/**),older(N)))

    static func inheritanceOwnerPolicy(csvBlocks: Int, masterFP: String, keyOrigin: String, ownerXpub: String, heirXpub: String) -> Policy {
        Policy(
            name: "Inheritance",
            descriptorTemplate: "wsh(or_d(pk(@0/**),and_v(v:pk(@1/**),older(\(csvBlocks)))))",
            keysInfo: [
                "[\(masterFP)/\(keyOrigin)]\(ownerXpub)",  // @0 = owner (internal)
                heirXpub                                      // @1 = heir (external, no origin)
            ]
        )
    }

    static func inheritanceHeirPolicy(csvBlocks: Int, masterFP: String, keyOrigin: String, ownerXpub: String, heirXpub: String) -> Policy {
        Policy(
            name: "Inheritance Heir",
            descriptorTemplate: "wsh(or_d(pk(@1/**),and_v(v:pk(@0/**),older(\(csvBlocks)))))",
            keysInfo: [
                "[\(masterFP)/\(keyOrigin)]\(heirXpub)",   // @0 = heir (internal)
                ownerXpub                                     // @1 = owner (external)
            ]
        )
    }

    // MARK: - HTLC (Hash Time-Lock)
    // Miniscript: andor(pk(@0/**),sha256(H),and_v(v:pk(@1/**),after(N)))

    static func htlcClaimPolicy(hashLock: String, timeoutBlocks: Int, masterFP: String, keyOrigin: String, receiverXpub: String, senderXpub: String) -> Policy {
        Policy(
            name: "HTLC Claim",
            descriptorTemplate: "wsh(andor(pk(@0/**),sha256(\(hashLock)),and_v(v:pk(@1/**),after(\(timeoutBlocks)))))",
            keysInfo: [
                "[\(masterFP)/\(keyOrigin)]\(receiverXpub)",  // @0 = receiver (internal, claiming)
                senderXpub                                       // @1 = sender (external)
            ]
        )
    }

    static func htlcRefundPolicy(hashLock: String, timeoutBlocks: Int, masterFP: String, keyOrigin: String, senderXpub: String, receiverXpub: String) -> Policy {
        Policy(
            name: "HTLC Refund",
            descriptorTemplate: "wsh(andor(pk(@1/**),sha256(\(hashLock)),and_v(v:pk(@0/**),after(\(timeoutBlocks)))))",
            keysInfo: [
                "[\(masterFP)/\(keyOrigin)]\(senderXpub)",  // @0 = sender (internal, refunding)
                receiverXpub                                    // @1 = receiver (external)
            ]
        )
    }

    // MARK: - Pool (M-of-N multisig)
    // Miniscript: sortedmulti(M,@0/**,@1/**,...,@(N-1)/**)

    static func poolPolicy(m: Int, masterFP: String, keyOrigin: String, internalXpub: String, internalKeyIndex: Int, allXpubs: [String]) -> Policy {
        let keyPlaceholders = (0..<allXpubs.count).map { "@\($0)/**" }.joined(separator: ",")
        let keysInfo = allXpubs.enumerated().map { i, xpub in
            i == internalKeyIndex ? "[\(masterFP)/\(keyOrigin)]\(xpub)" : xpub
        }
        return Policy(
            name: "Pool \(m)-of-\(allXpubs.count)",
            descriptorTemplate: "wsh(sortedmulti(\(m),\(keyPlaceholders)))",
            keysInfo: keysInfo
        )
    }

    // MARK: - Channel (2-of-2 + CLTV refund)
    // Miniscript: or_d(multi(2,@0/**,@1/**),and_v(v:pk(@0/**),after(N)))

    static func channelPolicy(timeoutBlocks: Int, masterFP: String, keyOrigin: String, senderXpub: String, receiverXpub: String) -> Policy {
        Policy(
            name: "Channel",
            descriptorTemplate: "wsh(or_d(multi(2,@0/**,@1/**),and_v(v:pk(@0/**),after(\(timeoutBlocks)))))",
            keysInfo: [
                "[\(masterFP)/\(keyOrigin)]\(senderXpub)",  // @0 = sender (internal)
                receiverXpub                                    // @1 = receiver (external)
            ]
        )
    }
}

// MARK: - Contract Signer
// High-level orchestrator: register wallet if needed, then sign.

struct ContractSigner {

    enum SpendPath {
        case vaultSpend
        case inheritanceKeepAlive
        case inheritanceHeirClaim
        case htlcClaim
        case htlcRefund
        case channelCooperativeClose
        case channelRefund
        case poolSpend
    }

    /// Sign a contract spend via V2 protocol.
    /// Handles wallet registration (if needed) and SIGN_PSBT.
    static func signContractSpend(
        psbtData: Data,
        contract: Contract,
        spendPath: SpendPath,
        witnessScript: Data,
        inputAddressInfos: [LedgerSigningV2.InputAddressInfo] = [],
        isTestnet: Bool
    ) async throws -> (signatures: [Data], updatedContract: Contract) {

        // In demo mode, return simulated signatures
        if DemoMode.shared.isActive || LedgerManager.shared.isDemoMode {
            let dummySig = Data(repeating: 0x30, count: 71) + Data([0x01])
            return ([dummySig], contract)
        }

        guard LedgerManager.shared.state == .connected else {
            throw SigningError.ledgerNotConnected
        }

        // Get signing parameters from keychain
        let coinType = KeychainStore.shared.loadString(forKey: KeychainStore.KeychainKey.ledgerCoinType.rawValue) ?? "0"
        let keyOrigin = "84'/\(coinType)'/0'"

        guard let masterFPData = KeychainStore.shared.load(forKey: KeychainStore.KeychainKey.ledgerMasterFingerprint.rawValue),
              masterFPData.count >= 4 else {
            throw SigningError.missingFingerprint
        }
        let masterFP = masterFPData.prefix(4).hex

        guard let xpub = KeychainStore.shared.loadString(forKey: KeychainStore.KeychainKey.ledgerOriginalXpub.rawValue)
                ?? KeychainStore.shared.loadXpub(isTestnet: isTestnet) else {
            throw SigningError.missingXpub
        }

        // Build the wallet policy for this contract + spend path
        let policy = buildPolicy(contract: contract, spendPath: spendPath, masterFP: masterFP, keyOrigin: keyOrigin, xpub: xpub)

        // Register if we don't have an HMAC for this descriptor
        var updatedContract = contract
        var walletHmac: Data

        if let existingHmac = contract.walletPolicyHmac,
           let hmacData = Data(hex: existingHmac),
           hmacData.count == 32,
           contract.walletPolicyDescriptor == policy.descriptorTemplate {
            // Already registered with matching descriptor
            walletHmac = hmacData
        } else {
            // Need to register
            print("[ContractSigner] Registering wallet policy: \(policy.descriptorTemplate)")
            let (_, hmac) = try await LedgerSigningV2.registerWallet(policy: policy)
            walletHmac = hmac
            updatedContract.walletPolicyHmac = hmac.hex
            updatedContract.walletPolicyDescriptor = policy.descriptorTemplate
            ContractStore.shared.update(updatedContract)
        }

        // Build wallet_id from serialized policy
        let walletId = LedgerSigningV2.computeWalletId(policy: policy)

        // Sign via V2 merkleized PSBT
        let result = try await LedgerSigningV2.signPSBTWithPolicy(
            psbt: psbtData,
            walletPolicy: policy,
            walletId: walletId,
            walletHmac: walletHmac,
            witnessScript: witnessScript,
            masterFP: Data(hex: masterFP) ?? Data(),
            keyOrigin: keyOrigin,
            inputAddressInfos: inputAddressInfos,
            isTestnet: isTestnet
        )

        let signatures = result.map { $0.signature }
        return (signatures, updatedContract)
    }

    // MARK: - Policy Builder

    private static func buildPolicy(contract: Contract, spendPath: SpendPath, masterFP: String, keyOrigin: String, xpub: String) -> WalletPolicyBuilder.Policy {
        switch spendPath {
        case .vaultSpend:
            return WalletPolicyBuilder.vaultPolicy(
                lockBlockHeight: contract.lockBlockHeight ?? 0,
                masterFP: masterFP, keyOrigin: keyOrigin, xpub: xpub
            )

        case .inheritanceKeepAlive:
            return WalletPolicyBuilder.inheritanceOwnerPolicy(
                csvBlocks: contract.csvBlocks ?? 0,
                masterFP: masterFP, keyOrigin: keyOrigin,
                ownerXpub: xpub,
                heirXpub: contract.heirXpub ?? contract.heirPubkey ?? ""
            )

        case .inheritanceHeirClaim:
            return WalletPolicyBuilder.inheritanceHeirPolicy(
                csvBlocks: contract.csvBlocks ?? 0,
                masterFP: masterFP, keyOrigin: keyOrigin,
                ownerXpub: contract.senderXpub ?? contract.ownerPubkey ?? "",
                heirXpub: xpub
            )

        case .htlcClaim:
            return WalletPolicyBuilder.htlcClaimPolicy(
                hashLock: contract.hashLock ?? "",
                timeoutBlocks: contract.timeoutBlocks ?? 0,
                masterFP: masterFP, keyOrigin: keyOrigin,
                receiverXpub: xpub,
                senderXpub: contract.senderXpub ?? contract.senderPubkey ?? ""
            )

        case .htlcRefund:
            return WalletPolicyBuilder.htlcRefundPolicy(
                hashLock: contract.hashLock ?? "",
                timeoutBlocks: contract.timeoutBlocks ?? 0,
                masterFP: masterFP, keyOrigin: keyOrigin,
                senderXpub: xpub,
                receiverXpub: contract.receiverXpub ?? contract.receiverPubkey ?? ""
            )

        case .channelCooperativeClose, .channelRefund:
            return WalletPolicyBuilder.channelPolicy(
                timeoutBlocks: contract.timeoutBlocks ?? 0,
                masterFP: masterFP, keyOrigin: keyOrigin,
                senderXpub: xpub,
                receiverXpub: contract.receiverXpub ?? contract.receiverPubkey ?? ""
            )

        case .poolSpend:
            return WalletPolicyBuilder.poolPolicy(
                m: contract.multisigM ?? 2,
                masterFP: masterFP, keyOrigin: keyOrigin,
                internalXpub: xpub,
                internalKeyIndex: 0,
                allXpubs: contract.multisigXpubs ?? contract.multisigPubkeys ?? []
            )
        }
    }

    // MARK: - Errors

    enum SigningError: LocalizedError {
        case ledgerNotConnected
        case missingFingerprint
        case missingXpub
        case registrationFailed
        case signingFailed(String)

        var errorDescription: String? {
            switch self {
            case .ledgerNotConnected: return "Ledger not connected"
            case .missingFingerprint: return "Master fingerprint missing. Reconnect the Ledger."
            case .missingXpub: return "Xpub missing. Reconnect the Ledger."
            case .registrationFailed: return "Wallet policy registration failed on Ledger"
            case .signingFailed(let msg): return "Signing failed: \(msg)"
            }
        }
    }
}
