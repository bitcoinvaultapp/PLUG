import SwiftUI

/// Shared "PLUG." branded header with connection status.
/// Shows on all tabs. Tapping the connection pill opens LedgerView.
struct PlugHeader: View {
    let pageName: String

    @ObservedObject private var ledger = LedgerManager.shared
    @ObservedObject private var tor = TorManager.shared
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

            HStack(spacing: 8) {
                // Tor pill — always visible
                torPill

                // Ledger connection pill — visible on ALL tabs
                Button {
                    showLedger = true
                } label: {
                    connectionPill
                }

                if isHome {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .fixedSize()
            .padding(.trailing, 4)
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showLedger) {
            NavigationStack {
                LedgerView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showLedger = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
    }

    // MARK: - Connection Pill

    @ViewBuilder
    private var connectionPill: some View {
        let isConnected = ledger.state == .connected
        let isWorking = ledger.state == .scanning || ledger.state == .connecting

        HStack(spacing: 5) {
            Circle()
                .fill(pillColor)
                .frame(width: 7, height: 7)

            if isWorking {
                ProgressView()
                    .controlSize(.mini)
            }

            Text(pillLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(pillColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(pillColor.opacity(0.1), in: Capsule())
    }

    private var pillColor: Color {
        switch ledger.state {
        case .connected: return .green
        case .scanning, .connecting: return .orange
        case .error: return .red
        default: return .gray
        }
    }

    private var pillLabel: String {
        switch ledger.state {
        case .connected:
            return ledger.deviceModel ?? ledger.connectedDevice?.name ?? "Ledger"
        case .scanning:
            return "Scanning"
        case .connecting:
            return "Connecting"
        case .error: return "Error"
        case .disconnected: return "Offline"
        }
    }

    // MARK: - Tor Pill

    private var torPill: some View {
        let color: Color = {
            switch tor.state {
            case .connected: return .purple
            case .connecting, .warmingUp: return .orange
            case .error: return .red
            case .disconnected: return .gray
            }
        }()

        return HStack(spacing: 4) {
            if tor.state == .connecting || tor.state == .warmingUp {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text("Tor")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1), in: Capsule())
    }
}
