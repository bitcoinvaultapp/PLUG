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
    @Published var scanProgress: Double = 0
    @Published var scanStatus: String?
    var hasLoadedOnce = false
    @Published var selectedStrategy: CoinSelectionStrategy = .largestFirst

    // Send form
    @Published var sendAddress: String = ""
    @Published var sendAmount: String = ""
    @Published var sendFeeRate: Double = 1.0
    @Published var sendPreview: CoinSelection.SelectionResult?
    @Published var sendError: String?
    @Published var builtPSBTBase64: String?

    // Coin control
    @Published var coinControlEnabled: Bool = false
    @Published var manuallySelectedOutpoints: Set<String> = []  // "txid:vout"

    /// UTXOs selected by coin control (excluding frozen)
    var coinControlUTXOs: [UTXO] {
        utxos.filter { manuallySelectedOutpoints.contains($0.outpoint) && !isFrozen(outpoint: $0.outpoint) }
    }

    /// Total of manually selected UTXOs
    var coinControlTotal: UInt64 {
        coinControlUTXOs.reduce(0) { $0 + $1.value }
    }

    func toggleUTXOSelection(outpoint: String) {
        if manuallySelectedOutpoints.contains(outpoint) {
            manuallySelectedOutpoints.remove(outpoint)
        } else {
            manuallySelectedOutpoints.insert(outpoint)
        }
    }

    func isUTXOSelected(outpoint: String) -> Bool {
        manuallySelectedOutpoints.contains(outpoint)
    }

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
    /// Max address index the user can pick (derived from scan)
    var maxAddressIndex: UInt32 {
        let maxScanned = addresses.filter { !$0.isChange }.map { $0.index }.max() ?? 19
        return max(maxScanned, 19)
    }

    // Address status tracking (privacy hygiene)
    /// Status for each address: fresh, funded, or used (spent from)
    @Published var addressStatuses: [String: WalletAddress.Status] = [:]

    /// Returns the status of an address based on on-chain activity
    func addressStatus(for address: String) -> WalletAddress.Status {
        addressStatuses[address] ?? .fresh
    }

    /// True if an address has been spent from (pubkey exposed on-chain)
    func isAddressUsed(_ address: String) -> Bool {
        addressStatus(for: address) == .used
    }

    /// Compute address statuses from UTXOs and transactions.
    /// Fresh = no on-chain activity. Funded = has UTXOs. Used = appeared as input (spent from).
    private func updateAddressStatuses() {
        var statuses: [String: WalletAddress.Status] = [:]

        // Collect all addresses that appeared as inputs (spent from → pubkey exposed)
        var spentFromAddresses = Set<String>()
        for tx in transactions {
            for input in tx.vin {
                if let prevAddr = input.prevout?.scriptpubkeyAddress {
                    spentFromAddresses.insert(prevAddr)
                }
            }
        }

        // Track ALL addresses (receiving + change)
        for addr in addresses {
            let hasUtxos = utxos.contains { $0.address == addr.address }
            let wasSpentFrom = spentFromAddresses.contains(addr.address)
            let receivedAnything = transactions.contains { tx in
                tx.vout.contains { $0.scriptpubkeyAddress == addr.address }
            }

            if wasSpentFrom {
                statuses[addr.address] = .used   // Pubkey exposed — never reuse
            } else if hasUtxos {
                statuses[addr.address] = .funded  // Has UTXOs, not yet spent from
            } else if receivedAnything {
                statuses[addr.address] = .used    // Received before but 0 balance
            } else {
                statuses[addr.address] = .fresh   // Never seen on-chain
            }
        }

        addressStatuses = statuses
    }

    /// Derive and select a specific receiving address index
    func selectAddressIndex(_ index: UInt32) {
        guard let xpubStr = KeychainStore.shared.loadXpub(isTestnet: isTestnet),
              let xpub = ExtendedPublicKey.fromBase58(xpubStr) else { return }
        // Check if already derived
        if let existing = addresses.first(where: { !$0.isChange && $0.index == index }) {
            currentReceiveAddress = existing.address
            currentReceiveIndex = existing.index
            return
        }
        // Derive on the fly
        let derived = AddressDerivation.deriveAddresses(
            xpub: xpub, change: 0, startIndex: index, count: 1, isTestnet: isTestnet
        )
        if let d = derived.first {
            let walletAddr = WalletAddress(index: d.index, address: d.address, publicKey: d.publicKey.hex, isChange: false)
            addresses.append(walletAddr)
            currentReceiveAddress = walletAddr.address
            currentReceiveIndex = walletAddr.index
        }
    }

    var isTestnet: Bool { NetworkConfig.shared.isTestnet }

    var xpub: ExtendedPublicKey? {
        guard let xpubStr = KeychainStore.shared.loadXpub(isTestnet: isTestnet) else { return nil }
        return ExtendedPublicKey.fromBase58(xpubStr)
    }

    var hasWallet: Bool { xpub != nil }

    // MARK: - Balance breakdown

    var confirmedBalance: UInt64 {
        utxos.filter { $0.status.confirmed }.reduce(0) { $0 + $1.value }
    }

    var unconfirmedBalance: UInt64 {
        utxos.filter { !$0.status.confirmed }.reduce(0) { $0 + $1.value }
    }

    var dustUtxos: [UTXO] {
        utxos.filter { $0.value < 546 }
    }

    var unconfirmedCount: Int {
        utxos.filter { !$0.status.confirmed }.count
    }

    /// Fee estimation (fetched on refresh)
    @Published var feeEstimate: FeeEstimate?
    /// BTC/USD price (fetched on refresh)
    @Published var btcPrice: Double = 0

    // MARK: - Load wallet data

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Listen for xpub changes (new Ledger connected, different device, etc.)
        NotificationCenter.default.publisher(for: .ledgerXpubChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.invalidateAndReload()
            }
            .store(in: &cancellables)
    }

    /// Full reset: clear all cached data and reload from scratch.
    /// Called when a new Ledger is connected or xpub changes.
    func invalidateAndReload() {
        addresses.removeAll()
        utxos.removeAll()
        transactions.removeAll()
        totalBalance = 0
        currentReceiveAddress = ""
        currentReceiveIndex = 0
        addressStatuses.removeAll()
        cachedXpubString = nil
        hasLoadedOnce = false
        error = nil
        KeychainStore.shared.delete(forKey: KeychainStore.KeychainKey.walletAddresses.rawValue)
        #if DEBUG
        print("[WalletVM] Full wallet reset — xpub changed, will rescan")
        #endif
        Task { await loadWallet() }
    }

    /// Force re-derivation of addresses (call after Ledger reconnect or xpub change)
    func invalidateAddresses() {
        addresses.removeAll()
        utxos.removeAll()
        currentReceiveAddress = ""
        currentReceiveIndex = 0
        #if DEBUG
        print("[WalletVM] Address cache invalidated — will re-derive on next load")
        #endif
    }

    /// Clear all wallet data — called when Ledger disconnects
    func clearWalletData() {
        addresses.removeAll()
        utxos.removeAll()
        transactions.removeAll()
        totalBalance = 0
        currentReceiveAddress = ""
        currentReceiveIndex = 0
        addressStatuses.removeAll()
        cachedXpubString = nil
        error = nil
        isLoading = false
        #if DEBUG
        print("[WalletVM] Wallet data cleared — Ledger disconnected")
        #endif
    }

    /// Force a full gap scan — clears cached addresses and re-derives from xpub.
    /// Use when: addresses seem missing, imported a new xpub, or gap > 20 suspected.
    func rescanWallet() async {
        #if DEBUG
        print("[WalletVM] Manual rescan requested — clearing cache")
        #endif
        hasLoadedOnce = false
        addresses.removeAll()
        utxos.removeAll()
        transactions.removeAll()
        totalBalance = 0
        addressStatuses.removeAll()
        cachedXpubString = nil
        KeychainStore.shared.delete(forKey: KeychainStore.KeychainKey.walletAddresses.rawValue)
        await loadWallet()
    }

    /// Track which xpub was used for the current address set
    private var cachedXpubString: String?

    func loadWallet() async {
        guard let xpub = xpub else {
            error = "No xpub found. Connect your Ledger."
            return
        }

        // Only load once per app session — use "Rescan" in Settings to force
        guard !hasLoadedOnce else {
            #if DEBUG
            print("[WalletVM] loadWallet() skipped — already loaded this session")
            #endif
            return
        }

        // Prevent re-entrant calls
        guard !isLoading else {
            #if DEBUG
            print("[WalletVM] loadWallet() skipped — already loading")
            #endif
            return
        }

        isLoading = true
        error = nil
        #if DEBUG
        print("[WalletVM] loadWallet() starting...")
        #endif

        // Fetch current block height for fee sniping protection (nLockTime)
        do {
            currentBlockHeight = try await MempoolAPI.shared.getBlockHeight()
        } catch {
            #if DEBUG
            print("[WalletVM] Could not fetch block height: \(error)")
            #endif
        }

        // Skip gap scan if addresses already in memory AND xpub unchanged
        let currentXpubStr = KeychainStore.shared.loadXpub(isTestnet: isTestnet)
        if !addresses.isEmpty && cachedXpubString == currentXpubStr {
            await refreshUTXOs()
            return
        }

        // Try loading cached addresses from Keychain (saved after previous gap scan)
        if let cached: [WalletAddress] = KeychainStore.shared.loadCodable(
            forKey: KeychainStore.KeychainKey.walletAddresses.rawValue,
            type: [WalletAddress].self
        ), !cached.isEmpty, cachedXpubString == nil || cachedXpubString == currentXpubStr {
            // Validate cache: P2WPKH addresses are 42-44 chars, P2WSH are 62+
            // If cache contains wrong address types or is too large, discard it
            let validCache = cached.count < 1000 && cached.allSatisfy { $0.address.count < 55 }
            if validCache {
                #if DEBUG
                print("[WalletVM] Loaded \(cached.count) cached addresses — skipping gap scan")
                #endif
                addresses = cached
                cachedXpubString = currentXpubStr

                if let firstUnused = cached.first(where: { !$0.isChange }) {
                    currentReceiveAddress = firstUnused.address
                    currentReceiveIndex = firstUnused.index
                }

                await refreshUTXOs()
                return
            } else {
                #if DEBUG
                print("[WalletVM] Cache invalid (\(cached.count) addrs, types wrong) — clearing and rescanning")
                #endif
                KeychainStore.shared.delete(forKey: KeychainStore.KeychainKey.walletAddresses.rawValue)
            }
        }

        #if DEBUG
        print("[WalletVM] No cached addresses — starting smart scan")
        #endif

        // xpub changed or first load — re-derive
        if !addresses.isEmpty {
            addresses.removeAll()
            utxos.removeAll()
        }
        cachedXpubString = currentXpubStr

        // Smart scan: start with a small probe (5 addresses).
        // If all empty → new wallet, stop immediately.
        // If any have activity → expand to full gap limit scan.
        let isTest = isTestnet
        let xpubCopy = xpub

        // Phase 1: Quick probe — 5 receiving addresses
        let probeCount: UInt32 = 5
        let probeBatch = await Task.detached(priority: .userInitiated) {
            AddressDerivation.deriveAddresses(
                xpub: xpubCopy, change: 0, startIndex: 0, count: probeCount, isTestnet: isTest
            )
        }.value

        let probeAddrs = probeBatch.map { $0.address }
        let probeResult = await UTXOFetchService.fetchUTXOsAndTransactions(for: probeAddrs)
        let hasActivity = !probeResult.utxos.isEmpty || !probeResult.transactions.isEmpty

        if !hasActivity {
            // New wallet — no history. Save the probe addresses + a few change.
            #if DEBUG
            print("[WalletVM] Smart scan: new wallet detected (0 activity in first \(probeCount) addresses)")
            #endif
            let changeProbe = await Task.detached(priority: .userInitiated) {
                AddressDerivation.deriveAddresses(
                    xpub: xpubCopy, change: 1, startIndex: 0, count: probeCount, isTestnet: isTest
                )
            }.value

            addresses = probeBatch.map { WalletAddress(index: $0.index, address: $0.address, publicKey: $0.publicKey.hex, isChange: false) }
                + changeProbe.map { WalletAddress(index: $0.index, address: $0.address, publicKey: $0.publicKey.hex, isChange: true) }

            if let firstAddr = addresses.first(where: { !$0.isChange }) {
                currentReceiveAddress = firstAddr.address
                currentReceiveIndex = firstAddr.index
            }

            KeychainStore.shared.saveCodable(addresses, forKey: KeychainStore.KeychainKey.walletAddresses.rawValue)
            totalBalance = 0
            hasLoadedOnce = true
            isLoading = false
            return
        }

        // Phase 2: Wallet has activity — full gap limit scan
        #if DEBUG
        print("[WalletVM] Smart scan: activity found, expanding to full gap scan")
        #endif
        let gapLimit = 20
        let batchSize: UInt32 = 20

        var allReceiving: [WalletAddress] = []
        var allChange: [WalletAddress] = []
        var allUTXOs: [UTXO] = []
        var allTxs: [Transaction] = []

        // Scan receiving addresses (change=0) with gap limit
        // Batched parallel queries instead of sequential (much faster over Tor)
        var consecutiveEmpty = 0
        var scanIndex: UInt32 = 0
        var consecutiveErrors = 0
        let maxConsecutiveErrors = 40 // Stop after 40 consecutive network errors
        let torActive = plug_tor_is_running()
        let fetchBatchSize = torActive ? 1 : 3  // Serial for Tor (Rust Mutex serializes anyway)
        #if DEBUG
        print("[WalletVM] Starting gap limit scan (gap=\(gapLimit), tor=\(torActive))...")
        #endif

        let maxScanIndex: UInt32 = 500 // Hard cap — never scan beyond index 500
        while consecutiveEmpty < gapLimit && scanIndex < maxScanIndex {
            let startIdx = scanIndex
            let batch = await Task.detached(priority: .userInitiated) {
                AddressDerivation.deriveAddresses(
                    xpub: xpubCopy, change: 0, startIndex: startIdx, count: batchSize, isTestnet: isTest
                )
            }.value

            // Fetch UTXOs + txs in parallel batches (not one-by-one)
            for fetchStart in stride(from: 0, to: batch.count, by: fetchBatchSize) {
                let fetchEnd = min(fetchStart + fetchBatchSize, batch.count)
                let fetchBatch = Array(batch[fetchStart..<fetchEnd])

                let results = await withTaskGroup(of: (UInt32, String, String, [UTXO], [Transaction], Bool).self) { group in
                    for item in fetchBatch {
                        group.addTask {
                            do {
                                let utxos = try await MempoolAPI.shared.getAddressUTXOs(address: item.address)
                                let txs = try await MempoolAPI.shared.getAddressTransactions(address: item.address)
                                return (item.index, item.address, item.publicKey.hex, utxos, txs, true)
                            } catch {
                                #if DEBUG
                                print("[WalletVM] Scan error #\(item.index) \(item.address.prefix(12)): \(error.localizedDescription)")
                                #endif
                                // On Tor error, DON'T count as empty — retry or skip
                                return (item.index, item.address, item.publicKey.hex, [], [], false)
                            }
                        }
                    }
                    var res: [(UInt32, String, String, [UTXO], [Transaction], Bool)] = []
                    for await r in group { res.append(r) }
                    return res.sorted { $0.0 < $1.0 } // sort by index
                }

                for (index, address, pubkey, utxos, txs, success) in results {
                    let walletAddr = WalletAddress(index: index, address: address, publicKey: pubkey, isChange: false)
                    allReceiving.append(walletAddr)

                    if !success {
                        consecutiveErrors += 1
                        #if DEBUG
                        print("[WalletVM] Skipping #\(index) due to error (\(consecutiveErrors) consecutive)")
                        #endif
                        if consecutiveErrors >= maxConsecutiveErrors {
                            #if DEBUG
                            print("[WalletVM] Too many consecutive errors (\(consecutiveErrors)), stopping scan")
                            #endif
                            consecutiveEmpty = gapLimit // force exit
                        }
                        continue
                    }

                    consecutiveErrors = 0 // reset on success

                    if utxos.isEmpty && txs.isEmpty {
                        consecutiveEmpty += 1
                    } else {
                        consecutiveEmpty = 0
                        allUTXOs.append(contentsOf: utxos)
                        allTxs.append(contentsOf: txs)
                    }
                }

                if consecutiveEmpty >= gapLimit { break }
            }

            scanIndex += batchSize
            #if DEBUG
            print("[WalletVM] Scanned up to index #\(scanIndex - 1), gap=\(consecutiveEmpty), utxos=\(allUTXOs.count)")
            #endif
        }

        #if DEBUG
        print("[WalletVM] Gap limit reached at index #\(scanIndex). Found \(allReceiving.count) addresses, \(allUTXOs.count) UTXOs")
        #endif

        // Derive a few change addresses (less critical, typically fewer)
        let changeBatch = await Task.detached(priority: .userInitiated) {
            AddressDerivation.deriveAddresses(
                xpub: xpubCopy, change: 1, startIndex: 0, count: batchSize, isTestnet: isTest
            )
        }.value
        allChange = changeBatch.map { WalletAddress(index: $0.index, address: $0.address, publicKey: $0.publicKey.hex, isChange: true) }

        // Fetch UTXOs for change addresses (parallel batches, not sequential)
        #if DEBUG
        print("[WalletVM] Fetching change addresses (\(allChange.count))...")
        #endif
        let changeResult = await UTXOFetchService.fetchUTXOsAndTransactions(for: allChange.map { $0.address })
        allUTXOs.append(contentsOf: changeResult.utxos)
        allTxs.append(contentsOf: changeResult.transactions)

        addresses = allReceiving + allChange

        // Cache addresses for HomeVM to reuse (same address set = same balance)
        KeychainStore.shared.saveCodable(addresses, forKey: KeychainStore.KeychainKey.walletAddresses.rawValue)
        #if DEBUG
        print("[WalletVM] Cached \(addresses.count) addresses to keychain")
        #endif

        // Set receive address to first unused
        if let firstUnused = allReceiving.first(where: { !$0.isChange }) {
            currentReceiveAddress = firstUnused.address
            currentReceiveIndex = firstUnused.index
        }

        // Deduplicate transactions
        var seen = Set<String>()
        let dedupedTxs = allTxs.filter { seen.insert($0.txid).inserted }

        // CRITICAL: Only keep UTXOs on OUR derived addresses.
        // Prevents phantom UTXOs from previous Ledger sessions.
        let knownAddresses = Set(addresses.map { $0.address })
        let cleanUTXOs = allUTXOs.filter { knownAddresses.contains($0.address) }

        utxos = cleanUTXOs
        transactions = dedupedTxs.sorted { ($0.status.blockTime ?? Int.max) > ($1.status.blockTime ?? Int.max) }
        totalBalance = cleanUTXOs.reduce(0) { $0 + $1.value }

        // Track address lifecycle (fresh / funded / used)
        updateAddressStatuses()

        // Update current receive address to first unused
        await findNextReceiveAddress()

        isLoading = false
    }

    // MARK: - Lightweight refresh (pull-to-refresh: price + block height only)

    func refreshMetadata() async {
        do {
            currentBlockHeight = try await MempoolAPI.shared.getBlockHeight()
            btcPrice = try await MempoolAPI.shared.getBTCPrice()
        } catch {
            #if DEBUG
            print("[WalletVM] refreshMetadata error: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Refresh UTXOs only (no re-derivation)

    func refreshUTXOs() async {
        guard !addresses.isEmpty else { return }
        isLoading = true
        scanProgress = 0
        scanStatus = "Scanning addresses..."

        // Fetch UTXOs and transactions via shared service
        let addrStrings = addresses.map { $0.address }
        let result = await UTXOFetchService.fetchUTXOsAndTransactions(
            for: addrStrings,
            onProgress: { [weak self] completed, total, phase in
                guard let self else { return }
                if phase == "utxos" {
                    self.scanProgress = Double(completed) / Double(total)
                    self.scanStatus = "Scanning addresses… \(completed)/\(total)"
                } else {
                    self.scanStatus = "Loading transactions…"
                }
            }
        )
        // Balance + UTXOs first (instant display)
        let knownAddresses = Set(addrStrings)
        let cleanUTXOs = result.utxos.filter { knownAddresses.contains($0.address) }
        utxos = cleanUTXOs
        totalBalance = cleanUTXOs.reduce(0) { $0 + $1.value }
        scanProgress = 1
        scanStatus = nil

        // Cache UTXOs + balance for HomeVM (shared data, single scan)
        KeychainStore.shared.saveCodable(cleanUTXOs, forKey: KeychainStore.KeychainKey.cachedUTXOs.rawValue)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_utxo_scan_time")
        #if DEBUG
        print("[WalletVM] Balance: \(totalBalance) sats, \(cleanUTXOs.count) UTXOs, errors: \(result.fetchErrorCount)")
        #endif

        // Then merge transactions (heavier)
        let activeAddrSet = Set(result.activeAddresses)
        var mergedTxs = transactions.filter { tx in
            !tx.vout.contains { activeAddrSet.contains($0.scriptpubkeyAddress ?? "") }
            && !tx.vin.contains { activeAddrSet.contains($0.prevout?.scriptpubkeyAddress ?? "") }
        }
        mergedTxs.append(contentsOf: result.transactions)

        var seen = Set<String>()
        let dedupedTxs = mergedTxs.filter { seen.insert($0.txid).inserted }
        transactions = dedupedTxs.sorted { ($0.status.blockTime ?? Int.max) > ($1.status.blockTime ?? Int.max) }

        // Fetch fee estimates (non-blocking, clearnet)
        if let fees = try? await MempoolAPI.shared.getRecommendedFees() {
            feeEstimate = fees
        }
        if let price = try? await MempoolAPI.shared.getBTCPrice() {
            btcPrice = price
        }

        // Track address lifecycle
        updateAddressStatuses()

        // Track sync errors — warn user if all fetches failed
        if result.fetchErrorCount > 0 && result.fetchSuccessCount == 0 {
            error = "Network error — balance may be outdated"
        } else if result.fetchErrorCount == 0 {
            error = nil
        }

        hasLoadedOnce = true
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

    // MARK: - Change address rotation

    /// Find the next fresh (unused) change address. Never reuse a change address
    /// that has been spent from — the pubkey is already exposed on-chain.
    private func nextFreshChangeAddress() -> WalletAddress? {
        let changeAddresses = addresses.filter { $0.isChange }.sorted { $0.index < $1.index }

        // Find first change address with no on-chain activity
        for addr in changeAddresses {
            let hasUtxos = utxos.contains { $0.address == addr.address }
            let wasUsed = transactions.contains { tx in
                // Check if this address appeared as an input (spent from)
                tx.vin.contains { $0.prevout?.scriptpubkeyAddress == addr.address }
            }
            let receivedAnything = transactions.contains { tx in
                tx.vout.contains { $0.scriptpubkeyAddress == addr.address }
            }

            // Fresh = never seen on-chain at all
            if !hasUtxos && !wasUsed && !receivedAnything {
                return addr
            }
        }

        // All change addresses used — derive the next one
        let nextIndex = (changeAddresses.last?.index ?? 0) + 1
        guard let xpub = xpub else { return changeAddresses.first }

        let derived = AddressDerivation.deriveAddresses(
            xpub: xpub, change: 1, startIndex: nextIndex, count: 1, isTestnet: isTestnet
        )
        if let newAddr = derived.first {
            let walletAddr = WalletAddress(index: newAddr.index, address: newAddr.address, publicKey: newAddr.publicKey.hex, isChange: true)
            addresses.append(walletAddr)
            return walletAddr
        }

        return changeAddresses.first // fallback
    }

    // MARK: - Send preview

    func previewSend() {
        guard let amount = UInt64(sendAmount), amount > 0 else {
            sendPreview = nil
            return
        }

        if coinControlEnabled && !manuallySelectedOutpoints.isEmpty {
            // Manual coin control — use only selected UTXOs
            let selected = coinControlUTXOs
            let totalInput = selected.reduce(UInt64(0)) { $0 + $1.value }
            let inputCount = selected.count
            let fee = UInt64(ceil(Double(11 + 68 * inputCount + 31 * 2) * sendFeeRate))
            let change = totalInput > amount + fee ? totalInput - amount - fee : 0

            sendPreview = CoinSelection.SelectionResult(
                selectedUTXOs: selected,
                totalInput: totalInput,
                fee: fee,
                change: change,
                hasChange: change >= 546
            )
        } else {
            // Automatic coin selection
            let frozenSet = FrozenUTXOStore.shared.frozenOutpoints
            sendPreview = CoinSelection.select(
                from: utxos,
                target: amount,
                feeRate: sendFeeRate,
                strategy: selectedStrategy,
                frozenOutpoints: frozenSet
            )
        }
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

        // Change output — always use a FRESH change address (never reuse)
        if preview.hasChange {
            let changeAddr = nextFreshChangeAddress()
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

        // 3b. Fee rate validation — protect against accidental overpayment
        if let fees = feeEstimate {
            let maxReasonable = Double(max(fees.fastestFee * 3, 100))
            if sendFeeRate > maxReasonable {
                sendError = "Fee rate \(Int(sendFeeRate)) sat/vB is abnormally high (fastest: \(fees.fastestFee) sat/vB). Reduce to avoid overpaying."
                return
            }
        }
        if sendFeeRate > 500 {
            sendError = "Fee rate \(Int(sendFeeRate)) sat/vB exceeds safety limit (500 sat/vB). This would waste funds."
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
            #if DEBUG
            print("[WalletVM] Warning: \(unconfirmedCount) unconfirmed UTXOs in selection")
            #endif
        }

        // 4c. Dust output warning on change
        if preview.hasChange && preview.change > 0 && preview.change < 546 {
            sendError = "The change amount (\(preview.change) sats) is below the dust threshold (546 sats). It will be lost to fees."
            return
        }

        // 5. Build PSBT (Stonewall or standard)
        let psbt: Data?
        if stonewallEnabled {
            psbt = buildStonewallPSBT()
        } else {
            psbt = buildSendPSBT()
        }
        guard let builtPSBT = psbt else {
            if sendError == nil { sendError = "Error building PSBT" }
            return
        }

        builtPSBTBase64 = builtPSBT.base64EncodedString()
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

        do {
            let signatures: [Data]
            var inputAddressInfosForWitness: [LedgerSigningV2.InputAddressInfo] = []

            do {
                // Real Ledger v2 signing
                #if DEBUG
                print("[WalletVM] Signing with real Ledger v2...")
                #endif

                // Detect Ledger Bitcoin app version to choose protocol
                var useProtocolV1 = true // default to v1 for updated firmware
                do {
                    let (appName, appVersion) = try await LedgerManager.shared.getAppAndVersion()
                    #if DEBUG
                    print("[WalletVM] Ledger app: \(appName) v\(appVersion)")
                    #endif
                    // Parse version: "2.4.5" → major=2, minor=4
                    let parts = appVersion.split(separator: ".").compactMap { Int($0) }
                    if parts.count >= 2 {
                        let major = parts[0]
                        let minor = parts[1]
                        // Protocol v1 requires firmware >= 2.1.0
                        useProtocolV1 = major > 2 || (major == 2 && minor >= 1)
                        #if DEBUG
                        print("[WalletVM] Protocol version: v\(useProtocolV1 ? "1" : "0") (app \(major).\(minor))")
                        #endif
                    }
                } catch {
                    #if DEBUG
                    print("[WalletVM] Could not detect app version: \(error), defaulting to protocol v1")
                    #endif
                }

                // Master fingerprint already saved to keychain during xpub retrieval
                if let savedFP = KeychainStore.shared.load(forKey: KeychainStore.KeychainKey.ledgerMasterFingerprint.rawValue) {
                    #if DEBUG
                    print("[WalletVM] Using saved master fingerprint: \(savedFP.hex)")
                    #endif
                }

                // Determine coin_type from what the Ledger app actually uses
                // Bitcoin mainnet app: coin_type=0, Bitcoin Test app: coin_type=1
                let savedCoinType = KeychainStore.shared.loadString(forKey: KeychainStore.KeychainKey.ledgerCoinType.rawValue) ?? "0"
                let coinType = savedCoinType == "1" ? 1 : 0
                let keyOrigin = "84'/\(coinType)'/0'"
                #if DEBUG
                print("[WalletVM] Using key origin: \(keyOrigin) (coin_type=\(coinType))")
                #endif

                // Use the ORIGINAL xpub from Ledger for wallet policy
                let xpubStr = KeychainStore.shared.loadString(forKey: KeychainStore.KeychainKey.ledgerOriginalXpub.rawValue)
                    ?? KeychainStore.shared.loadXpub(isTestnet: isTestnet) ?? ""
                #if DEBUG
                print("[WalletVM] Using xpub for signing: \(xpubStr.prefix(20))...")
                #endif

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

                            // Fetch previous transaction for NON_WITNESS_UTXO (BIP174)
                            var prevTx: Data?
                            if let rawHex = try? await MempoolAPI.shared.getRawTransaction(txid: utxo.txid),
                               let raw = Data(hex: rawHex) {
                                prevTx = raw
                            }

                            inputAddressInfos.append(LedgerSigningV2.InputAddressInfo(
                                change: walletAddr.isChange ? 1 : 0,
                                index: walletAddr.index,
                                publicKey: pubkeyData,
                                value: utxo.value,
                                scriptPubKey: spk,
                                previousTx: prevTx
                            ))
                            #if DEBUG
                            print("[WalletVM] Input UTXO \(utxo.outpoint): \(utxo.value) sats, addr=\(walletAddr.address.prefix(20))... change=\(walletAddr.isChange ? 1 : 0) index=\(walletAddr.index)")
                            #endif
                        } else {
                            #if DEBUG
                            print("[WalletVM] WARNING: Could not find wallet address for UTXO \(utxo.outpoint) at \(utxo.address)")
                            #endif
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
                #if DEBUG
                print("[WalletVM] Got \(signatures.count) signatures from Ledger")
                #endif
            }

            // Build witness stacks with per-input pubkeys
            var perInputPubkeys: [Data] = []

            if !inputAddressInfosForWitness.isEmpty {
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

            // Refresh UTXOs after broadcast
            await refreshUTXOs()

            // Poll for confirmation in background
            watchForConfirmation(txid: txid)
        } catch {
            sendError = error.localizedDescription
        }

        isSigning = false
    }

    /// Poll a transaction until confirmed, then refresh UTXOs
    private func watchForConfirmation(txid: String) {
        Task {
            for _ in 0..<60 { // Max 30 minutes (60 × 30s)
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                do {
                    let tx = try await MempoolAPI.shared.getTransaction(txid: txid)
                    if tx.status.confirmed {
                        #if DEBUG
                        print("[WalletVM] Tx \(txid.prefix(12)) confirmed at block \(tx.status.blockHeight ?? 0)")
                        #endif
                        await refreshUTXOs()
                        return
                    }
                } catch {
                    // Network error — keep polling
                }
            }
        }
    }

    // MARK: - RBF Fee Bump

    /// Pre-fill the send form to replace a pending transaction with higher fee
    func bumpFee(transaction: Transaction) {
        guard !transaction.status.confirmed else { return }

        // Find the destination output (not our address)
        let myAddresses = Set(addresses.map(\.address))
        let destOutput = transaction.vout.first { output in
            guard let addr = output.scriptpubkeyAddress else { return false }
            return !myAddresses.contains(addr)
        }

        // If all outputs are ours (self-transfer), use the first output as destination
        let dest = destOutput ?? transaction.vout.first
        sendAddress = dest?.scriptpubkeyAddress ?? ""
        sendAmount = dest.map { String(Double($0.value) / 100_000_000) } ?? ""

        // Suggest 2x the original fee rate
        let originalVsize = max(transaction.weight / 4, 1)
        let originalFeeRate = Double(transaction.fee) / Double(originalVsize)
        sendFeeRate = max(originalFeeRate * 2, originalFeeRate + 1)

        sendStep = .form
        sendError = nil
        builtPSBTBase64 = nil
        signedTxHex = nil
        broadcastTxid = nil
    }

    // MARK: - Stonewall (Fake CoinJoin)

    @Published var stonewallEnabled = false

    /// Build a Stonewall transaction: 2 equal outputs (destination + decoy to self)
    /// Makes the transaction look like a CoinJoin to blockchain observers
    func buildStonewallPSBT() -> Data? {
        guard let preview = sendPreview,
              let destScript = PSBTBuilder.scriptPubKeyFromAddress(sendAddress, isTestnet: isTestnet),
              let paymentAmount = UInt64(sendAmount) else { return nil }

        // Need at least 2 UTXOs for Stonewall
        guard preview.selectedUTXOs.count >= 2 else {
            sendError = "Stonewall requires at least 2 UTXOs"
            return nil
        }

        // Need enough balance for payment + equal decoy
        let totalInput = preview.totalInput
        let fee = preview.fee
        guard totalInput >= paymentAmount * 2 + fee else {
            sendError = "Stonewall requires balance >= 2x payment amount"
            return nil
        }

        let masterFP = KeychainStore.shared.load(forKey: KeychainStore.KeychainKey.ledgerMasterFingerprint.rawValue) ?? Data([0x00, 0x00, 0x00, 0x00])
        let psbtCoinType = UInt32(KeychainStore.shared.loadString(forKey: KeychainStore.KeychainKey.ledgerCoinType.rawValue) ?? "0") ?? 0

        // Build inputs (same as normal send)
        var inputs: [PSBTBuilder.TxInput] = []
        for utxo in preview.selectedUTXOs {
            guard let txidData = Data(hex: utxo.txid) else { continue }
            let txidInternal = Data(txidData.reversed())
            let walletAddr = addresses.first(where: { $0.address == utxo.address })
            let pubkeyData = walletAddr.flatMap { Data(hex: $0.publicKey) }
            let change: UInt32 = walletAddr?.isChange == true ? 1 : 0
            let addrIndex: UInt32 = walletAddr?.index ?? 0

            var witnessUtxoOutput: PSBTBuilder.TxOutput? = nil
            if let pk = pubkeyData {
                let pubkeyHash = Crypto.hash160(pk)
                var spk = Data([0x00, 0x14])
                spk.append(pubkeyHash)
                witnessUtxoOutput = PSBTBuilder.TxOutput(value: utxo.value, scriptPubKey: spk)
            }

            var bip32: [(pubkey: Data, fingerprint: Data, path: [UInt32])]? = nil
            if let pk = pubkeyData {
                bip32 = [(pubkey: pk, fingerprint: masterFP,
                          path: [UInt32(84) | 0x80000000, psbtCoinType | 0x80000000, UInt32(0) | 0x80000000, change, addrIndex])]
            }

            inputs.append(PSBTBuilder.TxInput(
                txid: txidInternal, vout: UInt32(utxo.vout), sequence: 0xFFFFFFFD,
                witnessUtxo: witnessUtxoOutput, bip32Derivation: bip32
            ))
        }

        // Build outputs: 2 equal amounts (destination + decoy) + optional change
        var outputs: [PSBTBuilder.TxOutput] = []

        // 1. Payment to destination
        outputs.append(PSBTBuilder.TxOutput(value: paymentAmount, scriptPubKey: destScript))

        // 2. Decoy equal output to fresh change address (looks like second participant's output)
        guard let decoyAddr = nextFreshChangeAddress()?.address else { return nil }
        if let decoyScript = PSBTBuilder.scriptPubKeyFromAddress(decoyAddr, isTestnet: isTestnet) {
            outputs.append(PSBTBuilder.TxOutput(value: paymentAmount, scriptPubKey: decoyScript))
        }

        // 3. Real change (if any left after 2x payment + fee)
        let remaining = totalInput - (paymentAmount * 2) - fee
        if remaining >= 546 {
            if let changeAddr = nextFreshChangeAddress()?.address,
               let changeScript = PSBTBuilder.scriptPubKeyFromAddress(changeAddr, isTestnet: isTestnet) {
                outputs.append(PSBTBuilder.TxOutput(value: remaining, scriptPubKey: changeScript))
            }
        }

        // Shuffle outputs for privacy (BIP69 alternative — random order)
        outputs.shuffle()

        let locktime = UInt32(currentBlockHeight > 0 ? currentBlockHeight : 0)
        return PSBTBuilder.buildPSBT(inputs: inputs, outputs: outputs, locktime: locktime)
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
        coinControlEnabled = false
        manuallySelectedOutpoints.removeAll()
    }

    // MARK: - UTXO management

    func toggleFreeze(outpoint: String) {
        FrozenUTXOStore.shared.toggle(outpoint: outpoint)
        objectWillChange.send() // Trigger WalletView re-render
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
