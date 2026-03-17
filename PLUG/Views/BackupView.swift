import SwiftUI

struct BackupView: View {
    @StateObject private var vm = BackupVM()
    @State private var showShareSheet = false

    var body: some View {
        Form {
            // Export
            Section("Export") {
                SecureField("Password", text: $vm.exportPassword)

                Button("Export backup") {
                    vm.exportBackup()
                    if vm.exportedData != nil {
                        showShareSheet = true
                    }
                }
                .disabled(vm.exportPassword.isEmpty)

                if let data = vm.exportedData {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Backup ready (\(data.count) bytes)")
                            .font(.caption)
                            .foregroundStyle(.green)

                        Button("Copy as Base64") {
                            UIPasteboard.general.string = data.base64EncodedString()
                        }
                        .font(.caption)
                    }
                }
            }

            // Import
            Section("Import") {
                SecureField("Password", text: $vm.importPassword)

                VStack(alignment: .leading) {
                    Text("Base64 data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $vm.importData)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 80)
                }

                Button("Import backup") {
                    vm.importBackup()
                }
                .disabled(vm.importPassword.isEmpty || vm.importData.isEmpty)
            }

            // BIP329 Labels
            Section("Labels (BIP329)") {
                Button("Export labels") {
                    let data = vm.exportBIP329()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    UIPasteboard.general.string = text
                    vm.message = "Labels copied to clipboard"
                }

                Button("Import from clipboard") {
                    if let text = UIPasteboard.general.string {
                        vm.importBIP329(data: Data(text.utf8))
                    }
                }
            }

            // Messages
            if let message = vm.message {
                Section {
                    Text(message)
                        .foregroundStyle(.green)
                }
            }

            if let error = vm.error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Backup & Restore")
        .sheet(isPresented: $showShareSheet) {
            if let data = vm.exportedData {
                ShareSheet(items: [data])
            }
        }
    }
}

// MARK: - Share Sheet (UIKit wrapper for iOS 16)

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
