import SwiftUI
import WebKit

// MARK: - Chapter data model

private struct Chapter: Identifiable {
    let id: String  // filename
    let number: Int?
    let title: String
    let desc: String
    let icon: String
    let color: Color
}

private struct ChapterSection: Identifiable {
    let id: String
    let title: String
    let chapters: [Chapter]
}

private let bookSections: [ChapterSection] = [
    ChapterSection(id: "fund", title: "Fundamentals", chapters: [
        Chapter(id: "ch01_intro.adoc", number: 1, title: "Introduction", desc: "What is Bitcoin, the protocol stack", icon: "bitcoinsign.circle.fill", color: .orange),
        Chapter(id: "ch02_overview.adoc", number: 2, title: "How Bitcoin Works", desc: "Transactions, blocks, and mining overview", icon: "gearshape.2.fill", color: .blue),
        Chapter(id: "ch03_bitcoin-core.adoc", number: 3, title: "Bitcoin Core", desc: "The reference implementation", icon: "desktopcomputer", color: .gray),
    ]),
    ChapterSection(id: "keys", title: "Keys & Wallets", chapters: [
        Chapter(id: "ch04_keys.adoc", number: 4, title: "Keys and Addresses", desc: "Public/private key cryptography", icon: "key.fill", color: .yellow),
        Chapter(id: "ch05_wallets.adoc", number: 5, title: "Wallet Recovery", desc: "Backup and recovery methods", icon: "wallet.bifold.fill", color: .purple),
    ]),
    ChapterSection(id: "tx", title: "Transactions", chapters: [
        Chapter(id: "ch06_transactions.adoc", number: 6, title: "Transactions", desc: "Structure, inputs, outputs, UTXO model", icon: "arrow.left.arrow.right", color: .green),
        Chapter(id: "ch07_authorization-authentication.adoc", number: 7, title: "Authorization", desc: "Script mechanisms and spending rules", icon: "lock.shield.fill", color: .teal),
        Chapter(id: "ch08_signatures.adoc", number: 8, title: "Digital Signatures", desc: "ECDSA and Schnorr algorithms", icon: "signature", color: .indigo),
        Chapter(id: "ch09_fees.adoc", number: 9, title: "Transaction Fees", desc: "Fee estimation and mempool", icon: "gauge.with.dots.needle.33percent", color: .orange),
    ]),
    ChapterSection(id: "net", title: "Network & Consensus", chapters: [
        Chapter(id: "ch10_network.adoc", number: 10, title: "The Bitcoin Network", desc: "Peer-to-peer architecture", icon: "network", color: .blue),
        Chapter(id: "ch11_blockchain.adoc", number: 11, title: "The Blockchain", desc: "Blocks, links, and validation", icon: "square.stack.3d.up.fill", color: .cyan),
        Chapter(id: "ch12_mining.adoc", number: 12, title: "Mining and Consensus", desc: "Proof-of-work and incentives", icon: "hammer.fill", color: .orange),
    ]),
    ChapterSection(id: "adv", title: "Advanced", chapters: [
        Chapter(id: "ch13_security.adoc", number: 13, title: "Bitcoin Security", desc: "Key custody and hardware wallets", icon: "shield.checkered", color: .red),
        Chapter(id: "ch14_applications.adoc", number: 14, title: "Second-Layer Apps", desc: "Payment channels and Lightning", icon: "bolt.fill", color: .yellow),
    ]),
    ChapterSection(id: "app", title: "Appendices", chapters: [
        Chapter(id: "appa_whitepaper.adoc", number: nil, title: "The Bitcoin Whitepaper", desc: "Satoshi Nakamoto's original paper", icon: "doc.text.fill", color: .orange),
        Chapter(id: "appc_bips.adoc", number: nil, title: "Bitcoin Improvement Proposals", desc: "BIP framework overview", icon: "list.bullet.rectangle.fill", color: .green),
    ]),
]

private let allChapterIds: [String] = bookSections.flatMap { $0.chapters.map(\.id) }

// MARK: - Reading Progress Store

private final class ReadingStore: ObservableObject {
    static let shared = ReadingStore()

    @Published var readChapters: Set<String> {
        didSet { UserDefaults.standard.set(Array(readChapters), forKey: "learn_read_chapters") }
    }
    @Published var scrollPositions: [String: Double] {
        didSet { UserDefaults.standard.set(scrollPositions, forKey: "learn_scroll_positions") }
    }

    init() {
        readChapters = Set(UserDefaults.standard.stringArray(forKey: "learn_read_chapters") ?? [])
        scrollPositions = (UserDefaults.standard.dictionary(forKey: "learn_scroll_positions") as? [String: Double]) ?? [:]
    }

    func markRead(_ id: String) { readChapters.insert(id) }
    func saveScroll(_ id: String, position: Double) { scrollPositions[id] = position }

