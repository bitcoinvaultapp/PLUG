import Foundation

// MARK: - Broadcast Queue
// Retry queue for failed transaction broadcasts
// Persisted in UserDefaults as JSON

final class BroadcastQueue: ObservableObject {

    static let shared = BroadcastQueue()

    @Published var pendingBroadcasts: [PendingBroadcast] = []

    private let key = "broadcast_queue"

    struct PendingBroadcast: Identifiable, Codable {
        let id: String
        let txHex: String
        let createdAt: Date
        var lastAttempt: Date?
        var attempts: Int
        var lastError: String?
    }

    init() {
        load()
    }

    // MARK: - Queue management

    func enqueue(txHex: String) {
        let entry = PendingBroadcast(
            id: UUID().uuidString,
            txHex: txHex,
            createdAt: Date(),
            lastAttempt: nil,
            attempts: 0,
            lastError: nil
        )
        pendingBroadcasts.append(entry)
        persist()
    }

    func remove(id: String) {
        pendingBroadcasts.removeAll { $0.id == id }
        persist()
    }

    func clearAll() {
        pendingBroadcasts.removeAll()
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Retry

    func retryAll() async {
        var remaining: [PendingBroadcast] = []

        for var broadcast in pendingBroadcasts {
            broadcast.attempts += 1
            broadcast.lastAttempt = Date()

            do {
                _ = try await MempoolAPI.shared.broadcastTransaction(hex: broadcast.txHex)
                // Success - don't add to remaining
            } catch {
                broadcast.lastError = error.localizedDescription
                remaining.append(broadcast)
            }
        }

        await MainActor.run {
            pendingBroadcasts = remaining
            persist()
        }
    }

    // MARK: - Persistence

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(pendingBroadcasts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([PendingBroadcast].self, from: data) {
            pendingBroadcasts = loaded
        }
    }
}
