import Foundation
import SwiftUI
import Combine

@MainActor
final class AtomicSwapVM: ObservableObject {

    // MARK: - Role & Step

    enum Role: String, CaseIterable {
        case initiator = "Initiator"
        case responder = "Responder"
    }

    enum SwapStep: String {
        case setup
        case created          // Initiator: HTLC created, showing QR
        case waitingCounterparty // Waiting for counterparty action
        case funded           // Both HTLCs funded
        case claiming         // Claiming in progress
        case complete
    }

    @Published var role: Role = .initiator
    @Published var step: SwapStep = .setup

    // MARK: - Form inputs (Initiator)

    @Published var name: String = ""
    @Published var counterpartyXpub: String = ""
    @Published var myAmount: String = ""        // sats I'm locking
    @Published var requestedAmount: String = "" // sats I want from counterparty
    @Published var timeoutBlocks: String = ""
    @Published var keyIndex: UInt32 = 0

    // MARK: - Responder inputs

    @Published var offerString: String = ""     // Pasted/scanned SwapOffer base64
    @Published var decodedOffer: SwapOffer?
    @Published var responderTimeoutBlocks: String = ""

    // MARK: - State

    @Published var swapOffer: SwapOffer?        // Generated offer (initiator)
    @Published var swapOfferEncoded: String = "" // Base64 for QR
    @Published var myContract: Contract?
    @Published var counterpartyAddress: String = "" // Counterparty's HTLC address (entered manually)
    @Published var myFundingStatus: String = ""
    @Published var counterpartyFundingStatus: String = ""
    @Published var extractedPreimage: String = ""

    @Published var currentBlockHeight: Int = 0
    @Published var isLoading = false
    @Published var error: String?
    @Published var claimTxid: String?

    var isTestnet: Bool { NetworkConfig.shared.isTestnet }

    // MARK: - Polling

    private var pollTimer: Timer?

    // MARK: - Lifecycle

    func loadBlockHeight() async {
        do {
            currentBlockHeight = try await MempoolAPI.shared.getBlockHeight()
        } catch {
            #if DEBUG
            print("[AtomicSwap] Failed to fetch block height: \(error)")
            #endif
        }
    }

    // MARK: - Initiator: Create Swap

    func createInitiatorHTLC() async {
        guard !isLoading else { return }
        guard !name.isEmpty,
              let timeout = Int(timeoutBlocks), timeout > currentBlockHeight,
              !counterpartyXpub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Invalid parameters"
            return
        }

        isLoading = true
        error = nil

        guard let xpubStr = KeychainStore.shared.loadXpub(isTestnet: isTestnet),
              let xpub = ExtendedPublicKey.fromBase58(xpubStr) else {
            error = "Unable to derive public key"
            isLoading = false
            return
        }

        let counterpartyInput = counterpartyXpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let isTest = isTestnet
        let tb = Int64(timeout)
        let kIdx = keyIndex

        guard let result = await Task.detached(priority: .userInitiated) { () -> (Data, Data, String, Data, Data, Data, Data)? in
            guard let derivedKey = xpub.derivePath([0, kIdx]) else { return nil }
            let senderPubkey = derivedKey.key

            let receiverKey: Data
            if let rxpub = ExtendedPublicKey.fromBase58(counterpartyInput),
               let derived = rxpub.derivePath([0, 0]) {
                receiverKey = derived.key
            } else if let hexData = Data(hex: counterpartyInput), hexData.count == 33 {
                receiverKey = hexData
            } else {
                return nil
            }

            guard let preimage = HTLCBuilder.generatePreimage() else { return nil }
            let hashLockData = HTLCBuilder.hashPreimage(preimage)

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
        let amountSats = UInt64(myAmount) ?? 0
        let reqAmount = UInt64(requestedAmount) ?? 0

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

        if ExtendedPublicKey.fromBase58(counterpartyInput) != nil {
            contract.receiverXpub = counterpartyInput
        }

        // Swap metadata
        let swapId = UUID().uuidString
        contract.swapId = swapId
        contract.swapRole = "initiator"
        contract.swapState = "created"
        contract.keyIndex = keyIndex

        // Save preimage
        KeychainStore.shared.saveString(preimage.hex, forKey: "htlc_preimage_\(contract.id)")

        ContractStore.shared.add(contract)
        myContract = contract

        // Build swap offer
        let suggestedTimeout = currentBlockHeight + (timeout - currentBlockHeight) / 2
        let offer = SwapOffer(
            version: 1,
            hashLock: hashLockData.hex,
            initiatorHTLCAddress: address,
            initiatorAmount: amountSats,
            initiatorTimeout: timeout,
            initiatorXpub: xpubStr,
            requestedAmount: reqAmount,
            suggestedTimeout: suggestedTimeout,
            network: isTestnet ? "testnet" : "mainnet",
            keyIndex: keyIndex
        )
        swapOffer = offer
        swapOfferEncoded = AtomicSwapUtil.encodeOffer(offer) ?? ""

        step = .created
        isLoading = false
    }

