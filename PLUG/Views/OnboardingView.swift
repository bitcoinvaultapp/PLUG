import SwiftUI

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @StateObject private var ledgerVM = LedgerVM()
    @State private var currentPage = 0

    var body: some View {
        TabView(selection: $currentPage) {
            // Page 1: Welcome
            welcomePage
                .tag(0)

            // Page 2: How it works
            howItWorksPage
                .tag(1)

            // Page 3: Connect Ledger
            connectPage
                .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
    }

    // MARK: - Welcome

    private var welcomePage: some View {
        VStack(spacing: 32) {
            Spacer()

            Image("LogoV6")
                .resizable()
                .scaledToFit()
                .frame(width: 200)

            VStack(spacing: 12) {
                Text("Programmable Locking UTXO Gateway")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text("Code money on Bitcoin.\nAll signing goes through your Ledger.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            Spacer()

            Button("Next") { withAnimation { currentPage = 1 } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            Spacer().frame(height: 40)
        }
        .padding()
    }

    // MARK: - How it works

    private var howItWorksPage: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 20) {
                featureRow(icon: "key.slash", title: "Zero private keys",
                           desc: "Only extended public keys (xpub) are stored")

                featureRow(icon: "lock.shield", title: "iOS Keychain",
                           desc: "Hardware encryption, accessible only when unlocked")

                featureRow(icon: "wave.3.right", title: "Ledger via BLE",
                           desc: "Transaction signing on the Ledger Nano X")

                featureRow(icon: "doc.text", title: "Smart Contracts",
                           desc: "Vault (CLTV), Inheritance (CSV), Pool (Multisig)")

                featureRow(icon: "chevron.left.forwardslash.chevron.right", title: "Script Editor",
                           desc: "Interactive Bitcoin Script interpreter")
            }

            Spacer()

            Button("Next") { withAnimation { currentPage = 2 } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            Spacer().frame(height: 40)
        }
        .padding()
    }

    private func featureRow(icon: String, title: String, desc: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Connect

    private var connectPage: some View {
        VStack(spacing: 24) {
            Spacer()

            switch ledgerVM.state {
            case .disconnected:
                Image(systemName: "wave.3.right")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
                Text("Connect your Ledger")
                    .font(.title2.weight(.bold))
                Text("Make sure Bluetooth is on and your Ledger is unlocked.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                Button("Scan for Ledger") {
                    ledgerVM.startScan()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            case .scanning:
                ProgressView()
                    .controlSize(.large)
                Text("Searching for Ledger...")
                    .foregroundStyle(.secondary)

                if !ledgerVM.discoveredDevices.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(Array(ledgerVM.discoveredDevices.enumerated()), id: \.offset) { i, name in
                            Button {
                                ledgerVM.connect(at: i)
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
                    .padding(.horizontal)
                }

            case .connecting:
                ProgressView()
                    .controlSize(.large)
                Text("Connecting...")
                    .foregroundStyle(.secondary)

            case .connected:
                if ledgerVM.xpubResult != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.green)
                    Text("Ledger connected")
                        .font(.title2.weight(.bold))
                    Text("xpub saved. You're ready.")
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.green)
                    Text("Ledger connected")
                        .font(.title2.weight(.bold))
                    Text("Open the Bitcoin app on your Ledger.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if ledgerVM.isLoading {
                        ProgressView()
                        Text("Check your Ledger screen...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Fetch xpub") {
                            Task { await ledgerVM.fetchAndSaveXpub() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }

            case .error(let msg):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.red)
                Text(msg)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    ledgerVM.startScan()
                }
                .buttonStyle(.borderedProminent)
            }

            if let error = ledgerVM.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()

            Button("Skip") {
                isComplete = true
            }
            .foregroundStyle(.secondary)

            Spacer().frame(height: 40)
        }
        .padding()
        .onChange(of: ledgerVM.xpubResult) { result in
            if result != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    isComplete = true
                }
            }
        }
    }
}
