import SwiftUI

struct LedgerView: View {
    @StateObject private var vm = LedgerVM()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Status
                statusCard

                // Actions based on state
                switch vm.state {
                case .disconnected:
                    disconnectedView
                case .scanning:
                    scanningView
                case .connecting:
                    connectingView
                case .connected:
                    connectedView
                case .error(let msg):
                    errorView(msg)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Ledger")
        }
    }

    // MARK: - Status card

    private var statusCard: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)

            Text(statusText)
                .font(.subheadline)

            Spacer()

            if vm.isDemoMode {
                Text("DEMO")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.orange, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusColor: Color {
        switch vm.state {
        case .connected: return .green
        case .scanning, .connecting: return .yellow
        case .error: return .red
        default: return .gray
        }
    }

    private var statusText: String {
        switch vm.state {
        case .disconnected: return "Disconnected"
        case .scanning: return "Scanning..."
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    // MARK: - Disconnected

    private var disconnectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wave.3.right")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Button("Scan for Ledger") {
                vm.startScan()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Demo mode") {
                vm.activateDemoMode()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Scanning

    private var scanningView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)

            Text("Searching for Ledger...")
                .foregroundStyle(.secondary)

            if !vm.discoveredDevices.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(vm.discoveredDevices.enumerated()), id: \.offset) { i, name in
                        Button {
                            vm.connect(at: i)
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.shield.fill")
                                Text(name)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    // MARK: - Connecting

    private var connectingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting to Ledger...")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Connected

    private var connectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Ledger connected")
                .font(.headline)

            Text("Open the Bitcoin app on your Ledger, then tap the button below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if let xpub = vm.xpubResult {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("xpub saved")
                        .font(.subheadline.bold())
                        .foregroundStyle(.green)
                    Text(xpub.prefix(20) + "..." + xpub.suffix(8))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding()
                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            } else {
                Button {
                    Task { await vm.fetchAndSaveXpub() }
                } label: {
                    HStack {
                        if vm.isLoading {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(vm.isLoading ? "Check your Ledger..." : "Fetch xpub")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isLoading)
            }

            if let error = vm.error {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }

            Button("Disconnect") {
                if vm.isDemoMode {
                    vm.deactivateDemoMode()
                } else {
                    vm.disconnect()
                }
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.red)
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)

            Text(message)
                .foregroundStyle(.secondary)

            Button("Retry") {
                vm.startScan()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
