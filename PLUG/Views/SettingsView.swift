import SwiftUI

struct SettingsView: View {
    @StateObject private var vm = SettingsVM()
    @State private var biometricEnabled = UserDefaults.standard.bool(forKey: "biometric_lock_enabled")

    var body: some View {
        NavigationStack {
            Form {
                // Network
                Section("Network") {
                    Toggle("Testnet", isOn: Binding(
                        get: { vm.isTestnet },
                        set: { _ in vm.toggleNetwork() }
                    ))

                    HStack {
                        Text("Active network")
                        Spacer()
                        Text(vm.isTestnet ? "Testnet" : "Mainnet")
                            .foregroundStyle(.secondary)
                    }

                    if !vm.isTestnet {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text("WARNING: Mainnet broadcast is disabled during testing")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Wallet
                Section("Wallet") {
                    if vm.hasXpub {
                        LabeledContent("xpub", value: vm.xpubDisplay)
                            .font(.system(.caption, design: .monospaced))
                    } else {
                        Text("No xpub configured")
                            .foregroundStyle(.secondary)
                    }

                    if vm.isDemoMode {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Demo mode active")
                        }
                    }
                }

                // Export
                Section("Export") {
                    if let descriptor = vm.exportDescriptor() {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Output Descriptor")
                                .font(.caption.weight(.medium))
                            Text(descriptor)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Button("Copy") {
                                UIPasteboard.general.string = descriptor
                            }
                            .font(.caption)
                        }
                    }
                }

                // Security
                Section("Security") {
                    Toggle("Biometric lock", isOn: $biometricEnabled)
                        .onChange(of: biometricEnabled) { _ in
                            UserDefaults.standard.set(biometricEnabled, forKey: "biometric_lock_enabled")
                        }
                }

                // Backup & Restore
                Section("Backup") {
                    NavigationLink("Backup & Restore") {
                        BackupView()
                    }
                }

                // Address Book
                Section("Contacts") {
                    NavigationLink("Address book") {
                        AddressBookView()
                    }
                }

                // Ledger
                Section("Ledger") {
                    NavigationLink("Manage connection") {
                        LedgerView()
                    }
                }

                // Danger zone
                Section("Danger zone") {
                    Button("Erase all data", role: .destructive) {
                        vm.showClearConfirmation = true
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Erase all data?", isPresented: $vm.showClearConfirmation) {
                Button("Erase", role: .destructive) {
                    vm.clearAllData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete all keys, contracts, and labels. This action cannot be undone.")
            }
            .onAppear { vm.refresh() }
        }
    }
}
