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

            Image(systemName: "bitcoinsign.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.orange)

            VStack(spacing: 12) {
                Text("PLUG")
                    .font(.system(size: 42, weight: .bold, design: .rounded))

                Text("Bitcoin Wallet")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text("100% native. Zero private keys on device.\nAll signing goes through your Ledger.")
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

            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("Connect your Ledger")
                .font(.title2.weight(.bold))

            Text("Or use demo mode to explore")
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                Button("Scan Ledger") {
                    ledgerVM.startScan()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Skip") {
                    isComplete = true
                }
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .onChange(of: ledgerVM.state) { newState in
            if case .connected = newState {
                Task {
                    await ledgerVM.fetchAndSaveXpub()
                    isComplete = true
                }
            }
        }
    }
}
