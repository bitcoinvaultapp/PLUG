import SwiftUI
import WebKit

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

// MARK: - Chapter Reader (GitHub-rendered HTML via WKWebView)

struct ChapterView: View {
    let filename: String
    let title: String
    @State private var htmlContent: String = ""
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.07, blue: 0.09).ignoresSafeArea()

            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading from GitHub...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let error = loadError {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            } else {
                ChapterWebView(html: htmlContent)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadFromGitHub()
        }
    }

    private func loadFromGitHub() async {
        let apiURL = "https://api.github.com/repos/bitcoinbook/bitcoinbook/contents/\(filename)"

        guard let url = URL(string: apiURL) else {
            loadError = "Invalid URL"
            isLoading = false
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.html", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                loadError = "Could not fetch chapter."
                isLoading = false
                return
            }

            let body = String(data: data, encoding: .utf8) ?? ""
            htmlContent = wrapInDarkTheme(body)
        } catch {
            loadError = "Network error. Check your connection."
        }

        isLoading = false
    }

    private func wrapInDarkTheme(_ body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>
            * { box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                background: #0D1117;
                color: #E6EDF3;
                padding: 16px;
                margin: 0;
                font-size: 16px;
                line-height: 1.7;
                -webkit-text-size-adjust: 100%;
            }
            h1, h2, h3, h4, h5 {
                color: #FFFFFF;
                font-weight: 700;
                margin-top: 28px;
                margin-bottom: 12px;
                border-bottom: 1px solid #21262D;
                padding-bottom: 8px;
            }
            h1 { font-size: 26px; }
            h2 { font-size: 22px; }
            h3 { font-size: 18px; border: none; }
            h4 { font-size: 16px; border: none; }
            p { margin: 12px 0; color: #C9D1D9; }
            a { color: #F7931A; text-decoration: none; }
            a:active { opacity: 0.7; }
            code, pre code {
                font-family: 'SF Mono', 'Menlo', monospace;
                font-size: 13px;
            }
            code {
                background: #161B22;
                padding: 2px 6px;
                border-radius: 4px;
                color: #F7931A;
            }
            pre {
                background: #161B22;
                border: 1px solid #21262D;
                border-radius: 8px;
                padding: 14px;
                overflow-x: auto;
                -webkit-overflow-scrolling: touch;
            }
            pre code {
                background: none;
                padding: 0;
                color: #E6EDF3;
            }
            ul, ol { padding-left: 24px; color: #C9D1D9; }
            li { margin: 4px 0; }
            li::marker { color: #F7931A; }
            em { color: #C9D1D9; font-style: italic; }
            strong { color: #FFFFFF; }
            table {
                border-collapse: collapse;
                width: 100%;
                margin: 16px 0;
                font-size: 14px;
            }
            th, td {
                border: 1px solid #21262D;
                padding: 8px 12px;
                text-align: left;
            }
            th { background: #161B22; color: #F7931A; font-weight: 600; }
            td { color: #C9D1D9; }
            tr:nth-child(even) td { background: #0D1117; }
            tr:nth-child(odd) td { background: #161B22; }
            blockquote {
                border-left: 3px solid #F7931A;
                margin: 16px 0;
                padding: 8px 16px;
                color: #8B949E;
                background: #161B22;
                border-radius: 0 8px 8px 0;
            }
            hr {
                border: none;
                border-top: 1px solid #21262D;
                margin: 24px 0;
            }
            img { max-width: 100%; border-radius: 8px; }
            .anchor, .octicon { display: none; }
            svg { display: none; }
            .markdown-heading { margin-top: 24px; }
            markdown-accessiblity-table { display: block; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}

// MARK: - WKWebView wrapper

struct ChapterWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 1)
        webView.scrollView.backgroundColor = UIColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 1)
        webView.scrollView.indicatorStyle = .white
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}
