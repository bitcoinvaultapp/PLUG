import SwiftUI

/// Shared "PLUG." branded header — same style as HomeView headerBar.
/// Used on all tabs except Home (which has its own copy with vm.isTestnet binding).
struct PlugHeader: View {
    let pageName: String

    var body: some View {
        HStack(spacing: 0) {
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
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, 8)

            // Network badge
            Text(NetworkConfig.shared.isTestnet ? "TESTNET" : "MAINNET")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(NetworkConfig.shared.isTestnet ? Color.btcOrange : Color.green, in: Capsule())
                .foregroundStyle(.black)
                .padding(.leading, 10)

            Spacer()

            // Connect / Settings
            HStack(spacing: 8) {
                NavigationLink(destination: LedgerView()) {
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

                NavigationLink(destination: SettingsView()) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(.vertical, 8)
    }
}
