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
        let batchSize = usingTor ? 10 : 5

        // Phase 1: Fetch UTXOs only
        // Shuffle to break sequential query pattern (anti-correlation)
        let shuffledAddrs = addresses.shuffled()
        var allUTXOs: [UTXO] = []
        var addressesWithActivity: [String] = []
        var errorCount = 0
        var successCount = 0

        #if DEBUG
        print("[UTXOFetchService] Phase 1: fetching UTXOs for \(shuffledAddrs.count) addresses (batch=\(batchSize), tor=\(usingTor))")
        #endif

        for (i, batchStart) in stride(from: 0, to: shuffledAddrs.count, by: batchSize).enumerated() {
            if !usingTor && i > 0 { try? await Task.sleep(nanoseconds: 200_000_000) }
            let batchEnd = min(batchStart + batchSize, shuffledAddrs.count)
            let batch = Array(shuffledAddrs[batchStart..<batchEnd])

            await withTaskGroup(of: (String, [UTXO], Bool).self) { group in
                for addr in batch {
                    group.addTask {
                        do {
                            let u = try await MempoolAPI.shared.getAddressUTXOs(address: addr)
                            return (addr, u, true)
                        } catch {
                            #if DEBUG
                            print("[UTXOFetchService] UTXO error for \(addr.prefix(12)): \(error.localizedDescription)")
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

        #if DEBUG
        print("[UTXOFetchService] Done: \(allUTXOs.count) UTXOs, \(allTxs.count) txs, \(addressesWithActivity.count) active addresses")
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
