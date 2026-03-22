import Foundation
import CommonCrypto

// MARK: - Mempool.space / Personal Node REST API client
// Two modes: clearnet (URLSession + TLS pinning) or Tor (plug_tor_fetch/post)

final class MempoolAPI: NSObject, URLSessionDelegate {

    static let shared = MempoolAPI()

    /// Whether the user explicitly skipped Tor (allows clearnet address queries)
    static var torSkipped = false

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var baseURL: String { NetworkConfig.shared.mempoolBaseURL }

    // MARK: - TLS Certificate Pinning (SPKI SHA-256)

    // Leaf cert expires: 2026-09-28. Rotate BEFORE this date.
    // Extract new pins:
    //   echo | openssl s_client -connect mempool.space:443 2>/dev/null \
    //     | openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER \
    //     | openssl dgst -sha256 -binary | base64
    private static let pinnedHashes: Set<String> = [
        "wV7micOM/PJtIxPpaZBTdQF0JnfIHXSGzrvsu7fzDdQ=", // leaf
        "KqkYYX5LYAYP7XGemqzbtPPIA8x7BS/BbOIcAXf3j2k=", // intermediate CA
    ]

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              challenge.protectionSpace.host.hasSuffix("mempool.space") else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        for cert in chain {
            guard let pubKey = SecCertificateCopyKey(cert),
                  let pubKeyData = SecKeyCopyExternalRepresentation(pubKey, nil) as Data? else { continue }
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            pubKeyData.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(pubKeyData.count), &hash) }
            if Self.pinnedHashes.contains(Data(hash).base64EncodedString()) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        #if DEBUG
        print("[PLUG] TLS pin verification FAILED for \(challenge.protectionSpace.host)")
        #endif
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    // MARK: - Core transport (2 paths: Tor or clearnet)

    /// Fetch via Tor — direct Arti stream, serialized, 60s timeout in Rust.
    /// Retries once on failure with 2s backoff.
    private func torGET(_ endpoint: String) async throws -> String {
        let (host, path) = TorConfig.shared.resolve(endpoint: endpoint)

        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                #if DEBUG
                print("[Tor] Retry \(path)")
                #endif
            }

            let result: String? = await Task.detached(priority: .userInitiated) {
                guard let h = host.cString(using: .utf8),
                      let p = path.cString(using: .utf8),
                      let ptr = plug_tor_fetch(h, 80, p) else { return nil as String? }
                let s = String(cString: ptr)
                plug_tor_free_string(ptr)
                return s
            }.value

            if let s = result, !s.isEmpty { return s }
        }
        throw APIError.torFetchFailed
    }

    /// POST via Tor — for broadcasting transactions.
    /// 3 attempts with exponential backoff (0s, 2s, 4s).
    private func torPOST(_ endpoint: String, body: String) async throws -> String {
        let (host, path) = TorConfig.shared.resolve(endpoint: endpoint)
        var lastError = "onion service unreachable"

        for attempt in 0..<3 {
            if attempt > 0 {
                let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                try? await Task.sleep(nanoseconds: delay)
                #if DEBUG
                print("[Tor] POST retry \(attempt + 1)/3")
                #endif
            }

            let result: String? = await Task.detached(priority: .userInitiated) {
                guard let h = host.cString(using: .utf8),
                      let p = path.cString(using: .utf8),
                      let b = body.cString(using: .utf8),
                      let ptr = plug_tor_post(h, 80, p, b) else { return nil as String? }
                let s = String(cString: ptr)
                plug_tor_free_string(ptr)
                return s
            }.value

            if let s = result?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s
            }
            lastError = result ?? "onion service unreachable"
        }
        throw APIError.broadcastFailed("Tor failed after 3 attempts: \(lastError)")
    }

    /// Clearnet GET — URLSession with TLS pinning.
    private func clearnetGET(_ endpoint: String) async throws -> Data {
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            throw APIError.invalidURL
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    /// Smart GET — Tor if running, clearnet fallback if skipped.
    /// For privacy-sensitive queries (addresses, transactions).
    private func privateGET<T: Decodable>(_ endpoint: String, type: T.Type) async throws -> T {
        if plug_tor_is_running() {
            let raw = try await torGET(endpoint)
            guard let data = raw.data(using: .utf8) else { throw APIError.decodingError }
            return try JSONDecoder().decode(type, from: data)
        }
        if Self.torSkipped {
            let data = try await clearnetGET(endpoint)
            return try JSONDecoder().decode(type, from: data)
        }
        throw APIError.torRequired
    }

    /// Smart GET returning text — Tor if running, clearnet fallback.
    private func privateText(_ endpoint: String) async throws -> String {
        if plug_tor_is_running() {
            return try await torGET(endpoint)
        }
        if Self.torSkipped {
            let data = try await clearnetGET(endpoint)
            guard let text = String(data: data, encoding: .utf8) else { throw APIError.decodingError }
            return text
        }
        throw APIError.torRequired
    }

    /// Public GET — non-sensitive data (price, difficulty). Always clearnet.
    private func publicGET<T: Decodable>(_ endpoint: String, type: T.Type) async throws -> T {
        let data = try await clearnetGET(endpoint)
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: - Price (public, non-sensitive)

    func getBTCPrice() async throws -> Double {
        struct R: Decodable { let USD: Int }
        return Double(try await publicGET("/v1/prices", type: R.self).USD)
    }

    // MARK: - Fees

    func getRecommendedFees() async throws -> FeeEstimate {
        if plug_tor_is_running(), TorConfig.shared.usePersonalNode {
            // Electrs: {"1": 87.882, "3": 50.5, ...}
            let raw = try await torGET("/fee-estimates")
            guard let data = raw.data(using: .utf8) else { throw APIError.decodingError }
            let m = try JSONDecoder().decode([String: Double].self, from: data)
            return FeeEstimate(
                fastestFee: Int(m["1"] ?? m["2"] ?? 1),
                halfHourFee: Int(m["3"] ?? m["6"] ?? 1),
                hourFee: Int(m["6"] ?? m["12"] ?? 1),
                economyFee: Int(m["12"] ?? m["24"] ?? 1),
                minimumFee: Int(m["144"] ?? m["504"] ?? 1)
            )
        }
        return try await publicGET("/v1/fees/recommended", type: FeeEstimate.self)
    }

    // MARK: - Blockchain info

    func getBlockHeight() async throws -> Int {
        let text = try await privateText("/blocks/tip/height")
        guard let h = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw APIError.decodingError
        }
        return h
    }

    func getBlockHash(height: Int) async throws -> String {
        try await privateText("/block-height/\(height)")
    }

    func getDifficultyAdjustment() async throws -> DifficultyAdjustment {
        // Not available on Electrs — always clearnet
        try await publicGET("/v1/difficulty-adjustment", type: DifficultyAdjustment.self)
    }

    // MARK: - Address (private — always Tor)

    func getAddressUTXOs(address: String) async throws -> [UTXO] {
        struct R: Decodable {
            let txid: String; let vout: Int; let value: UInt64; let status: UTXO.UTXOStatus
        }
        return try await privateGET("/address/\(address)/utxo", type: [R].self).map {
            UTXO(txid: $0.txid, vout: $0.vout, value: $0.value, address: address,
                 scriptPubKey: "", status: $0.status)
        }
    }

    func getAddressTransactions(address: String) async throws -> [Transaction] {
        try await privateGET("/address/\(address)/txs", type: [Transaction].self)
    }

    func hasTransactions(address: String) async throws -> Bool {
        struct Stats: Decodable {
            let txCount: Int
            enum CodingKeys: String, CodingKey { case txCount = "tx_count" }
        }
        struct R: Decodable {
            let chainStats: Stats; let mempoolStats: Stats
            enum CodingKeys: String, CodingKey {
                case chainStats = "chain_stats"; case mempoolStats = "mempool_stats"
            }
        }
        let info = try await privateGET("/address/\(address)", type: R.self)
        return info.chainStats.txCount > 0 || info.mempoolStats.txCount > 0
    }

    // MARK: - Transaction

    func getTransaction(txid: String) async throws -> Transaction {
        try await privateGET("/tx/\(txid)", type: Transaction.self)
    }

    /// Fetch raw transaction hex (for BIP174 NON_WITNESS_UTXO)
    func getRawTransaction(txid: String) async throws -> String {
        try await privateText("/tx/\(txid)/hex")
    }

    func broadcastTransaction(hex: String) async throws -> String {
        if plug_tor_is_running() {
            let txid = try await torPOST("/tx", body: hex)
            guard isValidTxid(txid) else {
                throw APIError.broadcastFailed("Invalid txid: \(txid)")
            }
            return txid
        }

        // Clearnet fallback
        guard let url = URL(string: "\(baseURL)/tx") else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = hex.data(using: .utf8)
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.broadcastFailed(String(data: data, encoding: .utf8) ?? "Unknown error")
        }
        guard let txid = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              isValidTxid(txid) else {
            throw APIError.broadcastFailed("Invalid txid returned")
        }
        return txid
    }

    private func isValidTxid(_ txid: String) -> Bool {
        txid.count == 64 && txid.allSatisfy(\.isHexDigit)
    }

    // MARK: - Errors

    enum APIError: LocalizedError {
        case invalidURL
        case httpError(Int)
        case decodingError
        case broadcastFailed(String)
        case torRequired
        case torFetchFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL"
            case .httpError(let code): return "HTTP error \(code)"
            case .decodingError: return "Decoding error"
            case .broadcastFailed(let msg): return "Broadcast failed: \(msg)"
            case .torRequired: return "Tor disconnected — address queries blocked to protect your privacy"
            case .torFetchFailed: return "Tor fetch failed — onion service unreachable"
            }
        }
    }
}
