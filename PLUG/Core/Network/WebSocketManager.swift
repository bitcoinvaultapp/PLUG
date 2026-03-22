import Foundation

// MARK: - WebSocket Manager
// Real-time updates from Mempool.space (mainnet clearnet only)

final class WebSocketManager: ObservableObject {

    static let shared = WebSocketManager()

    @Published var latestBlockHeight: Int = 0
    @Published var btcPrice: Double = 0
    @Published var isConnected: Bool = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 3

    func connect() {
        disconnect()

        // Skip WebSocket for testnet4 — endpoint doesn't exist
        if NetworkConfig.shared.isTestnet {
            #if DEBUG
            print("[WS] WebSocket disabled for testnet4")
            #endif
            return
        }

        // Block WebSocket when Tor is active — clearnet WS leaks IP
        if plug_tor_is_running() {
            #if DEBUG
            print("[WS] WebSocket disabled — Tor active (clearnet WS would leak IP)")
            #endif
            return
        }

        guard let url = URL(string: NetworkConfig.shared.mempoolWSURL) else { return }
        session = URLSession(configuration: .default)
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()

        isConnected = true

        // Subscribe to blocks and price
        let subscribeMsg = """
        {"action":"want","data":["blocks","stats","mempool-blocks"]}
        """
        send(subscribeMsg)

        receiveMessage()
        startPing()
    }

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session = nil
        isConnected = false
    }

    private func send(_ message: String) {
        webSocketTask?.send(.string(message)) { error in
            if let error {
                #if DEBUG
                print("[WS] Send error: \(error)")
                #endif
            }
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self?.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                // Continue receiving
                self?.receiveMessage()

            case .failure(let error):
                #if DEBUG
                print("[WS] Receive error: \(error)")
                #endif
                DispatchQueue.main.async {
                    self?.isConnected = false
                }
                // Reconnect with limit to avoid infinite loop
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.reconnectAttempts += 1
                    if self.reconnectAttempts <= self.maxReconnectAttempts {
                        let delay = Double(self.reconnectAttempts) * 10 // 10s, 20s, 30s
                        #if DEBUG
                        print("[WS] Reconnect attempt \(self.reconnectAttempts)/\(self.maxReconnectAttempts) in \(delay)s")
                        #endif
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            self.connect()
                        }
                    } else {
                        #if DEBUG
                        print("[WS] Max reconnect attempts reached, stopping")
                        #endif
                    }
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        DispatchQueue.main.async { [weak self] in
            // Block update
            if let block = json["block"] as? [String: Any],
               let height = block["height"] as? Int {
                self?.latestBlockHeight = height
            }

            // Price from conversions
            if let conversions = json["conversions"] as? [String: Any],
               let usd = conversions["USD"] as? Double {
                self?.btcPrice = usd
            }
        }
    }

    private func startPing() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.webSocketTask?.sendPing { error in
                if let error {
                    #if DEBUG
                    print("[WS] Ping error: \(error)")
                    #endif
                    DispatchQueue.main.async {
                        self?.isConnected = false
                    }
                }
            }
        }
    }
}
