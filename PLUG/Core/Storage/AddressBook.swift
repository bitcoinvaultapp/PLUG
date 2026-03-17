import Foundation

// MARK: - Address Book
// Saved recipient addresses persisted in UserDefaults as JSON

final class AddressBook: ObservableObject {

    static let shared = AddressBook()

    @Published var entries: [AddressBookEntry] = []

    private let key = "address_book"

    struct AddressBookEntry: Identifiable, Codable {
        let id: String
        var name: String
        var address: String
        var createdAt: Date
    }

    init() {
        load()
    }

    // MARK: - CRUD

    func add(name: String, address: String) {
        let entry = AddressBookEntry(
            id: UUID().uuidString,
            name: name,
            address: address,
            createdAt: Date()
        )
        entries.append(entry)
        persist()
    }

    func update(_ entry: AddressBookEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
            persist()
        }
    }

    func delete(id: String) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clearAll() {
        entries.removeAll()
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Search

    func find(address: String) -> AddressBookEntry? {
        entries.first { $0.address == address }
    }

    func search(query: String) -> [AddressBookEntry] {
        guard !query.isEmpty else { return entries }
        let lower = query.lowercased()
        return entries.filter {
            $0.name.lowercased().contains(lower) ||
            $0.address.lowercased().contains(lower)
        }
    }

    // MARK: - Persistence

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([AddressBookEntry].self, from: data) {
            entries = loaded
        }
    }
}
