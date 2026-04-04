import Foundation
import Security

/// Generic per-vendor API key storage in iOS Keychain.
/// Each vendor gets its own independent keychain entry.
enum APIKeychain {
    private static let service = "com.vomo.apikey"

    static func save(vendor: String, key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vendor
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vendor,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func load(vendor: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vendor,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    static func delete(vendor: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vendor
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func hasKey(vendor: String) -> Bool {
        load(vendor: vendor) != nil
    }

    // MARK: - Migration

    /// Migrate existing GrokKeychain key to APIKeychain on first launch.
    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "apiKeychain.migrated") else { return }
        if let existingKey = GrokKeychain.load() {
            _ = save(vendor: VoiceVendor.xai.rawValue, key: existingKey)
            print("🔑 [APIKeychain] Migrated Grok API key → xai")
        }
        defaults.set(true, forKey: "apiKeychain.migrated")
    }
}
