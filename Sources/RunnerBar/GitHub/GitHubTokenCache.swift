// GitHubTokenCache.swift
// RunnerBar
//
// Forwarding shim — githubToken() and invalidateTokenCache() have moved
// to RunnerBarCore/GitHub/GitHubTokenCache.swift.
//
// These two forwarding functions bridge existing unqualified call-sites in
// RunnerBar (OAuthService, SwiftUI views) without re-exporting the entire
// RunnerBarCore module namespace via @_exported import.
//
// TODO: Delete this file immediately post-merge. Before deleting, update
// the ~6 call-sites in RunnerBar to use the qualified RunnerBarCore symbols
// directly (they already resolve via the existing `import RunnerBarCore`).
import RunnerBarCore

/// Forwarding shim — resolves to `RunnerBarCore.githubToken()`.
/// - SeeAlso: `RunnerBarCore/GitHub/GitHubTokenCache.swift`
@_disfavoredOverload
@inline(__always)
func githubToken() -> String? {
    RunnerBarCore.githubToken()
}

/// Forwarding shim — resolves to `RunnerBarCore.invalidateTokenCache()`.
/// - SeeAlso: `RunnerBarCore/GitHub/GitHubTokenCache.swift`
@_disfavoredOverload
@inline(__always)
func invalidateTokenCache() {
    RunnerBarCore.invalidateTokenCache()
}
