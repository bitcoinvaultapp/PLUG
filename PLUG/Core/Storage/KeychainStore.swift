import Foundation
import Security
import UIKit

// MARK: - Keychain wrapper
// Hardware-backed encryption with kSecAttrAccessibleWhenUnlockedThisDeviceOnly
// Stores xpubs, scripts, witnessScripts

final class KeychainStore {

    static let shared = KeychainStore()

    private let service = "com.plug.bitcoin"

    enum KeychainKey: String {
        case xpub = "xpub_main"
        case xpubTestnet = "xpub_testnet"
        case contracts = "contracts_data"
        case walletAddresses = "wallet_addresses"
        case ledgerMasterFingerprint = "ledger_master_fingerprint"
        case ledgerOriginalXpub = "ledger_original_xpub"
        case ledgerCoinType = "ledger_coin_type"
    }

    // MARK: - Generic CRUD

    func save(_ data: Data, forKey key: String) -> Bool {
        // Delete existing first
        delete(forKey: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    func load(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    func delete(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Typed accessors

    func saveString(_ string: String, forKey key: String) -> Bool {
        guard let data = string.data(using: .utf8) else { return false }
        return save(data, forKey: key)
    }

    func loadString(forKey key: String) -> String? {
        guard let data = load(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveCodable<T: Encodable>(_ object: T, forKey key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(object) else { return false }
        return save(data, forKey: key)
    }

    func loadCodable<T: Decodable>(forKey key: String, type: T.Type) -> T? {
        guard let data = load(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - xpub management

    func saveXpub(_ xpub: String, isTestnet: Bool) {
        let key = isTestnet ? KeychainKey.xpubTestnet.rawValue : KeychainKey.xpub.rawValue
        saveString(xpub, forKey: key)
    }

    func loadXpub(isTestnet: Bool) -> String? {
        let key = isTestnet ? KeychainKey.xpubTestnet.rawValue : KeychainKey.xpub.rawValue
        return loadString(forKey: key)
    }

    func deleteXpub(isTestnet: Bool) {
        let key = isTestnet ? KeychainKey.xpubTestnet.rawValue : KeychainKey.xpub.rawValue
        delete(forKey: key)
    }

    // MARK: - Clear all

    func clearAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Secure Clipboard

/// Copy string to clipboard with auto-clear after timeout.
/// Use for sensitive data (preimages, scripts, PSBTs).
func secureCopy(_ value: String, clearAfter seconds: TimeInterval = 30) {
    UIPasteboard.general.string = value
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        if UIPasteboard.general.string == value {
            UIPasteboard.general.string = ""
        }
    }
}
