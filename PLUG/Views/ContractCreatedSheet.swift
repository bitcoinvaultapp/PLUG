import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit

/// Shown after any contract is successfully created.
/// Guides the user on next steps: copy address, save witness script, understand the lock.
struct ContractCreatedSheet: View {
    let contract: Contract
    let currentBlockHeight: Int
    var preimage: String? = nil    // HTLC only
    let onDismiss: () -> Void

    @State private var copiedItem = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Success header
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.green)
                        Text("Contract created!")
                            .font(.title2.bold())
                        Text(contract.name)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)

                    // QR Code + Address
                    VStack(spacing: 12) {
                        if let qr = generateQRCode(from: contract.address) {
                            Image(uiImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 180, height: 180)
                                .background(Color.white)
                                .cornerRadius(8)
                        }

                        Text(contract.address)
                            .font(.system(.caption, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        copyButton(label: "Copy address", value: contract.address, tag: "address")
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)

                    // Witness Script
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Witness Script", systemImage: "scroll")
                            .font(.subheadline.bold())

                        Text(contract.script.isEmpty ? contract.witnessScript : contract.script)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)

                        copyButton(label: "Copy script", value: contract.script.isEmpty ? contract.witnessScript : contract.script, tag: "script")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)

                    // HTLC Preimage (if applicable)
                    if let preimage = preimage {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Preimage (SECRET)", systemImage: "key.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(.orange)

                            Text(preimage)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)

                            copyButton(label: "Copy preimage", value: preimage, tag: "preimage")

                            Text("Keep this secret safe! The receiver needs it to claim the funds.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(12)
                    }

                    // Lock info
                    lockInfoSection

                    // Next steps
                    nextStepsSection

                    // Export contract
                    if let exportData = exportContractJSON(contract) {
                        ShareLink(item: exportData, preview: SharePreview("Contract \(contract.name)", image: Image(systemName: "doc.text"))) {
                            Label("Export contract", systemImage: "square.and.arrow.up")
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color(.systemGray6))
                                .cornerRadius(12)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Contract created")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { onDismiss() }
                        .bold()
                }
            }
        }
    }

    // MARK: - Lock Info

    @ViewBuilder
    private var lockInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Information", systemImage: "info.circle")
                .font(.subheadline.bold())

            switch contract.type {
            case .vault:
                if let lockHeight = contract.lockBlockHeight {
                    let blocks = max(0, lockHeight - currentBlockHeight)
                    Text("Locked until block \(lockHeight)")
                    Text(BlockDurationPicker.blocksToDateString(blocks: blocks))
                        .foregroundStyle(.orange)
                    Text("\(BlockDurationPicker.blocksToHumanTime(blocks: blocks)) remaining")
                        .foregroundStyle(.secondary)
                }

            case .inheritance:
                if let csvBlocks = contract.csvBlocks {
                    Text("Inactivity delay: \(BlockDurationPicker.blocksToHumanTime(blocks: csvBlocks))")
                    Text("The heir can claim after \(csvBlocks) blocks of owner inactivity.")
                        .foregroundStyle(.secondary)
                }

            case .htlc:
                if let timeout = contract.timeoutBlocks {
                    let blocks = max(0, timeout - currentBlockHeight)
                    Text("Timeout at block \(timeout)")
                    Text(BlockDurationPicker.blocksToDateString(blocks: blocks))
                        .foregroundStyle(.orange)
                }
                if let hash = contract.hashLock {
                    Text("Hash Lock: \(hash.prefix(24))...")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

            case .pool:
                if let m = contract.multisigM, let keys = contract.multisigPubkeys {
                    Text("Multisig \(m)-of-\(keys.count)")
                    Text("Requires \(m) of \(keys.count) signatures to spend.")
                        .foregroundStyle(.secondary)
                }

            case .channel:
                if let timeout = contract.timeoutBlocks {
                    let blocks = max(0, timeout - currentBlockHeight)
                    Text("Timeout at block \(timeout)")
                    Text("Cooperative close or refund after \(BlockDurationPicker.blocksToHumanTime(blocks: blocks)).")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    // MARK: - Next Steps

    @ViewBuilder
    private var nextStepsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Next steps", systemImage: "arrow.right.circle")
                .font(.subheadline.bold())

            switch contract.type {
            case .vault:
                step("1", "Send sats to the address above to fund your vault")
                step("2", "Wait until the unlock block height is reached")
                step("3", "Spend with your Ledger once unlocked")

            case .inheritance:
                step("1", "Send sats to the contract address")
                step("2", "Use 'Keep Alive' regularly to prevent the heir from claiming")
                step("3", "Share the address and witness script with your heir")

            case .htlc:
                step("1", "Save the preimage (secret) in a safe place")
                step("2", "Share the hash lock with the receiver")
                step("3", "Send sats to the contract address")
                step("4", "The receiver claims with the preimage, or you recover after the timeout")

            case .pool:
                step("1", "Share the address with all participants")
                step("2", "Each participant sends their contribution")
                step("3", "To spend, coordinate \(contract.multisigM ?? 2) signatures via PSBT")

            case .channel:
                step("1", "Send sats to the address to open the channel")
                step("2", "Exchange off-chain payments with the receiver")
                step("3", "Close cooperatively (2-of-2) or wait for timeout for a refund")
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.caption.bold())
                .frame(width: 20, height: 20)
                .background(Color.orange.opacity(0.2))
                .foregroundStyle(.orange)
                .clipShape(Circle())
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func copyButton(label: String, value: String, tag: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            copiedItem = tag
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if copiedItem == tag { copiedItem = "" }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copiedItem == tag ? "checkmark" : "doc.on.doc")
                Text(copiedItem == tag ? "Copied!" : label)
            }
            .font(.caption.bold())
            .foregroundStyle(copiedItem == tag ? .green : .orange)
        }
    }

    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Export all contract data as a JSON string for external recovery/backup.
    /// Since Contract is Codable, this encodes all fields including type-specific ones.
    private func exportContractJSON(_ contract: Contract) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(contract),
              var json = String(data: data, encoding: .utf8) else { return nil }

        // If an HTLC preimage was provided to this sheet, inject it into the export
        if let preimage = preimage {
            // Insert preimage into the JSON if not already present
            if !json.contains("\"preimage\"") {
                // Add before the closing brace
                json = json.replacingOccurrences(of: "\n}", with: ",\n  \"exportedPreimage\" : \"\(preimage)\"\n}")
            }
        }

        return json
    }
}
