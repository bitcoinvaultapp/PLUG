import SwiftUI

@main
struct PLUGApp: App {
    @StateObject private var walletVM = WalletVM()
    @AppStorage("onboarding_complete") private var onboardingComplete = false
    @AppStorage("app_appearance") private var appearanceRaw: String = AppAppearance.dark.rawValue

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .dark
    }

    init() {
        // Keychain migration — iOS keychain persists across app deletion.
        // Only wipe wallet/Ledger data. NEVER wipe contracts — they contain
        // witness scripts and HMACs needed to spend locked funds.
        let keychainVersion = UserDefaults.standard.integer(forKey: "keychain_version")
        if keychainVersion < 4 {
            // Wipe wallet data (xpubs, fingerprint, coin_type, cached addresses)
            KeychainStore.shared.deleteXpub(isTestnet: true)
            KeychainStore.shared.deleteXpub(isTestnet: false)
            KeychainStore.shared.delete(forKey: KeychainStore.KeychainKey.ledgerMasterFingerprint.rawValue)
            KeychainStore.shared.delete(forKey: KeychainStore.KeychainKey.ledgerOriginalXpub.rawValue)
            KeychainStore.shared.delete(forKey: KeychainStore.KeychainKey.ledgerCoinType.rawValue)
            KeychainStore.shared.delete(forKey: KeychainStore.KeychainKey.walletAddresses.rawValue)
            // Contracts are PRESERVED — they hold witness scripts and policy HMACs
            UserDefaults.standard.set(4, forKey: "keychain_version")
            #if DEBUG
            print("[PLUG] Cleared wallet keychain data (v4 migration — preserves contracts)")
            #endif
        }
    }

    var body: some Scene {
        WindowGroup {
            if onboardingComplete {
                TorBootstrapWrapper {
                    MainTabView()
                        .environmentObject(walletVM)
                }
                .preferredColorScheme(appearance.colorScheme)
            } else {
                OnboardingView(isComplete: $onboardingComplete)
                    .environmentObject(walletVM)
                    .preferredColorScheme(appearance.colorScheme)
            }
        }
        .onChange(of: onboardingComplete) { completed in
            if completed {
                // Onboarding just finished — xpub is now in Keychain, trigger scan
                walletVM.hasLoadedOnce = false
                Task { await walletVM.loadWallet() }
            }
        }
    }
}

// MARK: - Tor Bootstrap Wrapper

struct TorBootstrapWrapper<Content: View>: View {
    @ObservedObject private var tor = TorManager.shared
    @State private var skipTor = false
    @State private var hasEnteredApp = false
    @State private var elapsedSeconds = 0
    @State private var timer: Timer?
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    private var statusText: String {
        switch tor.state {
        case .connecting: return "Downloading consensus..."
        case .warmingUp: return "Building hidden service circuit..."
        case .error(let msg): return msg
        default: return "Protecting your privacy..."
        }
    }

    private var timerText: String {
        let s = elapsedSeconds
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }

    var body: some View {
        if hasEnteredApp {
            content()
        } else if case .connected = tor.state {
            content()
                .onAppear {
                    hasEnteredApp = true
                    timer?.invalidate()
                }
        } else if skipTor {
            content()
                .onAppear {
                    hasEnteredApp = true
                    timer?.invalidate()
                }
        } else {
            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 44))
                    .foregroundStyle(.purple)

                Text("Connecting to Tor")
                    .font(.system(size: 18, weight: .semibold))

                Text(statusText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .animation(.easeInOut, value: tor.state)

                // Timer + progress
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.regular)

                    Text(timerText)
                        .font(.system(size: 24, weight: .light, design: .monospaced))
                        .foregroundStyle(.purple.opacity(0.7))
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.3), value: elapsedSeconds)

                    if elapsedSeconds > 15 {
                        Text("First connect takes ~60s")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 8)

                if case .error = tor.state {
                    Button {
                        elapsedSeconds = 0
                        tor.start()
                    } label: {
                        Text("Retry")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.purple)
                    }
                    .padding(.top, 4)
                }

                Spacer()

                Button {
                    MempoolAPI.torSkipped = true
                    skipTor = true
                } label: {
                    Text("Skip — use clearnet")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 40)
            }
            .onAppear {
                tor.start()
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    elapsedSeconds += 1
                }
            }
            .onDisappear {
                timer?.invalidate()
            }
        }
    }
}

