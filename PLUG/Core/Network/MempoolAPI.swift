import Foundation

// MARK: - Bitcoin API Client
// All traffic via Tor. Personal node for wallet data. Mempool.space .onion for market data.

final class MempoolAPI {

    static let shared = MempoolAPI()

    // MARK: - Tor transport

    /// GET via Tor to personal node. Retries once with 2s backoff.
    private func nodeGET(_ endpoint: String) async throws -> String {
        guard TorConfig.shared.isNodeConfigured else { throw APIError.nodeNotConfigured }
        let (host, path) = TorConfig.shared.resolve(endpoint: endpoint)
        return try await torFetch(host: host, path: path)
    }

    /// GET via Tor to mempool.space .onion (price, difficulty).
    private func mempoolGET(_ endpoint: String) async throws -> String {
        let (host, path) = TorConfig.shared.resolveMempoolSpace(endpoint: endpoint)
        return try await torFetch(host: host, path: path)
    }

    /// Core Tor fetch with retry.
    private func torFetch(host: String, path: String) async throws -> String {
        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                #if DEBUG
                print("[Tor] Retry \(path)")
                #endif
            }
            let result: String? = await Task.detached(priority: .userInitiated) {
                guard let h = host.cString(using: .utf8),
                      let p = path.cString(using: .utf8),
                      let ptr = plug_tor_fetch(h, 80, p) else { return nil as String? }
                let s = String(cString: ptr)
                plug_tor_free_string(ptr)
                return s
            }.value
            if let s = result, !s.isEmpty { return s }
        }
        throw APIError.torFetchFailed
    }

    /// POST via Tor. 3 attempts with exponential backoff.
    private func torPOST(host: String, path: String, body: String) async throws -> String {
        var lastError = "onion service unreachable"
        for attempt in 0..<3 {
            if attempt > 0 {
                let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
            let result: String? = await Task.detached(priority: .userInitiated) {
                guard let h = host.cString(using: .utf8),
                      let p = path.cString(using: .utf8),
                      let b = body.cString(using: .utf8),
                      let ptr = plug_tor_post(h, 80, p, b) else { return nil as String? }
                let s = String(cString: ptr)
                plug_tor_free_string(ptr)
                return s
            }.value
            if let s = result?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s
            }
            lastError = result ?? "onion service unreachable"
        }
        throw APIError.broadcastFailed("Failed after 3 attempts: \(lastError)")
    }

    // MARK: - Decode helpers

    private func nodeJSON<T: Decodable>(_ endpoint: String, type: T.Type) async throws -> T {
        let raw = try await nodeGET(endpoint)
        guard let data = raw.data(using: .utf8) else { throw APIError.decodingError }
        return try JSONDecoder().decode(type, from: data)
    }

    private func mempoolJSON<T: Decodable>(_ endpoint: String, type: T.Type) async throws -> T {
        let raw = try await mempoolGET(endpoint)
        guard let data = raw.data(using: .utf8) else { throw APIError.decodingError }
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: - Price (mempool.space .onion)

    func getBTCPrice() async throws -> Double {
        struct R: Decodable { let USD: Int }
        return Double(try await mempoolJSON("/v1/prices", type: R.self).USD)
    }

    // MARK: - Fees (personal node)

    func getRecommendedFees() async throws -> FeeEstimate {
        let raw = try await nodeGET("/fee-estimates")
        guard let data = raw.data(using: .utf8) else { throw APIError.decodingError }
        let m = try JSONDecoder().decode([String: Double].self, from: data)
        return FeeEstimate(
            fastestFee: Int(m["1"] ?? m["2"] ?? 1),
            halfHourFee: Int(m["3"] ?? m["6"] ?? 1),
            hourFee: Int(m["6"] ?? m["12"] ?? 1),
            economyFee: Int(m["12"] ?? m["24"] ?? 1),
            minimumFee: Int(m["144"] ?? m["504"] ?? 1)
        )
    }

    // MARK: - Blockchain info (personal node)

    func getBlockHeight() async throws -> Int {
        let text = try await nodeGET("/blocks/tip/height")
        guard let h = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw APIError.decodingError
        }
        return h
    }

    func getBlockHash(height: Int) async throws -> String {
        try await nodeGET("/block-height/\(height)")
    }

    func getDifficultyAdjustment() async throws -> DifficultyAdjustment {
        try await mempoolJSON("/v1/difficulty-adjustment", type: DifficultyAdjustment.self)
    }

    // MARK: - Address (personal node)

    func getAddressUTXOs(address: String) async throws -> [UTXO] {
        struct R: Decodable {
            let txid: String; let vout: Int; let value: UInt64; let status: UTXO.UTXOStatus
        }
        return try await nodeJSON("/address/\(address)/utxo", type: [R].self).map {
            UTXO(txid: $0.txid, vout: $0.vout, value: $0.value, address: address,
                 scriptPubKey: "", status: $0.status)
        }
    }

    func getAddressTransactions(address: String) async throws -> [Transaction] {
        try await nodeJSON("/address/\(address)/txs", type: [Transaction].self)
    }

    func hasTransactions(address: String) async throws -> Bool {
        struct Stats: Decodable {
            let txCount: Int
            enum CodingKeys: String, CodingKey { case txCount = "tx_count" }
        }
        struct R: Decodable {
            let chainStats: Stats; let mempoolStats: Stats
            enum CodingKeys: String, CodingKey {
                case chainStats = "chain_stats"; case mempoolStats = "mempool_stats"
            }
        }
        let info = try await nodeJSON("/address/\(address)", type: R.self)
        return info.chainStats.txCount > 0 || info.mempoolStats.txCount > 0
    }

    // MARK: - Transaction (personal node)

    func getTransaction(txid: String) async throws -> Transaction {
        try await nodeJSON("/tx/\(txid)", type: Transaction.self)
    }

    func getRawTransaction(txid: String) async throws -> String {
        try await nodeGET("/tx/\(txid)/hex")
    }

    // MARK: - Broadcast (personal node)

    func broadcastTransaction(hex: String) async throws -> String {
        let (host, path) = TorConfig.shared.resolve(endpoint: "/tx")
        let txid = try await torPOST(host: host, path: path, body: hex)
        guard isValidTxid(txid) else {
            throw APIError.broadcastFailed("Invalid txid: \(txid)")
        }
        return txid
    }

    private func isValidTxid(_ txid: String) -> Bool {
        txid.count == 64 && txid.allSatisfy(\.isHexDigit)
    }

    // MARK: - Errors

    enum APIError: LocalizedError {
        case nodeNotConfigured
        case decodingError
        case broadcastFailed(String)
        case torFetchFailed

        var errorDescription: String? {
            switch self {
            case .nodeNotConfigured: return "Personal node not configured. Set your .onion address in Settings."
            case .decodingError: return "Decoding error"
            case .broadcastFailed(let msg): return "Broadcast failed: \(msg)"
            case .torFetchFailed: return "Tor fetch failed — node unreachable"
            }
        }
    }
}
