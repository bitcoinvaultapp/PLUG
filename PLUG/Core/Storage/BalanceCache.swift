import Foundation

// MARK: - Balance Cache
// Offline fallback for last known wallet balance
// Persisted in UserDefaults as JSON

final class BalanceCache {

    static let shared = BalanceCache()

    private let key = "balance_cache"
    private let staleDuration: TimeInterval = 600 // 10 minutes

    struct CachedBalance: Codable {
        let balance: UInt64
        let utxoCount: Int
        let timestamp: Date
        let blockHeight: Int
    }

    // MARK: - Save / Load

    func save(balance: UInt64, utxoCount: Int, blockHeight: Int) {
        let cached = CachedBalance(
            balance: balance,
            utxoCount: utxoCount,
            timestamp: Date(),
            blockHeight: blockHeight
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(cached) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func load() -> CachedBalance? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CachedBalance.self, from: data)
    }

    // MARK: - Staleness

    var isStale: Bool {
        guard let cached = load() else { return true }
        return Date().timeIntervalSince(cached.timestamp) > staleDuration
    }

    // MARK: - Clear

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
