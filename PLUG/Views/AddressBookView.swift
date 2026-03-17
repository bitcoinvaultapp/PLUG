import SwiftUI

struct AddressBookView: View {
    @StateObject private var vm = AddressBookVM()
    @State private var showAdd = false

    var body: some View {
        List {
            if vm.entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Address book empty")
                        .font(.headline)
                    Text("Save your Bitcoin addresses")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                ForEach(vm.entries) { entry in
                    Button {
                        UIPasteboard.general.string = entry.address
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(entry.address.prefix(24) + "...")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .onDelete { indexSet in
                    for i in indexSet {
                        vm.delete(id: vm.entries[i].id)
                    }
                }
            }
        }
        .navigationTitle("Address Book")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAdd) { addSheet }
        .onAppear { vm.refresh() }
    }

    // MARK: - Add Sheet

    private var addSheet: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Contact name", text: $vm.newName)
                }

                Section("Bitcoin Address") {
                    TextField("bc1q... or tb1q...", text: $vm.newAddress)
                        .font(.system(.caption, design: .monospaced))
                        .textInputAutocapitalization(.never)
                }

                if let error = vm.error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Add") {
                        vm.add()
                        if vm.error == nil {
                            showAdd = false
                        }
                    }
                    .disabled(vm.newName.isEmpty || vm.newAddress.isEmpty)
                }
            }
            .navigationTitle("New Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAdd = false }
                }
            }
        }
    }
}

// MARK: - Address Book ViewModel

@MainActor
final class AddressBookVM: ObservableObject {

    @Published var entries: [AddressEntry] = []
    @Published var newName: String = ""
    @Published var newAddress: String = ""
    @Published var error: String?

    private let storageKey = "address_book_v1"

    func refresh() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([AddressEntry].self, from: data) {
            entries = saved
        }
    }

    func add() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = newAddress.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty, !address.isEmpty else {
            error = "Name and address required"
            return
        }

        error = nil
        let entry = AddressEntry(id: UUID().uuidString, name: name, address: address)
        entries.append(entry)
        persist()

        newName = ""
        newAddress = ""
    }

    func delete(id: String) {
        entries.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

// MARK: - Address Entry Model

struct AddressEntry: Identifiable, Codable {
    let id: String
    let name: String
    let address: String
}