    var totalChapters: Int { allChapterIds.count }
    var readCount: Int { readChapters.intersection(allChapterIds).count }
    var progress: Double {
        totalChapters > 0 ? Double(readCount) / Double(totalChapters) : 0
    }
}

// MARK: - LearnView

struct LearnView: View {
    @ObservedObject private var store = ReadingStore.shared

    var body: some View {
        NavigationStack {
            List {
                PlugHeader(pageName: "Learn")
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                // Hero — book cover
                heroSection
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 16, trailing: 0))

                // Chapter sections
                ForEach(bookSections) { section in
                    Section {
                        ForEach(section.chapters) { chapter in
                            if chapter.id == "appa_whitepaper.adoc" {
                                NavigationLink {
                                    WhitepaperView()
                                } label: {
                                    chapterRow(chapter)
                                }
                                .listRowBackground(Color.clear)
                            } else {
                                NavigationLink {
                                    ChapterView(
                                        filename: chapter.id,
                                        title: chapter.number.map { "Ch. \($0) — \(chapter.title)" } ?? chapter.title
                                    )
                                } label: {
                                    chapterRow(chapter)
                                }
                                .listRowBackground(Color.clear)
                            }
                        }
                    } header: {
                        Text(section.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(spacing: 16) {
            // Book cover
            if let coverPath = Bundle.main.path(forResource: "cover", ofType: "png", inDirectory: "bitcoinbook/images"),
               let uiImage = UIImage(contentsOfFile: coverPath) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
            }

            VStack(spacing: 4) {
                Text("Mastering Bitcoin")
                    .font(.system(size: 20, weight: .bold))
                Text("3rd Edition")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.btcOrange)
                Text("Andreas M. Antonopoulos & David A. Harding")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // Overall progress
            HStack(spacing: 12) {
                ProgressView(value: store.progress)
                    .tint(Color.btcOrange)
                Text("\(store.readCount)/\(store.totalChapters)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Chapter Row

    private func chapterRow(_ chapter: Chapter) -> some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: chapter.icon)
                .font(.system(size: 15))
                .foregroundStyle(chapter.color)
                .frame(width: 28, height: 28)
                .background(chapter.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

            // Number + title + description
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let n = chapter.number {
                        Text("\(n)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(chapter.color.opacity(0.5), in: Circle())
                    }
                    Text(chapter.title)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(chapter.desc)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Read indicator
            if store.readChapters.contains(chapter.id) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
            }

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.quaternary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Chapter Reader

struct ChapterView: View {
    let filename: String
    let title: String

    @ObservedObject private var store = ReadingStore.shared
    @State private var htmlContent: String = ""
    @State private var loadError: String?
    @State private var scrollProgress: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.btcOrange)
                    .frame(width: max(0, geo.size.width * scrollProgress), height: 2)
                    .animation(.easeOut(duration: 0.15), value: scrollProgress)
            }
            .frame(height: 2)

            if let error = loadError {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if !htmlContent.isEmpty {
                ChapterWebView(
                    html: htmlContent,
                    imagesPath: bundleImagesPath,
                    onScroll: { progress in
                        scrollProgress = progress
                        store.saveScroll(filename, position: progress)
                        if progress > 0.8 {
                            store.markRead(filename)
                        }
                    }
                )
            }
        }
        .background(Color.bgDark.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                navigationButtons
            }
        }
        .onAppear { loadLocal() }
    }

    // MARK: - Chapter navigation (prev/next)

    private var currentIndex: Int? {
        allChapterIds.firstIndex(of: filename)
    }

    private var navigationButtons: some View {
        HStack(spacing: 16) {
            if let idx = currentIndex, idx > 0 {
                NavigationLink {
                    ChapterView(filename: allChapterIds[idx - 1], title: chapterTitle(allChapterIds[idx - 1]))
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if let idx = currentIndex, idx < allChapterIds.count - 1 {
                NavigationLink {
                    ChapterView(filename: allChapterIds[idx + 1], title: chapterTitle(allChapterIds[idx + 1]))
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chapterTitle(_ id: String) -> String {
        for section in bookSections {
            if let ch = section.chapters.first(where: { $0.id == id }) {
                return ch.number.map { "Ch. \($0) — \(ch.title)" } ?? ch.title
            }
        }
        return id
    }

    // MARK: - Local loading

    private var bundleImagesPath: String? {
        Bundle.main.path(forResource: "images", ofType: nil, inDirectory: "bitcoinbook")
    }

    private func loadLocal() {
        guard htmlContent.isEmpty else { return }
        guard let path = Bundle.main.path(
            forResource: filename.replacingOccurrences(of: ".adoc", with: ""),
            ofType: "adoc", inDirectory: "bitcoinbook"
        ) else {
            loadError = "Chapter not found in bundle"
            return
        }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            loadError = "Unable to read chapter"
            return
        }
        htmlContent = wrapInDarkTheme(AsciidocParser.toHTML(content))
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
                font-family: 'New York', 'Georgia', serif;
                background: #0D1117;
                color: #D1D5DB;
                padding: 20px 24px 80px 24px;
                margin: 0;
                font-size: 17px;
                line-height: 1.8;
                -webkit-text-size-adjust: 100%;
            }
            h1, h2, h3, h4, h5 {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                color: #FFFFFF;
                font-weight: 700;
                margin-top: 32px;
                margin-bottom: 12px;
            }
            h1 { font-size: 28px; border-bottom: 1px solid #21262D; padding-bottom: 8px; }
            h2 { font-size: 23px; border-bottom: 1px solid #21262D; padding-bottom: 6px; }
            h3 { font-size: 19px; }
            h4 { font-size: 16px; }
            p { margin: 14px 0; }
            a { color: #F7931A; text-decoration: none; }
            a:active { opacity: 0.7; }
            code, pre code {
                font-family: 'SF Mono', 'Menlo', monospace;
                font-size: 14px;
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
                border-radius: 10px;
                padding: 16px;
                overflow-x: auto;
                -webkit-overflow-scrolling: touch;
            }
            pre code { background: none; padding: 0; color: #E6EDF3; }
            ul, ol { padding-left: 24px; }
            li { margin: 6px 0; }
            li::marker { color: #F7931A; }
            em { font-style: italic; }
            strong { color: #FFFFFF; }
            table {
                border-collapse: collapse;
                width: 100%;
                margin: 16px 0;
                font-size: 14px;
            }
            th, td {
                border: 1px solid #21262D;
                padding: 10px 12px;
                text-align: left;
            }
            th { background: #161B22; color: #F7931A; font-weight: 600; }
            td { color: #C9D1D9; }
            tr:nth-child(even) td { background: #0D1117; }
            tr:nth-child(odd) td { background: #161B22; }
            blockquote {
                border-left: 3px solid #F7931A;
                margin: 20px 0;
                padding: 12px 20px;
                color: #9CA3AF;
                background: #161B22;
                border-radius: 0 10px 10px 0;
                font-style: italic;
            }
            blockquote strong { color: #F7931A; font-style: normal; }
            hr { border: none; border-top: 1px solid #21262D; margin: 28px 0; }
            img { max-width: 100%; border-radius: 10px; margin: 12px 0; }
            figure { margin: 16px 0; text-align: center; }
            figcaption {
                font-size: 13px; color: #6B7280; margin-top: 6px;
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            }
            .figure-title {
                font-size: 14px; color: #9CA3AF; font-style: italic;
                margin-bottom: 4px;
            }
            .anchor, .octicon, svg { display: none; }
        </style>
        <script>
            window.addEventListener('scroll', function() {
                var h = document.documentElement.scrollHeight - window.innerHeight;
                var p = h > 0 ? window.scrollY / h : 0;
                window.webkit.messageHandlers.scroll.postMessage(p);
            });
        </script>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}

// MARK: - WKWebView with scroll tracking

struct ChapterWebView: UIViewRepresentable {
    let html: String
    var imagesPath: String?
    var onScroll: ((Double) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "scroll")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 1)
        webView.scrollView.backgroundColor = UIColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 1)
        webView.scrollView.indicatorStyle = .white

        // Load once here — not in updateUIView to avoid reload loops
        let baseURL: URL?
        if let imgPath = imagesPath {
            baseURL = URL(fileURLWithPath: imgPath).deletingLastPathComponent()
        } else {
            baseURL = nil
        }
        webView.loadHTMLString(html, baseURL: baseURL)

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Do nothing — HTML loaded in makeUIView. Prevents reload on every SwiftUI re-render.
    }

    class Coordinator: NSObject, WKScriptMessageHandler {
        let onScroll: ((Double) -> Void)?
        init(onScroll: ((Double) -> Void)?) { self.onScroll = onScroll }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let progress = message.body as? Double {
                DispatchQueue.main.async { self.onScroll?(progress) }
            }
        }
    }
}

// MARK: - Bitcoin Whitepaper PDF Viewer

import PDFKit

struct WhitepaperView: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "bitcoin", withExtension: "pdf") {
            PDFViewer(url: url)
                .ignoresSafeArea(edges: .bottom)
                .background(Color.bgDark.ignoresSafeArea())
                .navigationTitle("The Bitcoin Whitepaper")
                .navigationBarTitleDisplayMode(.inline)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("PDF not found in bundle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.bgDark.ignoresSafeArea())
            .navigationTitle("The Bitcoin Whitepaper")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct PDFViewer: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = PDFDocument(url: url)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = UIColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 1)
        pdfView.pageBreakMargins = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {}
}
