import Foundation
import Combine
import UIKit

@MainActor
final class WalletVM: ObservableObject {

    @Published var addresses: [WalletAddress] = []
    @Published var utxos: [UTXO] = []
    @Published var transactions: [Transaction] = []
    @Published var totalBalance: UInt64 = 0
    @Published var isLoading = false
    @Published var error: String?
    @Published var selectedStrategy: CoinSelectionStrategy = .largestFirst

    // Send form
    @Published var sendAddress: String = ""
    @Published var sendAmount: String = ""
    @Published var sendFeeRate: Double = 1.0
    @Published var sendPreview: CoinSelection.SelectionResult?
    @Published var sendError: String?
    @Published var builtPSBTBase64: String?

    // Sign + Broadcast
    @Published var isSigning: Bool = false
    @Published var signedTxHex: String?
    @Published var broadcastTxid: String?
    @Published var sendStep: SendStep = .form
    @Published var currentBlockHeight: Int = 0

    enum SendStep {
        case form       // Filling in fields
        case built      // PSBT constructed
        case signed     // Signed, ready to broadcast
        case broadcast  // Broadcast done
    }

    // Receive
    @Published var currentReceiveAddress: String = ""
    @Published var currentReceiveIndex: UInt32 = 0

    var isTestnet: Bool { NetworkConfig.shared.isTestnet }

    var xpub: ExtendedPublicKey? {
        guard let xpubStr = KeychainStore.shared.loadXpub(isTestnet: isTestnet) else { return nil }
        return ExtendedPublicKey.fromBase58(xpubStr)
    }

    var hasWallet: Bool { xpub != nil }

    // MARK: - Load wallet data

    /// Force re-derivation of addresses (call after Ledger reconnect or xpub change)
    func invalidateAddresses() {
        addresses.removeAll()
        utxos.removeAll()
        currentReceiveAddress = ""
        currentReceiveIndex = 0
        print("[WalletVM] Address cache invalidated — will re-derive on next load")
    }

    /// Track which xpub was used for the current address set
    private var cachedXpubString: String?

    func loadWallet() async {
        guard let xpub = xpub else {
            error = "No xpub found. Connect your Ledger."
            return
        }

        isLoading = true
        error = nil

        // Fetch current block height for fee sniping protection (nLockTime)
        do {
            currentBlockHeight = try await MempoolAPI.shared.getBlockHeight()
        } catch {
            print("[WalletVM] Could not fetch block height: \(error)")
        }

        // Skip re-derivation if addresses already loaded AND xpub hasn't changed
        let currentXpubStr = KeychainStore.shared.loadXpub(isTestnet: isTestnet)
        if !addresses.isEmpty && cachedXpubString == currentXpubStr {
            await refreshUTXOs()
            return
        }

        // xpub changed or first load — re-derive
        if !addresses.isEmpty {
            addresses.removeAll()
            utxos.removeAll()
        }
        cachedXpubString = currentXpubStr

        // Derive addresses off main thread (EC arithmetic is CPU-heavy)
        // Use 5 addresses for faster loading; scan more on demand
        let isTest = isTestnet
        let xpubCopy = xpub
        let addrCount: UInt32 = 5
        let (receiving, change) = await Task.detached(priority: .userInitiated) {
            let recv = AddressDerivation.deriveAddresses(
                xpub: xpubCopy, change: 0, startIndex: 0, count: addrCount, isTestnet: isTest
            )
            let chg = AddressDerivation.deriveAddresses(
                xpub: xpubCopy, change: 1, startIndex: 0, count: addrCount, isTestnet: isTest
            )
            return (recv, chg)
        }.value

        addresses = receiving.map { WalletAddress(index: $0.index, address: $0.address, publicKey: $0.publicKey.hex, isChange: false) }
            + change.map { WalletAddress(index: $0.index, address: $0.address, publicKey: $0.publicKey.hex, isChange: true) }

        // Set receive address to first unused
        if let firstUnused = addresses.first(where: { !$0.isChange }) {
            currentReceiveAddress = firstUnused.address
            currentReceiveIndex = firstUnused.index
        }

        // Fetch UTXOs for all addresses (parallel)
        let addrList = addresses
        let (allUTXOs, allTxs): ([UTXO], [Transaction]) = await withTaskGroup(of: (utxos: [UTXO], txs: [Transaction]).self) { group in
            for addr in addrList {
                group.addTask {
                    do {
                        async let u = MempoolAPI.shared.getAddressUTXOs(address: addr.address)
                        async let t = MempoolAPI.shared.getAddressTransactions(address: addr.address)
                        return (try await u, try await t)
                    } catch {
                        return ([], [])
                    }
                }
            }
            var utxos: [UTXO] = []
            var txs: [Transaction] = []
            for await result in group {
                utxos.append(contentsOf: result.utxos)
                txs.append(contentsOf: result.txs)
            }
            return (utxos, txs)
        }

        // Deduplicate transactions
        var seen = Set<String>()
        let dedupedTxs = allTxs.filter { seen.insert($0.txid).inserted }

        utxos = allUTXOs
        transactions = dedupedTxs.sorted { ($0.status.blockTime ?? Int.max) > ($1.status.blockTime ?? Int.max) }
        totalBalance = allUTXOs.reduce(0) { $0 + $1.value }

        // Update current receive address to first unused
        await findNextReceiveAddress()

        isLoading = false
    }

