import SwiftUI

@main
struct PLUGApp: App {
    @StateObject private var walletVM = WalletVM()
    @StateObject private var networkConfig = NetworkConfig.shared
    @AppStorage("onboarding_complete") private var onboardingComplete = false

    init() {
        // Force testnet on first launch for safety
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "has_launched_before")
        if !hasLaunchedBefore {
            NetworkConfig.shared.isTestnet = true
            UserDefaults.standard.set(true, forKey: "has_launched_before")
        }

        // Clear stale keychain data when Ledger integration is updated
        // iOS keychain persists across app deletion, causing address mismatches
        let keychainVersion = UserDefaults.standard.integer(forKey: "keychain_version")
        if keychainVersion < 2 {
            KeychainStore.shared.deleteXpub(isTestnet: true)
            KeychainStore.shared.deleteXpub(isTestnet: false)
            KeychainStore.shared.delete(forKey: KeychainStore.KeychainKey.ledgerMasterFingerprint.rawValue)
            KeychainStore.shared.delete(forKey: KeychainStore.KeychainKey.ledgerOriginalXpub.rawValue)
            KeychainStore.shared.delete(forKey: KeychainStore.KeychainKey.ledgerCoinType.rawValue)
            UserDefaults.standard.set(2, forKey: "keychain_version")
            print("[PLUG] Cleared stale keychain data (v2 migration)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if onboardingComplete {
                MainTabView()
                    .environmentObject(walletVM)
                    .environmentObject(networkConfig)
                    .preferredColorScheme(.dark)
            } else {
                OnboardingView(isComplete: $onboardingComplete)
                    .environmentObject(walletVM)
                    .environmentObject(networkConfig)
                    .preferredColorScheme(.dark)
            }
        }
    }
}

struct MainTabView: View {
    @State private var selectedTab = 0

    var body: some View {
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
    }
}

// MARK: - Contracts Hub (replaces separate Vault/Inheritance tabs)

struct ContractsHubView: View {
    var body: some View {
        List {
            PlugHeader(pageName: "Contracts")
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            Section {
                Text("Bitcoin Script-based contracts using P2WSH")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink(destination: VaultView()) {
                    contractHubRow(
                        title: "Time-Lock Vaults",
                        desc: "Lock sats until a future date",
                        badge: "CLTV",
                        badgeColor: .orange
                    )
                }

                NavigationLink(destination: InheritanceView()) {
                    contractHubRow(
                        title: "Inheritance",
                        desc: "Automatic heir access after inactivity",
                        badge: "CSV",
                        badgeColor: .purple
                    )
                }

                NavigationLink(destination: HTLCView()) {
                    contractHubRow(
                        title: "Hash Time-Lock",
                        desc: "Conditional payments with hash preimage",
                        badge: "HTLC",
                        badgeColor: .teal
                    )
                }

                NavigationLink(destination: ChannelView()) {
                    contractHubRow(
                        title: "Payment Channels",
                        desc: "Off-chain micropayments",
                        badge: "CHANNEL",
                        badgeColor: .green
                    )
                }

                NavigationLink(destination: PoolView()) {
                    contractHubRow(
                        title: "Multisig Pool",
                        desc: "M-of-N shared custody",
                        badge: "MULTI",
                        badgeColor: .blue
                    )
                }
            }

            Section {
                NavigationLink(destination: OpReturnView()) {
                    contractHubRow(
                        title: "OP_RETURN",
                        desc: "Embed data on the blockchain",
                        badge: "DATA",
                        badgeColor: .indigo
                    )
                }
            }
        }
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
    }

    private func contractHubRow(title: String, desc: String, badge: String, badgeColor: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(badge)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(badgeColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(badgeColor)
        }
        .padding(.vertical, 4)
    }
}