    // MARK: - Responder: Decode & Verify Offer

    func decodeOffer() {
        let trimmed = offerString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Paste a swap offer"
            return
        }
        guard let offer = AtomicSwapUtil.decodeOffer(trimmed) else {
            error = "Invalid swap offer format"
            return
        }

        // Network check
        let expectedNetwork = isTestnet ? "testnet" : "mainnet"
        guard offer.network == expectedNetwork else {
            error = "Network mismatch: offer is for \(offer.network), you're on \(expectedNetwork)"
            return
        }

        decodedOffer = offer
        responderTimeoutBlocks = "\(offer.suggestedTimeout)"
        error = nil
    }

    func verifyInitiatorFunding() async {
        guard let offer = decodedOffer else { return }
        isLoading = true
        do {
            let utxos = try await MempoolAPI.shared.getAddressUTXOs(address: offer.initiatorHTLCAddress)
            let funded = utxos.reduce(UInt64(0)) { $0 + $1.value }
            if funded >= offer.initiatorAmount {
                counterpartyFundingStatus = "Funded: \(BalanceUnit.format(funded)) sats"
            } else if funded > 0 {
                counterpartyFundingStatus = "Partially funded: \(BalanceUnit.format(funded)) / \(BalanceUnit.format(offer.initiatorAmount)) sats"
            } else {
                counterpartyFundingStatus = "Not yet funded"
            }
        } catch {
            counterpartyFundingStatus = "Error checking: \(error.localizedDescription)"
        }
        isLoading = false
    }

    // MARK: - Responder: Create HTLC

    func createResponderHTLC() async {
        guard let offer = decodedOffer else { return }
        guard !isLoading else { return }
        guard let respTimeout = Int(responderTimeoutBlocks), respTimeout > currentBlockHeight else {
            error = "Invalid timeout"
            return
        }

        // Safety: responder timeout must be less than initiator's
        guard AtomicSwapUtil.validateTimeouts(
            initiatorTimeout: offer.initiatorTimeout,
            responderTimeout: respTimeout,
            currentBlockHeight: currentBlockHeight
        ) else {
            error = "Unsafe timeouts: your timeout must be at most half of the initiator's window"
            return
        }

        isLoading = true
        error = nil

        guard let xpubStr = KeychainStore.shared.loadXpub(isTestnet: isTestnet),
              let xpub = ExtendedPublicKey.fromBase58(xpubStr) else {
            error = "Unable to derive public key"
            isLoading = false
            return
        }

        let hashLockHex = offer.hashLock
        let initiatorXpubStr = offer.initiatorXpub
        let isTest = isTestnet
        let tb = Int64(respTimeout)
        let kIdx = keyIndex

        guard let result = await Task.detached(priority: .userInitiated) { () -> (Data, Data, String, Data, Data, Data)? in
            guard let derivedKey = xpub.derivePath([0, kIdx]) else { return nil }
            let senderPubkey = derivedKey.key // responder is the "sender" of their HTLC

            // Initiator is the "receiver" of responder's HTLC
            let receiverKey: Data
            if let ixpub = ExtendedPublicKey.fromBase58(initiatorXpubStr),
               let derived = ixpub.derivePath([0, 0]) {
                receiverKey = derived.key
            } else {
                return nil
            }

            guard let hashLockData = Data(hex: hashLockHex) else { return nil }

            let script = HTLCBuilder.htlcScript(
                receiverPubkey: receiverKey,
                senderPubkey: senderPubkey,
                hashLock: hashLockData,
                timeoutBlocks: tb
            )
            guard let address = script.p2wshAddress(isTestnet: isTest) else { return nil }
            return (script.script, script.witnessScriptHash, address, senderPubkey, receiverKey, hashLockData)
        }.value else {
            error = "Unable to generate contract"
            isLoading = false
            return
        }

        let (scriptData, witnessHash, address, senderKey, receiverKey, hashLockData) = result

        var contract = Contract.newHTLC(
            name: "Swap: \(offer.initiatorHTLCAddress.prefix(8))...",
            script: scriptData,
            witnessScript: witnessHash,
            address: address,
            hashLock: hashLockData,
            senderPubkey: senderKey,
            receiverPubkey: receiverKey,
            timeoutBlocks: respTimeout,
            amount: offer.requestedAmount,
            isTestnet: isTestnet
        )

        contract.receiverXpub = initiatorXpubStr
        contract.swapId = UUID().uuidString
        contract.swapRole = "responder"
        contract.swapState = "created"
        contract.counterpartyHTLCAddress = offer.initiatorHTLCAddress
        contract.keyIndex = keyIndex

        ContractStore.shared.add(contract)
        myContract = contract
        step = .created
        isLoading = false
    }

    // MARK: - Polling for counterparty activity

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollStatus()
            }
        }
        // Immediate first poll
        Task { await pollStatus() }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollStatus() async {
        // Check counterparty funding
        if !counterpartyAddress.isEmpty {
            do {
                let utxos = try await MempoolAPI.shared.getAddressUTXOs(address: counterpartyAddress)
                let funded = utxos.reduce(UInt64(0)) { $0 + $1.value }
                if funded > 0 {
                    counterpartyFundingStatus = "Funded: \(BalanceUnit.format(funded)) sats"
                }
            } catch {}
        }

        // Check my HTLC funding
        if let contract = myContract {
            do {
                let utxos = try await MempoolAPI.shared.getAddressUTXOs(address: contract.address)
                let funded = utxos.reduce(UInt64(0)) { $0 + $1.value }
                if funded > 0 {
                    myFundingStatus = "Funded: \(BalanceUnit.format(funded)) sats"
                }
            } catch {}
        }

        // Responder: check if initiator claimed (preimage revealed)
        if role == .responder, let contract = myContract, let hashLock = contract.hashLock {
            do {
                let txs = try await MempoolAPI.shared.getAddressTransactions(address: contract.address)
                // Look for spending transactions (not funding)
                for tx in txs {
                    if let preimage = AtomicSwapUtil.extractPreimageFromTransaction(tx, expectedHashLock: hashLock) {
                        extractedPreimage = preimage.hex
                        step = .funded
                        stopPolling()
                        return
                    }
                }
            } catch {}
        }
    }

    // MARK: - Claim (uses existing HTLC claim infrastructure)

    func claimCounterpartyHTLC(destinationAddress: String) async {
        guard !counterpartyAddress.isEmpty || myContract?.counterpartyHTLCAddress != nil else {
            error = "No counterparty address"
            return
        }

        let targetAddress = myContract?.counterpartyHTLCAddress ?? counterpartyAddress

        // For initiator: use stored preimage
        // For responder: use extracted preimage
        let preimageHex: String
        if role == .initiator, let contract = myContract {
            guard let stored = KeychainStore.shared.loadString(forKey: "htlc_preimage_\(contract.id)") else {
                error = "Preimage not found"
                return
            }
            preimageHex = stored
        } else {
            guard !extractedPreimage.isEmpty else {
                error = "Preimage not yet extracted"
                return
            }
            preimageHex = extractedPreimage
        }

        // We need the counterparty's contract to claim it
        // For now, the claim is done through the regular HTLC claim flow
        // The user will need to use the HTLC view's claim function with the preimage
        // This is a simplified path — the full implementation would build the PSBT here
        claimTxid = "Use HTLC Claim with preimage: \(preimageHex.prefix(16))..."
        step = .complete

        // Update swap state
        if var contract = myContract {
            contract.swapState = "completed"
            ContractStore.shared.update(contract)
            myContract = contract
        }
    }

    // MARK: - Reset

    func reset() {
        step = .setup
        name = ""
        counterpartyXpub = ""
        myAmount = ""
        requestedAmount = ""
        timeoutBlocks = ""
        offerString = ""
        decodedOffer = nil
        responderTimeoutBlocks = ""
        swapOffer = nil
        swapOfferEncoded = ""
        myContract = nil
        counterpartyAddress = ""
        myFundingStatus = ""
        counterpartyFundingStatus = ""
        extractedPreimage = ""
        error = nil
        claimTxid = nil
        stopPolling()
    }
}
