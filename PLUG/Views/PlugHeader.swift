import SwiftUI

/// Shared "PLUG." branded header — same style on every tab.
/// Uses Button + navigationDestination to avoid List disclosure chevrons.
struct PlugHeader: View {
    let pageName: String

    @State private var showLedger = false
    @State private var showSettings = false

    var body: some View {
        HStack {
            // Left: branding + page name + network badge
            HStack(spacing: 0) {
                Text("PLUG")
                    .font(.system(size: 20, weight: .black))
                Text(".")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Color.btcOrange)
                if !pageName.isEmpty {
                    Text(" \(pageName)")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(.secondary)
                }

                Text(NetworkConfig.shared.isTestnet ? "TESTNET" : "MAINNET")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(NetworkConfig.shared.isTestnet ? Color.btcOrange : Color.green, in: Capsule())
                    .foregroundStyle(.black)
                    .padding(.leading, 10)
            }
            .lineLimit(1)
            .padding(.leading, 8)

            Spacer()

            // Right: Connect + Settings
            HStack(spacing: 8) {
                Button {
                    showLedger = true
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(LedgerManager.shared.state == .connected ? Color.green : Color.gray)
                            .frame(width: 6, height: 6)
                        Text("Connect")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 8)
        .navigationDestination(isPresented: $showLedger) {
            LedgerView()
        }
        .navigationDestination(isPresented: $showSettings) {
            SettingsView()
        }
    }
}