    // MARK: - Refresh UTXOs only (no re-derivation)

    private func refreshUTXOs() async {
        isLoading = true
        let addrList = addresses
        let (allUTXOs, allTxs): ([UTXO], [Transaction]) = await withTaskGroup(of: (utxos: [UTXO], txs: [Transaction]).self) { group in
            for addr in addrList {
                group.addTask {
                    do {
                        async let u = MempoolAPI.shared.getAddressUTXOs(address: addr.address)
                        async let t = MempoolAPI.shared.getAddressTransactions(address: addr.address)
                        return (try await u, try await t)
                    } catch {
                        return ([], [])
                    }
                }
            }
            var utxos: [UTXO] = []
            var txs: [Transaction] = []
            for await result in group {
                utxos.append(contentsOf: result.utxos)
                txs.append(contentsOf: result.txs)
            }
            return (utxos, txs)
        }

        var seen = Set<String>()
        let dedupedTxs = allTxs.filter { seen.insert($0.txid).inserted }
        utxos = allUTXOs
        transactions = dedupedTxs.sorted { ($0.status.blockTime ?? Int.max) > ($1.status.blockTime ?? Int.max) }
        totalBalance = allUTXOs.reduce(0) { $0 + $1.value }
        isLoading = false
    }

    // MARK: - Find next unused address

    private func findNextReceiveAddress() async {
        guard let xpub = xpub else { return }

        let receivingAddresses = addresses.filter { !$0.isChange }
        for addr in receivingAddresses {
            let hasActivity = utxos.contains { $0.address == addr.address } ||
                              transactions.contains { tx in
                                  tx.vout.contains { $0.scriptpubkeyAddress == addr.address }
                              }
            if !hasActivity {
                currentReceiveAddress = addr.address
                currentReceiveIndex = addr.index
                return
            }
        }

        // All addresses used - derive next batch
        let nextIndex = (receivingAddresses.last?.index ?? 0) + 1
        let newAddrs = AddressDerivation.deriveAddresses(
            xpub: xpub, change: 0, startIndex: nextIndex, count: 1, isTestnet: isTestnet
        )
        if let newAddr = newAddrs.first {
            currentReceiveAddress = newAddr.address
            currentReceiveIndex = newAddr.index
        }
    }

    // MARK: - Send preview

