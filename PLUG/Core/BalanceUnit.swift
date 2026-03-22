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
            return String(format: "%.8f BTC", Double(sats) / 100_000_000)
        case .sats:
            return "\(formatSats(sats)) sats"
        case .usd:
            if btcPrice > 0 {
                return String(format: "$%.2f", Double(sats) / 100_000_000 * btcPrice)
            }
            return String(format: "%.8f BTC", Double(sats) / 100_000_000)
        }
    }

    /// Format with split value/unit (for large balance display)
    static func formatSplit(_ sats: UInt64, btcPrice: Double = 0) -> (value: String, unit: String) {
        switch current {
        case .btc:
            return (String(format: "%.8f", Double(sats) / 100_000_000), "BTC")
        case .sats:
            return (formatSats(sats), "sats")
        case .usd:
            if btcPrice > 0 {
                return (String(format: "%.2f", Double(sats) / 100_000_000 * btcPrice), "USD")
            }
            return ("--", "USD")
        }
    }

    /// Format sats with thousand separators (196 732)
    static func formatSats(_ sats: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        return formatter.string(from: NSNumber(value: sats)) ?? "\(sats)"
    }
}
