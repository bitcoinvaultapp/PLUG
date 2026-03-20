import Foundation
import CommonCrypto

// MARK: - Mempool.space REST API client
// TLS certificate pinning (SPKI SHA-256) via URLSessionDelegate

final class MempoolAPI: NSObject, URLSessionDelegate {

    static let shared = MempoolAPI()

    private lazy var clearnetSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Active session — always clearnet for non-address queries (block height, fees, price).
    /// Address queries use addressRequest() which tries Tor first.
    private var session: URLSession {
        clearnetSession
    }

    private var baseURL: String {
        NetworkConfig.shared.mempoolBaseURL
    }

    // MARK: - TLS Certificate Pinning (SPKI SHA-256)

    /// Pinned SPKI hashes for mempool.space — leaf + intermediate CA.
    /// Rotate when mempool.space renews their certificate.
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

        // Verify at least one certificate in the chain matches a pinned SPKI hash
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        for cert in chain {
            guard let pubKey = SecCertificateCopyKey(cert),
                  let pubKeyData = SecKeyCopyExternalRepresentation(pubKey, nil) as Data? else { continue }
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            pubKeyData.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(pubKeyData.count), &hash) }
            let pin = Data(hash).base64EncodedString()
            if Self.pinnedHashes.contains(pin) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        // No pin matched — reject connection
        #if DEBUG
        print("[PLUG] TLS pin verification FAILED for \(challenge.protectionSpace.host)")
        #endif
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    // MARK: - Generic request

    private func request<T: Decodable>(_ endpoint: String, type: T.Type) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            throw APIError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        return try JSONDecoder().decode(type, from: data)
    }

    /// Whether the user explicitly skipped Tor (allows clearnet address queries)
    static var torSkipped = false

    /// Address-specific request — REQUIRES Tor. Never leaks IP.
    /// Routes through Tor SOCKS5 proxy to mempool .onion (no exit nodes).
    /// Blocks entirely if Tor is unavailable (unless user explicitly skipped).
    private func addressRequest<T: Decodable>(_ endpoint: String, type: T.Type) async throws -> T {
        // Route through Tor SOCKS5 proxy → .onion (stays inside Tor network, no exit)
        if plug_tor_is_running(), let torSession = TorConfig.shared.createTorSession() {
            let isTestnet = NetworkConfig.shared.isTestnet
            let prefix = isTestnet ? "/testnet" : ""
            let onionBase = "http://\(TorConfig.shared.onionAddress)\(prefix)/api"
            if let url = URL(string: "\(onionBase)\(endpoint)") {
                let (data, response) = try await torSession.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                return try JSONDecoder().decode(type, from: data)
            }
        }

        // User explicitly chose "Skip — use clearnet"
        if Self.torSkipped {
            return try await request(endpoint, type: type)
        }

        // Tor not running and not skipped — block to protect privacy
        throw APIError.torRequired
    }

    private func requestRaw(_ endpoint: String) async throws -> Data {
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            throw APIError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        return data
    }

    private func requestText(_ endpoint: String) async throws -> String {
        let data = try await requestRaw(endpoint)
        guard let text = String(data: data, encoding: .utf8) else {
            throw APIError.decodingError
        }
        return text
    }

    // MARK: - Price

    func getBTCPrice() async throws -> Double {
        struct PriceResponse: Decodable {
            let USD: Int
        }
        let response = try await request("/v1/prices", type: PriceResponse.self)
        return Double(response.USD)
    }

    // MARK: - Fees

    func getRecommendedFees() async throws -> FeeEstimate {
        try await request("/v1/fees/recommended", type: FeeEstimate.self)
    }

    // MARK: - Blockchain info

    func getBlockHeight() async throws -> Int {
        let text = try await requestText("/blocks/tip/height")
        guard let height = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw APIError.decodingError
        }
        return height
    }

    func getBlockHash(height: Int) async throws -> String {
        try await requestText("/block-height/\(height)")
    }

    func getDifficultyAdjustment() async throws -> DifficultyAdjustment {
        try await request("/v1/difficulty-adjustment", type: DifficultyAdjustment.self)
    }

    // MARK: - Address

    func getAddressUTXOs(address: String) async throws -> [UTXO] {
        struct MempoolUTXO: Decodable {
            let txid: String
            let vout: Int
            let value: UInt64
            let status: UTXO.UTXOStatus
        }

        let utxos = try await addressRequest("/address/\(address)/utxo", type: [MempoolUTXO].self)
        return utxos.map { utxo in
            UTXO(
                txid: utxo.txid,
                vout: utxo.vout,
                value: utxo.value,
                address: address,
                scriptPubKey: "",
                status: utxo.status
            )
        }
    }

    func getAddressTransactions(address: String) async throws -> [Transaction] {
        try await addressRequest("/address/\(address)/txs", type: [Transaction].self)
    }

    func hasTransactions(address: String) async throws -> Bool {
        struct AddressInfo: Decodable {
            let chainStats: ChainStats
            let mempoolStats: ChainStats

            struct ChainStats: Decodable {
                let txCount: Int
                enum CodingKeys: String, CodingKey {
                    case txCount = "tx_count"
                }
            }

            enum CodingKeys: String, CodingKey {
                case chainStats = "chain_stats"
                case mempoolStats = "mempool_stats"
            }
        }

        let info = try await addressRequest("/address/\(address)", type: AddressInfo.self)
        return info.chainStats.txCount > 0 || info.mempoolStats.txCount > 0
    }

    // MARK: - Transaction

    func getTransaction(txid: String) async throws -> Transaction {
        try await request("/tx/\(txid)", type: Transaction.self)
    }

    func broadcastTransaction(hex: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/tx") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = hex.data(using: .utf8)
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.broadcastFailed(errorText)
        }

        guard let txid = String(data: data, encoding: .utf8) else {
            throw APIError.decodingError
        }

        return txid.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Errors

    enum APIError: LocalizedError {
        case invalidURL
        case httpError(Int)
        case decodingError
        case broadcastFailed(String)
        case torRequired

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL"
            case .httpError(let code): return "HTTP error \(code)"
            case .decodingError: return "Decoding error"
            case .broadcastFailed(let msg): return "Broadcast failed: \(msg)"
            case .torRequired: return "Tor disconnected — address queries blocked to protect your privacy"
            }
        }
    }
}