    func previewSend() {
        guard let amount = UInt64(sendAmount), amount > 0 else {
            sendPreview = nil
            return
        }

        let frozenSet = FrozenUTXOStore.shared.frozenOutpoints
        sendPreview = CoinSelection.select(
            from: utxos,
            target: amount,
            feeRate: sendFeeRate,
            strategy: selectedStrategy,
            frozenOutpoints: frozenSet
        )
    }

    // MARK: - Build PSBT for sending

    func buildSendPSBT() -> Data? {
        guard let preview = sendPreview,
              let destScript = PSBTBuilder.scriptPubKeyFromAddress(sendAddress, isTestnet: isTestnet) else {
            return nil
        }

        // Get master fingerprint for BIP32 derivation
        let masterFP = KeychainStore.shared.load(forKey: KeychainStore.KeychainKey.ledgerMasterFingerprint.rawValue) ?? Data([0x00, 0x00, 0x00, 0x00])

        var inputs: [PSBTBuilder.TxInput] = []
        for utxo in preview.selectedUTXOs {
            guard let txidData = Data(hex: utxo.txid) else { continue }
            let txidInternal = Data(txidData.reversed())

            // Find wallet address for this UTXO to get pubkey and derivation path
            let walletAddr = addresses.first(where: { $0.address == utxo.address })
            let pubkeyData = walletAddr.flatMap { Data(hex: $0.publicKey) }
            let change: UInt32 = walletAddr?.isChange == true ? 1 : 0
            let addrIndex: UInt32 = walletAddr?.index ?? 0

            // Build witness UTXO: value(8 LE) + scriptPubKey
            var witnessUtxoOutput: PSBTBuilder.TxOutput? = nil
            if let pk = pubkeyData {
                let pubkeyHash = Crypto.hash160(pk)
                var spk = Data([0x00, 0x14]) // OP_0 + PUSH_20 (P2WPKH)
                spk.append(pubkeyHash)
                witnessUtxoOutput = PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk)
            }

            // Build BIP32 derivation: m/84'/coin_type'/0'/change/index
            // coin_type matches what the Ledger app expects (0 for Bitcoin, 1 for Bitcoin Test)
            let psbtCoinType = UInt32(KeychainStore.shared.loadString(forKey: KeychainStore.KeychainKey.ledgerCoinType.rawValue) ?? "0") ?? 0
            var bip32: [(pubkey: Data, fingerprint: Data, path: [UInt32])]? = nil
            if let pk = pubkeyData {
                bip32 = [(
                    pubkey: pk,
                    fingerprint: masterFP,
                    path: [UInt32(84) | 0x80000000, psbtCoinType | 0x80000000, UInt32(0) | 0x80000000, change, addrIndex]
                )]
            }

            inputs.append(PSBTBuilder.TxInput(
                txid: txidInternal,
                vout: UInt32(utxo.vout),
                sequence: 0xFFFFFFFD, // Enable RBF
                witnessUtxo: witnessUtxoOutput,
                bip32Derivation: bip32
            ))
        }

        var outputs: [PSBTBuilder.TxOutput] = []

        // Payment output
        outputs.append(PSBTBuilder.TxOutput(
            value: UInt64(sendAmount) ?? 0,
            scriptPubKey: destScript
        ))

        // Change output
        if preview.hasChange {
            // Get change address
            let changeAddr = addresses.first { $0.isChange }
            if let addr = changeAddr,
               let changeScript = PSBTBuilder.scriptPubKeyFromAddress(addr.address, isTestnet: isTestnet) {
                outputs.append(PSBTBuilder.TxOutput(
                    value: preview.change,
                    scriptPubKey: changeScript
                ))
            }
        }

