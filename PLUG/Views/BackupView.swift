import SwiftUI
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

struct BackupView: View {
    @StateObject private var vm = BackupVM()
    @State private var showShareAll = false
    @State private var showShareSingle = false
    @State private var singleExportData: Data?
    @State private var showFileImporter = false
    @State private var showSuccess = false
    @State private var copiedLabels = false

    private var contracts: [Contract] {
        ContractStore.shared.contractsForNetwork(isTestnet: NetworkConfig.shared.isTestnet)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Hero
                VStack(spacing: 6) {
                    Image(systemName: "shield.checkerboard")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.orange, .orange.opacity(0.5))
                    Text("Protect your contracts. Without a backup, locked funds are unrecoverable.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 8)

                // Success overlay
                if showSuccess {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Backup saved successfully")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.green)
                    }
                    .transition(.opacity)
                }

                // Password
                VStack(alignment: .leading, spacing: 6) {
                    Text("Encryption Password")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    SecureField("Password", text: $vm.exportPassword)
                        .font(.system(size: 14))
                        .padding(12)
                        .background(Color(.systemGray6).opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                }

                // Back Up All
                Button {
                    vm.exportBackup()
                    if vm.exportedData != nil {
                        showShareAll = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.doc.fill")
                        Text("Back Up All Contracts")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        vm.exportPassword.isEmpty ? Color(.systemGray3) : Color.orange,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(vm.exportPassword.isEmpty)

                // Last backup info
                if let lastBackup = UserDefaults.standard.object(forKey: "last_backup_date") as? Date {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                        Text("Last backup:")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(lastBackup, style: .relative)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                // Contract list
                if !contracts.isEmpty {
                    Divider().opacity(0.15)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("CONTRACTS")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.quaternary)

                        ForEach(contracts) { contract in
                            contractBackupRow(contract)
                        }
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text("No contracts to back up")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 20)
                }

                // Restore
                Divider().opacity(0.15)

                VStack(alignment: .leading, spacing: 10) {
                    Text("RESTORE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.quaternary)

                    // Step 1: Select file
                    Button {
                        showFileImporter = true
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill")
                            Text(vm.importData.isEmpty ? "Select Backup File" : "File loaded ✓")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(vm.importData.isEmpty ? .blue : .green)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                            (vm.importData.isEmpty ? Color.blue : Color.green).opacity(0.3), lineWidth: 1
                        ))
                    }
                    .buttonStyle(.plain)

                    // Step 2: Password + Restore (after file selected)
                    if !vm.importData.isEmpty {
                        SecureField("Decryption password", text: $vm.importPassword)
                            .font(.system(size: 14))
                            .padding(12)
                            .background(Color(.systemGray6).opacity(0.3), in: RoundedRectangle(cornerRadius: 10))

                        Button {
                            vm.importBackup()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.doc.fill")
                                Text("Restore")
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                vm.importPassword.isEmpty ? Color(.systemGray3) : Color.blue,
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.importPassword.isEmpty)
                    }

                    // Manual paste fallback
                    DisclosureGroup("Or paste backup data") {
                        TextEditor(text: $vm.importData)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(height: 50)
                            .padding(6)
                            .background(Color(.systemGray6).opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .tint(.secondary)
                }

                // Labels BIP329
                Divider().opacity(0.15)

                HStack(spacing: 12) {
                    Button {
                        let data = vm.exportBIP329()
                        UIPasteboard.general.string = String(data: data, encoding: .utf8) ?? ""
                        copiedLabels = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedLabels = false }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copiedLabels ? "checkmark" : "tag.fill")
                            Text(copiedLabels ? "Copied" : "Export Labels")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    }

                    Text("·").foregroundStyle(.quaternary)

                    Button {
                        if let text = UIPasteboard.general.string {
                            vm.importBIP329(data: Data(text.utf8))
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle")
                            Text("Import Labels")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                }

                // Messages
                if let message = vm.message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
                if let error = vm.error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareAll, onDismiss: {
            if vm.exportedData != nil {
                withAnimation { showSuccess = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { showSuccess = false }
                }
            }
        }) {
            if let data = vm.exportedData {
                let fileName = "plug_backup_\(dateStamp).plug"
                ShareSheet(items: [BackupFile(data: data, fileName: fileName)])
            }
        }
        .sheet(isPresented: $showShareSingle) {
            if let data = singleExportData {
                ShareSheet(items: [BackupFile(data: data, fileName: "plug_contract.plug")])
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.data, .plainText, .item]) { result in
            switch result {
            case .success(let url):
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                if let data = try? Data(contentsOf: url) {
                    vm.importData = data.base64EncodedString()
                    vm.importBackup()
                }
            case .failure(let error):
                vm.error = error.localizedDescription
            }
        }
    }

    private var dateStamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: - Contract Row

    private func contractBackupRow(_ contract: Contract) -> some View {
        let lastBackup = UserDefaults.standard.object(forKey: "last_backup_date") as? Date
        let isBackedUp = lastBackup != nil

        return HStack(spacing: 10) {
            Image(systemName: contractIcon(contract.type))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(contractColor(contract.type), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(contract.name)
                    .font(.system(size: 12, weight: .medium))
                Text(contractTag(contract.type))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(contractColor(contract.type).opacity(0.7))
            }

            Spacer()

            Image(systemName: isBackedUp ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(isBackedUp ? .green : .red)

            Button {
                exportSingle(contract)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(vm.exportPassword.isEmpty)
        }
        .padding(.vertical, 6)
    }

    private func exportSingle(_ contract: Contract) {
        guard !vm.exportPassword.isEmpty else { return }
        let payload = SingleContractBackup(contract: contract)
        guard let json = try? JSONEncoder().encode(payload) else { return }
        do {
            singleExportData = try vm.encryptData(json)
            showShareSingle = true
        } catch {}
    }

    // MARK: - Helpers

    private func contractIcon(_ type: ContractType) -> String {
        switch type {
        case .vault: return "lock.fill"
        case .inheritance: return "shield.fill"
        case .pool: return "person.2.fill"
        case .htlc: return "arrow.left.arrow.right"
        case .channel: return "bolt.fill"
        }
    }

    private func contractColor(_ type: ContractType) -> Color {
        switch type {
        case .vault: return .orange
        case .inheritance: return .purple
        case .pool: return .blue
        case .htlc: return .teal
        case .channel: return .green
        }
    }

    private func contractTag(_ type: ContractType) -> String {
        switch type {
        case .vault: return "CLTV"
        case .inheritance: return "CSV"
        case .pool: return "MULTI"
        case .htlc: return "HTLC"
        case .channel: return "CHANNEL"
        }
    }
}

// MARK: - Backup File (for Share Sheet with filename)

class BackupFile: NSObject, UIActivityItemSource {
    let data: Data
    let fileName: String

    init(data: Data, fileName: String) {
        self.data = data
        self.fileName = fileName
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return data
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? data.write(to: tempURL, options: .completeFileProtection)
        return tempURL
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        return "PLUG Backup"
    }
}

// MARK: - Single Contract Backup

private struct SingleContractBackup: Codable {
    let contract: Contract
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
