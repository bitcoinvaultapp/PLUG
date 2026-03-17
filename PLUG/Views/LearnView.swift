import SwiftUI

struct LearnView: View {
    var body: some View {
        NavigationStack {
            List {
                PlugHeader(pageName: "Learn")
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                Section {
                    Text("Mastering Bitcoin — 3rd Edition")
                        .font(.headline)
                    Text("Andreas M. Antonopoulos & David A. Harding")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Fundamentals") {
                    chapterLink("ch01_intro.adoc", number: 1, title: "Introduction", desc: "What is Bitcoin, the protocol stack", icon: "bitcoinsign.circle.fill", color: .orange)
                    chapterLink("ch02_overview.adoc", number: 2, title: "How Bitcoin Works", desc: "Transactions, blocks, and mining overview", icon: "gearshape.2.fill", color: .blue)
                    chapterLink("ch03_bitcoin-core.adoc", number: 3, title: "Bitcoin Core", desc: "The reference implementation", icon: "desktopcomputer", color: .gray)
                }

                Section("Keys & Wallets") {
                    chapterLink("ch04_keys.adoc", number: 4, title: "Keys and Addresses", desc: "Public/private key cryptography", icon: "key.fill", color: .yellow)
                    chapterLink("ch05_wallets.adoc", number: 5, title: "Wallet Recovery", desc: "Backup and recovery methods", icon: "wallet.bifold.fill", color: .purple)
                }

                Section("Transactions") {
                    chapterLink("ch06_transactions.adoc", number: 6, title: "Transactions", desc: "Structure, inputs, outputs, UTXO model", icon: "arrow.left.arrow.right", color: .green)
                    chapterLink("ch07_authorization-authentication.adoc", number: 7, title: "Authorization", desc: "Script mechanisms and spending rules", icon: "lock.shield.fill", color: .teal)
                    chapterLink("ch08_signatures.adoc", number: 8, title: "Digital Signatures", desc: "ECDSA and Schnorr algorithms", icon: "signature", color: .indigo)
                    chapterLink("ch09_fees.adoc", number: 9, title: "Transaction Fees", desc: "Fee estimation and mempool", icon: "gauge.with.dots.needle.33percent", color: .orange)
                }

                Section("Network & Consensus") {
                    chapterLink("ch10_network.adoc", number: 10, title: "The Bitcoin Network", desc: "Peer-to-peer architecture", icon: "network", color: .blue)
                    chapterLink("ch11_blockchain.adoc", number: 11, title: "The Blockchain", desc: "Blocks, links, and validation", icon: "square.stack.3d.up.fill", color: .cyan)
                    chapterLink("ch12_mining.adoc", number: 12, title: "Mining and Consensus", desc: "Proof-of-work and incentives", icon: "hammer.fill", color: .orange)
                }

                Section("Advanced") {
                    chapterLink("ch13_security.adoc", number: 13, title: "Bitcoin Security", desc: "Key custody and hardware wallets", icon: "shield.checkered", color: .red)
                    chapterLink("ch14_applications.adoc", number: 14, title: "Second-Layer Apps", desc: "Payment channels and Lightning", icon: "bolt.fill", color: .yellow)
                }

                Section("Appendices") {
                    chapterLink("appa_whitepaper.adoc", number: nil, title: "The Bitcoin Whitepaper", desc: "Satoshi Nakamoto's original paper", icon: "doc.text.fill", color: .orange)
                    chapterLink("appc_bips.adoc", number: nil, title: "Bitcoin Improvement Proposals", desc: "BIP framework overview", icon: "list.bullet.rectangle.fill", color: .green)
                }
            }
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func chapterLink(_ filename: String, number: Int?, title: String, desc: String, icon: String, color: Color) -> some View {
        NavigationLink {
            ChapterView(filename: filename, title: number.map { "Ch. \($0) — \(title)" } ?? title)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(color)
                    .frame(width: 32, height: 32)
                    .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let n = number {
                            Text("\(n)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(color.opacity(0.6), in: Circle())
                        }
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Chapter Reader

struct ChapterView: View {
    let filename: String
    let title: String
    @State private var content: String = ""
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView()
                    .padding(.top, 40)
            } else if content.isEmpty {
                Text("Could not load chapter.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
            } else {
                Text(content)
                    .font(.system(.body, design: .serif))
                    .lineSpacing(4)
                    .padding()
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadChapter()
        }
    }

    private func loadChapter() async {
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension

        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                content = cleanAsciidoc(text)
            }
        }
        isLoading = false
    }

    /// Strip common AsciiDoc markup for readable plain text
    private func cleanAsciidoc(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")

        lines = lines.filter { line in
            // Skip image references, includes, and attribute lines
            !line.hasPrefix("image::") &&
            !line.hasPrefix("include::") &&
            !line.hasPrefix(":") &&
            !line.hasPrefix("ifdef::") &&
            !line.hasPrefix("endif::") &&
            !line.hasPrefix("[[") &&
            !line.hasPrefix("////")
        }

        var result = lines.joined(separator: "\n")

        // Clean up AsciiDoc formatting
        // Remove ((index terms))
        result = result.replacingOccurrences(of: "\\(\\(.*?\\)\\)", with: "", options: .regularExpression)
        // Remove <<cross references>>
        result = result.replacingOccurrences(of: "<<.*?>>", with: "", options: .regularExpression)
        // Convert === headings to bold text
        result = result.replacingOccurrences(of: "^={2,}\\s*", with: "\n", options: .regularExpression)
        // Remove .Title admonitions
        result = result.replacingOccurrences(of: "(?m)^\\.[A-Z].*$", with: "", options: .regularExpression)
        // Remove [role=...] attributes
        result = result.replacingOccurrences(of: "\\[.*?\\]", with: "", options: .regularExpression)
        // Clean pass-through markers
        result = result.replacingOccurrences(of: "pass:[", with: "")
        result = result.replacingOccurrences(of: "++++", with: "")
        // Collapse multiple blank lines
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
