import Foundation

// MARK: - Keychain
//
// Wraps the macOS `security` CLI to store and retrieve the OAuth token.
// No entitlements or code-signing identity required — works in unsigned
// and ad-hoc signed builds alike.
//
// Shell escaping: GitHub OAuth tokens are always `gho_[A-Za-z0-9]+`.
// Single-quote escaping is sufficient; no other shell metacharacters appear.

enum Keychain {
    private static let service = "runner-bar"
    private static let account = "github-oauth-token"

    /// The stored OAuth token, or nil if none is present.
    static var token: String? {
        let raw = shell(
            "/usr/bin/security find-generic-password -s \(service) -a \(account) -w 2>/dev/null",
            timeout: 20
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    /// Saves (or overwrites) the token and invalidates the in-memory token cache.
    static func save(_ token: String) {
        let escaped = token.replacingOccurrences(of: "'", with: "'\\''")
        _ = shell(
            "/usr/bin/security add-generic-password -s \(service) -a \(account) -w '\(escaped)' -U 2>/dev/null",
            timeout: 20
        )
        invalidateTokenCache()
    }

    /// Deletes the stored token and invalidates the in-memory token cache.
    static func delete() {
        _ = shell(
            "/usr/bin/security delete-generic-password -s \(service) -a \(account) 2>/dev/null",
            timeout: 20
        )
        invalidateTokenCache()
    }
}
