import SwiftUI

struct SettingsView: View {
    @StateObject private var vm = SettingsVM()
    @State private var biometricEnabled = UserDefaults.standard.bool(forKey: "biometric_lock_enabled")
    @AppStorage("balance_unit") private var balanceUnit: String = BalanceUnit.btc.rawValue

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

                // Tor Privacy
                Section {
                    TorSettingsRow()
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Routes wallet address queries through the Tor network. Prevents your IP from being linked to your addresses.")
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

                // Display
                Section("Display") {
                    Picker("Balance unit", selection: $balanceUnit) {
                        Text("BTC").tag(BalanceUnit.btc.rawValue)
                        Text("sats").tag(BalanceUnit.sats.rawValue)
                        Text("USD").tag(BalanceUnit.usd.rawValue)
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

// MARK: - Tor Settings Row

struct TorSettingsRow: View {
    @ObservedObject private var torManager = TorManager.shared

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 10) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 16))
                        .foregroundStyle(statusColor)
                    Text("Tor Network")
                        .font(.system(size: 15))
                }

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusColor)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.1), in: Capsule())
            }

            HStack {
                if case .connecting = torManager.state {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                    Text("Bootstrapping Tor...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if case .warmingUp = torManager.state {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                    Text("Establishing private route...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if torManager.isRunning {
                    Button {
                        torManager.stop()
                    } label: {
                        Text("Disconnect")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.red)
                    }
                } else {
                    Button {
                        torManager.start()
                    } label: {
                        Text("Connect to Tor")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.purple)
                    }
                }

                Spacer()

                if torManager.isRunning {
                    Text("SOCKS5 ::\(torManager.socksPort)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            if case .error(let msg) = torManager.state {
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
    }

    private var statusColor: Color {
        switch torManager.state {
        case .disconnected: return .gray
        case .connecting, .warmingUp: return .orange
        case .connected: return .green
        case .error: return .red
        }
    }

    private var statusLabel: String {
        switch torManager.state {
        case .disconnected: return "Off"
        case .connecting: return "Connecting"
        case .warmingUp: return "Warming up"
        case .connected: return "Connected"
        case .error: return "Error"
        }
    }
}
