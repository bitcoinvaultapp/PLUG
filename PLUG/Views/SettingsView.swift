import SwiftUI

struct SettingsView: View {
    @StateObject private var vm = SettingsVM()
    @EnvironmentObject var walletVM: WalletVM
    @State private var biometricEnabled = UserDefaults.standard.bool(forKey: "biometric_lock_enabled")
    @State private var showRescanConfirm = false
    @State private var isRescanning = false
    @AppStorage("balance_unit") private var balanceUnit: String = BalanceUnit.btc.rawValue

    var body: some View {
        NavigationStack {
            Form {
                // Tor Privacy
                Section {
                    TorSettingsRow()
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Routes wallet address queries through the Tor network. Prevents your IP from being linked to your addresses.")
                }

                // Personal Node
                Section {
                    PersonalNodeSettingsRow()
                } header: {
                    Text("Personal Node")
                } footer: {
                    Text("Connect to your own Bitcoin Core + Electrs server via Tor. All address, UTXO, fee, and block queries stay on your infrastructure. Requires Tor to be connected.")
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

                    Button {
                        showRescanConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.orange)
                            Text("Rescan addresses")
                            Spacer()
                            if isRescanning {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(isRescanning || !vm.hasXpub)
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

                // Appearance
                Section("Appearance") {
                    Picker("Theme", selection: Binding(
                        get: { UserDefaults.standard.string(forKey: "app_appearance") ?? "dark" },
                        set: { UserDefaults.standard.set($0, forKey: "app_appearance") }
                    )) {
                        Text("System").tag(AppAppearance.system.rawValue)
                        Text("Light").tag(AppAppearance.light.rawValue)
                        Text("Dark").tag(AppAppearance.dark.rawValue)
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
            .alert("Rescan addresses?", isPresented: $showRescanConfirm) {
                Button("Rescan") {
                    isRescanning = true
                    Task {
                        await walletVM.rescanWallet()
                        isRescanning = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will re-derive all addresses from your xpub and fetch fresh balances. This may take a few minutes over Tor.")
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
                    Text("Arti")
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

// MARK: - Personal Node Settings Row

struct PersonalNodeSettingsRow: View {
    @ObservedObject private var torConfig = TorConfig.shared
    @ObservedObject private var torManager = TorManager.shared
    @State private var onionInput: String = ""
    @State private var checkStatus: NodeCheckStatus = .idle

    enum NodeCheckStatus: Equatable {
        case idle, checking, reachable(Int), unreachable
    }

    var body: some View {
        VStack(spacing: 12) {
            // Personal node is required — no toggle
                VStack(alignment: .leading, spacing: 8) {
                    Text(".onion address")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("abc...xyz.onion", text: $onionInput)
                        .font(.system(size: 13, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onAppear { onionInput = torConfig.personalNodeOnion }
                        .onChange(of: onionInput) { _ in
                            torConfig.personalNodeOnion = onionInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            checkStatus = .idle
                        }

                    HStack {
                        Button {
                            checkNode()
                        } label: {
                            HStack(spacing: 6) {
                                if case .checking = checkStatus {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.system(size: 12))
                                }
                                Text("Test connection")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(.orange)
                        }
                        .disabled(onionInput.isEmpty || !torManager.isRunning || checkStatus == .checking)

                        Spacer()

                        switch checkStatus {
                        case .reachable(let height):
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Block \(height)")
                                    .foregroundStyle(.green)
                            }
                            .font(.system(size: 11, weight: .medium))
                        case .unreachable:
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                Text("Unreachable")
                                    .foregroundStyle(.red)
                            }
                            .font(.system(size: 11, weight: .medium))
                        default:
                            EmptyView()
                        }
                    }
                }

            if !torManager.isRunning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Tor must be connected to reach your node")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func checkNode() {
        checkStatus = .checking
        let host = torConfig.personalNodeOnion
        Task.detached(priority: .userInitiated) {
            guard let hostC = host.cString(using: .utf8),
                  let pathC = "/api/blocks/tip/height".cString(using: .utf8) else {
                await MainActor.run { checkStatus = .unreachable }
                return
            }
            guard let resultPtr = plug_tor_fetch(hostC, 80, pathC) else {
                await MainActor.run { checkStatus = .unreachable }
                return
            }
            let result = String(cString: resultPtr)
            plug_tor_free_string(resultPtr)

            if let height = Int(result.trimmingCharacters(in: .whitespacesAndNewlines)) {
                await MainActor.run { checkStatus = .reachable(height) }
            } else {
                await MainActor.run { checkStatus = .unreachable }
            }
        }
    }
}
