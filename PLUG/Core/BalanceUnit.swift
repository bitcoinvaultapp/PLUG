import Foundation

enum BalanceUnit: String, CaseIterable {
    case btc, sats, usd

    var next: BalanceUnit {
        let all = Self.allCases
        let idx = all.firstIndex(of: self)!
        return all[(idx + 1) % all.count]
    }

    /// Current global preference
    static var current: BalanceUnit {
        let raw = UserDefaults.standard.string(forKey: "balance_unit") ?? "btc"
        return BalanceUnit(rawValue: raw) ?? .btc
    }

    /// Format a sats amount using the current global preference.
    /// Pass btcPrice for USD conversion (0 = skip USD).
    static func format(_ sats: UInt64, btcPrice: Double = 0) -> String {
        switch current {
        case .btc:
            let btc = Double(sats) / 100_000_000
            return String(format: "%.8f BTC", btc)
        case .sats:
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = " "
            let formatted = formatter.string(from: NSNumber(value: sats)) ?? "\(sats)"
            return "\(formatted) sats"
        case .usd:
            if btcPrice > 0 {
                let usd = Double(sats) / 100_000_000 * btcPrice
                return String(format: "$%.2f", usd)
            }
            // No price available — show BTC
            let btc = Double(sats) / 100_000_000
            return String(format: "%.8f BTC", btc)
        }
    }
}
