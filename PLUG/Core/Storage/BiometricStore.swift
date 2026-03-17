import Foundation
import LocalAuthentication

// MARK: - Biometric Authentication
// Face ID / Touch ID gating for app access
// Persists preference in UserDefaults

final class BiometricStore: ObservableObject {

    static let shared = BiometricStore()

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: enabledKey)
        }
    }

    @Published var isLocked: Bool = false

    private let enabledKey = "biometric_enabled"
    private let context = LAContext()

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
    }

    // MARK: - Biometry info

    var biometryType: LABiometryType {
        let ctx = LAContext()
        var error: NSError?
        ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return ctx.biometryType
    }

    var biometryName: String {
        switch biometryType {
        case .faceID:
            return "Face ID"
        case .touchID:
            return "Touch ID"
        case .opticID:
            return "Optic ID"
        @unknown default:
            return "Biometrics"
        }
    }

    var isAvailable: Bool {
        let ctx = LAContext()
        var error: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    // MARK: - Authentication

    func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        var error: NSError?

        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }

        do {
            let success = try await ctx.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            return success
        } catch {
            return false
        }
    }

    // MARK: - Enable / Disable

    func enable() {
        isEnabled = true
    }

    func disable() {
        isEnabled = false
        isLocked = false
    }

    // MARK: - App lifecycle

    func lockApp() {
        guard isEnabled else { return }
        isLocked = true
    }

    func unlockApp() async -> Bool {
        guard isEnabled, isLocked else { return true }

        let success = await authenticate(reason: "Unlock PLUG")
        if success {
            await MainActor.run {
                isLocked = false
            }
        }
        return success
    }
}
