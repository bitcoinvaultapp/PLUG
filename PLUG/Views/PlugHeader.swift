import SwiftUI

/// Shared "PLUG." branded header.
/// Home shows "PLUG. Home" + badge + connect + settings.
/// Other tabs show only "PLUG. PageName".
struct PlugHeader: View {
    let pageName: String

    @State private var showLedger = false
    @State private var showSettings = false

    private var isHome: Bool { pageName == "Home" }

    var body: some View {
        HStack {
            // Branding
            HStack(spacing: 0) {
                Text("PLUG")
                    .font(.system(size: 20, weight: .black))
                Text(".")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Color.btcOrange)
                Text(" \(pageName)")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(.secondary)

                if isHome {
                    Text(NetworkConfig.shared.isTestnet ? "TESTNET" : "MAINNET")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(NetworkConfig.shared.isTestnet ? Color.btcOrange : Color.green, in: Capsule())
                        .foregroundStyle(.black)
                        .padding(.leading, 10)
                }
            }
            .lineLimit(1)
            .padding(.leading, 8)

            Spacer()

            if isHome {
                HStack(spacing: 12) {
                    Button {
                        showLedger = true
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(LedgerManager.shared.state == .connected ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(LedgerManager.shared.state == .connected ? "Connected" : "Connect")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(.primary)
                    }

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize()
                .padding(.trailing, 4)
                .navigationDestination(isPresented: $showLedger) {
                    LedgerView()
                }
                .navigationDestination(isPresented: $showSettings) {
                    SettingsView()
                }
            }
        }
        .padding(.vertical, 8)
    }
}
