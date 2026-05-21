import Foundation
import Security

// MARK: - Keychain
//
// Wraps Security.framework to store and retrieve the OAuth token.
// Uses SecItemAdd (with kSecAttrUpdateItemIfExistentKey to upsert),
// SecItemCopyMatching, and SecItemDelete — no subprocess required.

enum Keychain {
    private static let service = "runner-bar"
    private static let account = "github-oauth-token"

    // MARK: - Private helpers

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    // MARK: - Public API

    /// The stored OAuth token, or nil if none is present.
    static var token: String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return token.isEmpty ? nil : token
    }

    /// Saves (or overwrites) the token and invalidates the in-memory token cache.
    static func save(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }
        // Try update first; fall back to add if item does not exist.
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery()
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                log("Keychain.save › SecItemAdd failed: \(addStatus)")
            }
        } else if updateStatus != errSecSuccess {
            log("Keychain.save › SecItemUpdate failed: \(updateStatus)")
        }
        invalidateTokenCache()
    }

    /// Deletes the stored token and invalidates the in-memory token cache.
    static func delete() {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            log("Keychain.delete › SecItemDelete failed: \(status)")
        }
        invalidateTokenCache()
    }
}
