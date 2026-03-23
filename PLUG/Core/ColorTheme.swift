import SwiftUI
import UIKit

// MARK: - App Color Theme
// Adaptive colors — automatically switch between light and dark mode.

extension Color {
    // Backgrounds
    static let bgDark = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.07, green: 0.07, blue: 0.11, alpha: 1)
            : UIColor.systemBackground
    })
    static let cardDark = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.11, green: 0.11, blue: 0.16, alpha: 1)
            : UIColor.secondarySystemBackground
    })

    // Accent — stays orange in both modes
    static let btcOrange = Color(red: 0.97, green: 0.58, blue: 0.10)

    // Contract colors — same in both modes
    static let vaultYellow = Color(red: 0.93, green: 0.79, blue: 0.15)
    static let inheritancePurple = Color(red: 0.65, green: 0.40, blue: 0.90)
    static let poolTeal = Color(red: 0.20, green: 0.82, blue: 0.73)
    static let accentGreen = Color(red: 0.30, green: 0.85, blue: 0.40)

    // Text
    static let dimText = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.45, green: 0.45, blue: 0.52, alpha: 1)
            : UIColor.secondaryLabel
    })
}

// MARK: - Appearance Setting

enum AppAppearance: String, CaseIterable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
