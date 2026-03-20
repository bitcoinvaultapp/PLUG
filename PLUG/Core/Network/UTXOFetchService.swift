import Foundation

/// Shared service for batched UTXO and transaction fetching.
/// Used by both HomeVM and WalletVM to eliminate duplicated fetch logic.
enum UTXOFetchService {

    struct FetchResult {
        let utxos: [UTXO]
        let transactions: [Transaction]
        let activeAddresses: [String]
        let fetchErrorCount: Int
        let fetchSuccessCount: Int
    }

    /// Fetches UTXOs and transactions for the given addresses in batches.
    ///
    /// - Phase 1: Fetch UTXOs for all addresses (shuffled for anti-correlation).
    /// - Phase 2: Fetch transactions only for addresses that have activity.
    ///
    /// Batch size is 10 when Tor is running, 5 otherwise.
    /// Clearnet batches have a 200ms inter-batch delay to avoid 429 rate limits.
    ///
    /// - Parameter addresses: Array of address strings to query.
    /// - Returns: A `FetchResult` containing UTXOs, transactions, and active address strings.
    static func fetchUTXOsAndTransactions(
        for addresses: [String]
    ) async -> FetchResult {
        guard !addresses.isEmpty else {
            return FetchResult(utxos: [], transactions: [], activeAddresses: [], fetchErrorCount: 0, fetchSuccessCount: 0)
        }

        let usingTor = plug_tor_is_running()
        let batchSize = usingTor ? 1 : 5  // Serial for Tor (Rust Mutex serializes anyway)

        // Phase 1: Fetch UTXOs only
        // Shuffle to break sequential query pattern (anti-correlation)
        let shuffledAddrs = addresses.shuffled()
        var allUTXOs: [UTXO] = []
        var addressesWithActivity: [String] = []
        var errorCount = 0
        var successCount = 0
        let startTime = CFAbsoluteTimeGetCurrent()

        #if DEBUG
        print("[UTXOFetch] ▶ Phase 1: \(shuffledAddrs.count) addresses, batch=\(batchSize), tor=\(usingTor), port=\(plug_tor_port())")
        #endif

        for (i, batchStart) in stride(from: 0, to: shuffledAddrs.count, by: batchSize).enumerated() {
            if !usingTor && i > 0 { try? await Task.sleep(nanoseconds: 200_000_000) }
            let batchEnd = min(batchStart + batchSize, shuffledAddrs.count)
            let batch = Array(shuffledAddrs[batchStart..<batchEnd])

            await withTaskGroup(of: (String, [UTXO], Bool).self) { group in
                for addr in batch {
                    group.addTask {
                        do {
                            let t0 = CFAbsoluteTimeGetCurrent()
                            let u = try await MempoolAPI.shared.getAddressUTXOs(address: addr)
                            let dt = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                            #if DEBUG
                            if !u.isEmpty { print("[UTXOFetch] ✅ \(addr.prefix(12))… \(u.count) UTXOs (\(dt)ms)") }
                            #endif
                            return (addr, u, true)
                        } catch {
                            #if DEBUG
                            print("[UTXOFetch] ❌ \(addr.prefix(12))… \(error.localizedDescription)")
                            #endif
                            return (addr, [], false)
                        }
                    }
                }
                for await (addr, utxos, success) in group {
                    if success { successCount += 1 } else { errorCount += 1 }
                    allUTXOs.append(contentsOf: utxos)
                    if !utxos.isEmpty { addressesWithActivity.append(addr) }
                }
            }
        }

        // Phase 2: Fetch transactions only for active addresses
        var allTxs: [Transaction] = []

        if !addressesWithActivity.isEmpty {
            #if DEBUG
            print("[UTXOFetchService] Phase 2: fetching txs for \(addressesWithActivity.count) active addresses")
            #endif

            for (i, batchStart) in stride(from: 0, to: addressesWithActivity.count, by: batchSize).enumerated() {
                if !usingTor && i > 0 { try? await Task.sleep(nanoseconds: 200_000_000) }
                let batchEnd = min(batchStart + batchSize, addressesWithActivity.count)
                let batch = Array(addressesWithActivity[batchStart..<batchEnd])

                await withTaskGroup(of: [Transaction].self) { group in
                    for addr in batch {
                        group.addTask {
                            (try? await MempoolAPI.shared.getAddressTransactions(address: addr)) ?? []
                        }
                    }
                    for await txs in group {
                        allTxs.append(contentsOf: txs)
                    }
                }
            }
        }

        let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        #if DEBUG
        print("[UTXOFetch] ⏱ Done in \(elapsed)ms: \(allUTXOs.count) UTXOs, \(allTxs.count) txs, \(addressesWithActivity.count) active, \(errorCount) errors / \(successCount) success")
        #endif

        return FetchResult(
            utxos: allUTXOs,
            transactions: allTxs,
            activeAddresses: addressesWithActivity,
            fetchErrorCount: errorCount,
            fetchSuccessCount: successCount
        )
    }
}