        // Fee sniping defense: set nLockTime to current block height for standard P2WPKH sends.
        // This prevents miners from replaying transactions in reorganized blocks (Mastering Bitcoin Ch. 9).
        let locktime = currentBlockHeight > 0 ? UInt32(currentBlockHeight) : 0
        return PSBTBuilder.buildPSBT(inputs: inputs, outputs: outputs, locktime: locktime)
    }

    /// Build PSBT with full error reporting
    func buildAndPreview() {
        sendError = nil
        builtPSBTBase64 = nil

        // 1. Validate address
        guard !sendAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sendError = "Destination address required"
            return
        }

        let addr = sendAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PSBTBuilder.scriptPubKeyFromAddress(addr, isTestnet: isTestnet) != nil else {
            sendError = "Invalid address. Use a \(isTestnet ? "tb1..." : "bc1...") address"
            return
        }

        // 2. Validate amount
        guard let amount = UInt64(sendAmount), amount > 0 else {
            sendError = "Invalid amount"
            return
        }

        guard amount >= 546 else {
            sendError = "Amount below dust threshold (546 sats)"
            return
        }

        // 3. Check UTXOs
        guard !utxos.isEmpty else {
            sendError = "No UTXOs available"
            return
        }

        let totalAvailable = utxos.reduce(UInt64(0)) { $0 + $1.value }
        guard amount <= totalAvailable else {
            sendError = "Insufficient funds (\(totalAvailable) sats available, \(amount) requested)"
            return
        }

        // 4. Coin selection
        previewSend()
        guard let preview = sendPreview else {
            sendError = "Unable to select UTXOs. Try a different amount or strategy."
            return
        }

        // 4b. Transaction pinning warning — check unconfirmed UTXOs in selection
        let unconfirmedCount = preview.selectedUTXOs.filter { !$0.status.confirmed }.count
        if unconfirmedCount > 20 {
            sendError = "Warning: \(unconfirmedCount) unconfirmed UTXOs. Risk of transaction pinning. Wait for confirmations."
            return
        }
        if unconfirmedCount > 5 {
            // Show warning but don't block the transaction
            print("[WalletVM] Warning: \(unconfirmedCount) unconfirmed UTXOs in selection")
        }

        // 4c. Dust output warning on change
        if preview.hasChange && preview.change > 0 && preview.change < 546 {
            sendError = "The change amount (\(preview.change) sats) is below the dust threshold (546 sats). It will be lost to fees."
            return
        }

        // 5. Build PSBT
        guard let psbt = buildSendPSBT() else {
            sendError = "Error building PSBT"
            return
        }

        builtPSBTBase64 = psbt.base64EncodedString()
        sendStep = .built
    }

    // MARK: - Sign via Ledger

    func signAndPrepare() async {
        guard let psbtBase64 = builtPSBTBase64,
              let psbtData = Data(base64Encoded: psbtBase64) else {
            sendError = "No PSBT to sign"
            return
        }

        isSigning = true
        sendError = nil

        // Check if real Ledger is physically connected via BLE
        let hasPhysicalLedger = LedgerManager.shared.state == .connected
            && LedgerManager.shared.connectedDevice != nil

        // If a real Ledger is connected, always use it (override demo mode)
        if hasPhysicalLedger {
            print("[WalletVM] Real Ledger detected — using hardware signing")
        } else {
            print("[WalletVM] No physical Ledger — using simulated signing")
        }

        do {
            let signatures: [Data]
            var inputAddressInfosForWitness: [LedgerSigningV2.InputAddressInfo] = []

            if hasPhysicalLedger {
                // Real Ledger v2 signing
                print("[WalletVM] Signing with real Ledger v2...")

                // Detect Ledger Bitcoin app version to choose protocol
                var useProtocolV1 = true // default to v1 for updated firmware
                do {
                    let (appName, appVersion) = try await LedgerManager.shared.getAppAndVersion()
                    print("[WalletVM] Ledger app: \(appName) v\(appVersion)")
                    // Parse version: "2.4.5" → major=2, minor=4
                    let parts = appVersion.split(separator: ".").compactMap { Int($0) }
                    if parts.count >= 2 {
                        let major = parts[0]
                        let minor = parts[1]
                        // Protocol v1 requires firmware >= 2.1.0
                        useProtocolV1 = major > 2 || (major == 2 && minor >= 1)
                        print("[WalletVM] Protocol version: v\(useProtocolV1 ? "1" : "0") (app \(major).\(minor))")
                    }
                } catch {
                    print("[WalletVM] Could not detect app version: \(error), defaulting to protocol v1")
                }

                // Master fingerprint already saved to keychain during xpub retrieval
                if let savedFP = KeychainStore.shared.load(forKey: KeychainStore.KeychainKey.ledgerMasterFingerprint.rawValue) {
                    print("[WalletVM] Using saved master fingerprint: \(savedFP.hex)")
                }

                // Determine coin_type from what the Ledger app actually uses
                // Bitcoin mainnet app: coin_type=0, Bitcoin Test app: coin_type=1
                let savedCoinType = KeychainStore.shared.loadString(forKey: KeychainStore.KeychainKey.ledgerCoinType.rawValue) ?? "0"
                let coinType = savedCoinType == "1" ? 1 : 0
                let keyOrigin = "84'/\(coinType)'/0'"
                print("[WalletVM] Using key origin: \(keyOrigin) (coin_type=\(coinType))")

                // Use the ORIGINAL xpub from Ledger for wallet policy
                let xpubStr = KeychainStore.shared.loadString(forKey: KeychainStore.KeychainKey.ledgerOriginalXpub.rawValue)
                    ?? KeychainStore.shared.loadXpub(isTestnet: isTestnet) ?? ""
                print("[WalletVM] Using xpub for signing: \(xpubStr.prefix(20))...")

                // Build per-input address info for correct BIP32 derivation paths
                var inputAddressInfos = inputAddressInfosForWitness
                if let preview = sendPreview {
                    for utxo in preview.selectedUTXOs {
                        // Find the wallet address that matches this UTXO
                        if let walletAddr = addresses.first(where: { $0.address == utxo.address }),
                           let pubkeyData = Data(hex: walletAddr.publicKey) {
                            // Build scriptPubKey for P2WPKH: OP_0 PUSH_20 HASH160(pubkey)
                            let pubkeyHash = Crypto.hash160(pubkeyData)
                            var spk = Data([0x00, 0x14]) // OP_0 + PUSH_20
                            spk.append(pubkeyHash)

                            inputAddressInfos.append(LedgerSigningV2.InputAddressInfo(
                                change: walletAddr.isChange ? 1 : 0,
                                index: walletAddr.index,
                                publicKey: pubkeyData,
                                value: utxo.value,
                                scriptPubKey: spk
                            ))
                            print("[WalletVM] Input UTXO \(utxo.outpoint): \(utxo.value) sats, addr=\(walletAddr.address.prefix(20))... change=\(walletAddr.isChange ? 1 : 0) index=\(walletAddr.index)")
                        } else {
                            print("[WalletVM] WARNING: Could not find wallet address for UTXO \(utxo.outpoint) at \(utxo.address)")
                        }
                    }
                }

                inputAddressInfosForWitness = inputAddressInfos
                let descriptor = "wpkh(@0)"  // signPSBT will adjust for protocol version

                let result = try await LedgerSigningV2.signPSBT(
                    psbt: psbtData,
                    walletPolicy: descriptor,
                    keyOrigin: keyOrigin,
                    xpub: xpubStr,
                    inputAddressInfos: inputAddressInfos,
                    useProtocolV1: useProtocolV1
                )

                signatures = result.map { $0.signature }
                print("[WalletVM] Got \(signatures.count) signatures from Ledger")
            } else {
                // Demo mode: simulate signatures
                print("[WalletVM] Simulating signatures (no Ledger connected)")
                let inputCount = countPSBTInputs(psbtData)
                var sigs: [Data] = []
                for _ in 0..<max(inputCount, 1) {
                    var fakeSig = Data([0x30, 0x44, 0x02, 0x20])
                    fakeSig.append(Data(repeating: 0xAB, count: 32))
                    fakeSig.append(Data([0x02, 0x20]))
                    fakeSig.append(Data(repeating: 0xCD, count: 32))
                    fakeSig.append(Data([0x01]))
                    sigs.append(fakeSig)
                }
                signatures = sigs
            }

            // Build witness stacks with per-input pubkeys
            // For real Ledger signing, use the per-input address info pubkeys
            // For demo mode, derive the first pubkey as fallback
            var perInputPubkeys: [Data] = []

            if hasPhysicalLedger && !inputAddressInfosForWitness.isEmpty {
                perInputPubkeys = inputAddressInfosForWitness.map { $0.publicKey }
            }

            if perInputPubkeys.isEmpty {
                guard let xpubKey = xpub else {
                    sendError = "xpub not found"
                    isSigning = false
                    return
                }
                let xpubCopy = xpubKey
                let fallbackPubkey: Data = await Task.detached {
                    let changeLevelKey = xpubCopy.deriveChild(index: 0)
                    let firstKey = changeLevelKey?.deriveChild(index: 0)
                    return firstKey?.key ?? Data()
                }.value
                perInputPubkeys = signatures.map { _ in fallbackPubkey }
            }

            // P2WPKH witness: [signature, pubkey]
            let witnessStacks: [[Data]] = signatures.enumerated().map { (i, sig) in
                let pk = i < perInputPubkeys.count ? perInputPubkeys[i] : perInputPubkeys.last ?? Data()
                return [sig, pk]
            }

            guard let finalTx = SpendManager.finalizePSBT(
                psbtData: psbtData,
                witnessStacks: witnessStacks
            ) else {
                sendError = "Error during finalization"
                isSigning = false
                return
            }

            let validation = SpendManager.validateTransaction(finalTx)
            guard validation.valid else {
                sendError = "Invalid transaction: \(validation.reason)"
                isSigning = false
                return
            }

            signedTxHex = SpendManager.extractTransactionHex(finalTx)
            sendStep = .signed

        } catch {
            sendError = error.localizedDescription
        }

        isSigning = false
    }

    /// Count inputs in a PSBT's unsigned transaction
    private func countPSBTInputs(_ psbtData: Data) -> Int {
        guard let parsed = PSBTBuilder.parsePSBT(psbtData),
              let unsignedTx = parsed.unsignedTx,
              unsignedTx.count > 4 else { return 1 }
        guard let (count, _) = VarInt.decode(unsignedTx, offset: 4) else { return 1 }
        return Int(count)
    }

    // MARK: - Broadcast

    func broadcastTransaction() async {
        guard let txHex = signedTxHex else {
            sendError = "No transaction to broadcast"
            return
        }

        isSigning = true
        sendError = nil

        do {
            let txid = try await SpendManager.broadcast(txHex: txHex)
            broadcastTxid = txid
            sendStep = .broadcast

            // Refresh wallet
            await loadWallet()
        } catch {
            sendError = error.localizedDescription
        }

        isSigning = false
    }

    /// Reset send form
    func resetSend() {
        sendAddress = ""
        sendAmount = ""
        sendFeeRate = 1.0
        sendPreview = nil
        sendError = nil
        builtPSBTBase64 = nil
        signedTxHex = nil
        broadcastTxid = nil
        sendStep = .form
    }

    // MARK: - UTXO management

    func toggleFreeze(outpoint: String) {
        FrozenUTXOStore.shared.toggle(outpoint: outpoint)
    }

    func isFrozen(outpoint: String) -> Bool {
        FrozenUTXOStore.shared.isFrozen(outpoint: outpoint)
    }

    // MARK: - Labels

    func setLabel(_ label: String, forTxid txid: String) {
        TxLabelStore.shared.setLabel(label, forTxid: txid)
    }

    func label(forTxid txid: String) -> String? {
        TxLabelStore.shared.label(forTxid: txid)
    }
}