struct MainTabView: View {
    @State private var selectedTab = 0
    @ObservedObject private var ledger = LedgerManager.shared
    @EnvironmentObject var walletVM: WalletVM
    @State private var showDisconnectBanner = false
    @State private var wasConnected = false
    @State private var lastDeviceName = ""

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $selectedTab) {
                HomeView()
                    .tag(0)
                    .tabItem {
                        Image(systemName: "house.fill")
                        Text("Home")
                    }

                WalletView()
                    .tag(1)
                    .tabItem {
                        Image(systemName: "wallet.bifold.fill")
                        Text("Wallet")
                    }

                NavigationStack {
                    ContractsHubView()
                }
                    .tag(2)
                    .tabItem {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("Contracts")
                    }

                LearnView()
                    .tag(3)
                    .tabItem {
                        Image(systemName: "book.fill")
                        Text("Learn")
                    }

                ScriptEditorView()
                    .tag(4)
                    .tabItem {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                        Text("Script")
                    }
            }
            .tint(Color.btcOrange)

            // Disconnect banner — slides down when Ledger drops unexpectedly
            if showDisconnectBanner {
                disconnectBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .onChange(of: ledger.state) { newState in
            if case .connected = newState {
                wasConnected = true
                lastDeviceName = ledger.deviceModel ?? ledger.connectedDevice?.name ?? "Ledger"
                withAnimation { showDisconnectBanner = false }
            } else if wasConnected, case .disconnected = newState {
                withAnimation(.easeOut(duration: 0.3)) { showDisconnectBanner = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    withAnimation { showDisconnectBanner = false }
                    wasConnected = false
                }
            }
        }
        .onAppear {
            Task { await walletVM.loadWallet() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ledgerManualDisconnect)) { _ in
            walletVM.clearWalletData()
        }
    }

    private var disconnectBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            Text("\(lastDeviceName) disconnected")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)

            Spacer()

            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .onTapGesture {
                    withAnimation { showDisconnectBanner = false }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.top, 50)
    }
}

// MARK: - Contracts Hub (replaces separate Vault/Inheritance tabs)

struct ContractsHubView: View {
    @ObservedObject private var contractStore = ContractStore.shared

    private var contracts: [Contract] {
        contractStore.contractsForNetwork(isTestnet: NetworkConfig.shared.isTestnet)
    }

    private func count(for type: ContractType) -> Int {
        contracts.filter { $0.type == type }.count
    }

    private var totalContracts: Int { contracts.count }

    var body: some View {
        List {
            PlugHeader(pageName: "Contracts")
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            VStack(alignment: .leading, spacing: 4) {
                Text("Bitcoin Script-based contracts using P2WSH")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                if !contracts.isEmpty {
                    Text("\(contracts.count) active")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            NavigationLink(destination: VaultView()) {
                contractHubRow(
                    icon: "lock.shield.fill", color: .orange,
                    title: "Time-Lock Vault", desc: "Lock sats until a future block",
                    opcode: "OP_CHECKLOCKTIMEVERIFY", count: count(for: .vault)
                )
            }
            .listRowBackground(Color.clear)

            NavigationLink(destination: InheritanceView()) {
                contractHubRow(
                    icon: "person.line.dotted.person.fill", color: .purple,
                    title: "Inheritance", desc: "Heir access after relative timelock",
                    opcode: "OP_CHECKSEQUENCEVERIFY", count: count(for: .inheritance)
                )
            }
            .listRowBackground(Color.clear)

            NavigationLink(destination: HTLCView()) {
                contractHubRow(
                    icon: "key.viewfinder", color: .teal,
                    title: "Hash Time-Lock", desc: "Conditional payment with preimage",
                    opcode: "OP_SHA256 + CLTV", count: count(for: .htlc)
                )
            }
            .listRowBackground(Color.clear)

            NavigationLink(destination: PoolView()) {
                contractHubRow(
                    icon: "person.3.sequence.fill", color: .blue,
                    title: "Multisig Pool", desc: "M-of-N shared custody",
                    opcode: "OP_CHECKMULTISIG", count: count(for: .pool)
                )
            }
            .listRowBackground(Color.clear)

            // Backup status
            backupStatusRow
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
    }

    private var backupStatusRow: some View {
        let lastBackup = UserDefaults.standard.object(forKey: "last_backup_date") as? Date
        let needsBackup = !contracts.isEmpty && (lastBackup == nil || Date().timeIntervalSince(lastBackup!) > 7 * 24 * 3600)

        return Group {
            if needsBackup {
                NavigationLink(destination: BackupView()) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                        Text("\(contracts.count) contract\(contracts.count > 1 ? "s" : "") need backup")
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.8))
                        Spacer()
                        Text("Backup")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                }
            } else if let date = lastBackup {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                    Text("All backed up")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(date, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
        .padding(.top, 8)
    }

    private func contractHubRow(icon: String, color: Color, title: String, desc: String, opcode: String, count: Int) -> some View {
        HStack(spacing: 12) {
            // Icon — colored, no background
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 24)

            // Title + description + opcode tag
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(opcode)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(color.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.08), in: Capsule())
            }

            Spacer()

            // Count badge
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(color, in: Circle())
            }

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.quaternary)
        }
        .padding(.vertical, 4)
    }
}
