import Foundation

// MARK: - Address Book
// Saved recipient addresses persisted in Keychain via KeychainStore

final class AddressBook: ObservableObject {

    static let shared = AddressBook()

    @Published var entries: [AddressBookEntry] = []

    private let keychainKey = KeychainStore.KeychainKey.addressBook.rawValue

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
        KeychainStore.shared.delete(forKey: keychainKey)
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
        KeychainStore.shared.saveCodable(entries, forKey: keychainKey)
    }

    private func load() {
        if let loaded = KeychainStore.shared.loadCodable(forKey: keychainKey, type: [AddressBookEntry].self) {
            entries = loaded
        }
    }
}
