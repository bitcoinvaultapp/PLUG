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

// MARK: - Chapter Reader (GitHub-style AsciiDoc renderer)

struct ChapterView: View {
    let filename: String
    let title: String
    @State private var blocks: [AdocBlock] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView()
                    .padding(.top, 40)
            } else if blocks.isEmpty {
                Text("Could not load chapter.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
        }
        .background(Color(red: 0.06, green: 0.07, blue: 0.09))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadChapter()
        }
    }

    // MARK: - Block renderer

    @ViewBuilder
    private func blockView(_ block: AdocBlock) -> some View {
        switch block.type {
        case .heading(let level):
            Text(block.content)
                .font(headingFont(level))
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .padding(.top, level <= 2 ? 28 : 20)
                .padding(.bottom, 8)
            if level <= 2 {
                Divider()
                    .background(Color(white: 0.2))
                    .padding(.bottom, 12)
            }

        case .paragraph:
            Text(cleanInline(block.content))
                .font(.system(size: 15))
                .foregroundStyle(Color(white: 0.85))
                .lineSpacing(6)
                .padding(.vertical, 6)
                .textSelection(.enabled)

        case .code:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.content)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color(red: 0.9, green: 0.55, blue: 0.2))
                    .padding(14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.1, green: 0.1, blue: 0.14), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.15), lineWidth: 1))
            .padding(.vertical, 8)

        case .tip:
            admonitionBox(icon: "lightbulb.fill", color: .green, label: "TIP", content: block.content)

        case .warning:
            admonitionBox(icon: "exclamationmark.triangle.fill", color: .orange, label: "WARNING", content: block.content)

        case .note:
            admonitionBox(icon: "info.circle.fill", color: .blue, label: "NOTE", content: block.content)

        case .listItem:
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(Color.btcOrange)
                    .frame(width: 5, height: 5)
                    .padding(.top, 8)
                Text(cleanInline(block.content))
                    .font(.system(size: 15))
                    .foregroundStyle(Color(white: 0.85))
                    .lineSpacing(6)
            }
            .padding(.vertical, 2)
            .padding(.leading, 8)

        case .separator:
            Divider()
                .background(Color(white: 0.15))
                .padding(.vertical, 16)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 28)
        case 2: return .system(size: 22)
        case 3: return .system(size: 18)
        default: return .system(size: 16)
        }
    }

    private func admonitionBox(icon: String, color: Color, label: String, content: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.system(size: 14))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                Text(cleanInline(content))
                    .font(.system(size: 14))
                    .foregroundStyle(Color(white: 0.8))
                    .lineSpacing(4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
        .padding(.vertical, 8)
    }

    // MARK: - Inline cleanup

    private func cleanInline(_ text: String) -> String {
        var s = text
        // Remove ((index terms))
        s = s.replacingOccurrences(of: "\\(\\(.*?\\)\\)", with: "", options: .regularExpression)
        // Remove <<cross references>> but keep display text
        s = s.replacingOccurrences(of: "<<[^,>]+,\\s*([^>]+)>>", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "<<.*?>>", with: "", options: .regularExpression)
        // Remove pass-through
        s = s.replacingOccurrences(of: "pass:[", with: "")
        s = s.replacingOccurrences(of: "++++", with: "")
        // Remove inline formatting markers (keep text)
        s = s.replacingOccurrences(of: "__", with: "")
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "``", with: "")
        // Single markers
        s = s.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "_([^_]+)_", with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - AsciiDoc parser

    private func loadChapter() async {
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension

        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            isLoading = false
            return
        }

        blocks = parseAsciidoc(text)
        isLoading = false
    }

    private func parseAsciidoc(_ text: String) -> [AdocBlock] {
        let lines = text.components(separatedBy: "\n")
        var result: [AdocBlock] = []
        var i = 0
        var inCode = false
        var codeBuffer: [String] = []
        var admonitionType: AdocBlock.BlockType?
        var admonitionBuffer: [String] = []
        var inAdmonition = false

        while i < lines.count {
            let line = lines[i]

            // Skip metadata lines
            if line.hasPrefix("[[") || line.hasPrefix(":") || line.hasPrefix("ifdef::") ||
               line.hasPrefix("endif::") || line.hasPrefix("image::") || line.hasPrefix("include::") ||
               line.hasPrefix("[role=") || line.hasPrefix("////") || line.hasPrefix(".") && line.count > 1 && line.dropFirst().first?.isUpperCase == true {
                i += 1
                continue
            }

            // Code block delimiter
            if line.hasPrefix("----") {
                if inCode {
                    result.append(AdocBlock(type: .code, content: codeBuffer.joined(separator: "\n")))
                    codeBuffer.removeAll()
                    inCode = false
                } else {
                    inCode = true
                }
                i += 1
                continue
            }

            if inCode {
                codeBuffer.append(line)
                i += 1
                continue
            }

            // Admonition block end
            if line == "====" && inAdmonition {
                if let type = admonitionType {
                    result.append(AdocBlock(type: type, content: admonitionBuffer.joined(separator: " ")))
                }
                admonitionBuffer.removeAll()
                admonitionType = nil
                inAdmonition = false
                i += 1
                continue
            }

            if inAdmonition {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    admonitionBuffer.append(trimmed)
                }
                i += 1
                continue
            }

            // Admonition start: [TIP], [WARNING], [NOTE]
            if line == "[TIP]" || line == "[WARNING]" || line == "[NOTE]" || line == "[IMPORTANT]" || line == "[CAUTION]" {
                let type: AdocBlock.BlockType
                switch line {
                case "[TIP]": type = .tip
                case "[WARNING]", "[CAUTION]": type = .warning
                default: type = .note
                }
                admonitionType = type
                // Next line should be ====
                if i + 1 < lines.count && lines[i + 1].hasPrefix("====") {
                    inAdmonition = true
                    i += 2
                } else {
                    i += 1
                }
                continue
            }

            // Headings
            if line.hasPrefix("== ") {
                result.append(AdocBlock(type: .heading(1), content: String(line.dropFirst(3))))
                i += 1
                continue
            }
            if line.hasPrefix("=== ") {
                result.append(AdocBlock(type: .heading(2), content: String(line.dropFirst(4))))
                i += 1
                continue
            }
            if line.hasPrefix("==== ") {
                result.append(AdocBlock(type: .heading(3), content: String(line.dropFirst(5))))
                i += 1
                continue
            }
            if line.hasPrefix("===== ") {
                result.append(AdocBlock(type: .heading(4), content: String(line.dropFirst(6))))
                i += 1
                continue
            }

            // List items
            if line.hasPrefix("* ") {
                result.append(AdocBlock(type: .listItem, content: String(line.dropFirst(2))))
                i += 1
                continue
            }

            // Horizontal rule
            if line == "---" || line == "'''" {
                result.append(AdocBlock(type: .separator, content: ""))
                i += 1
                continue
            }

            // Empty line
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }

            // Paragraph — collect consecutive non-empty lines
            var para: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                if next.trimmingCharacters(in: .whitespaces).isEmpty || next.hasPrefix("==") ||
                   next.hasPrefix("----") || next.hasPrefix("* ") || next.hasPrefix("[") ||
                   next.hasPrefix("[[") || next.hasPrefix("image::") || next.hasPrefix("include::") {
                    break
                }
                para.append(next)
                i += 1
            }
            result.append(AdocBlock(type: .paragraph, content: para.joined(separator: " ")))
        }

        return result
    }
}

// MARK: - AsciiDoc Block Model

struct AdocBlock {
    enum BlockType: Equatable {
        case heading(Int)
        case paragraph
        case code
        case tip
        case warning
        case note
        case listItem
        case separator
    }

    let type: BlockType
    let content: String
}
