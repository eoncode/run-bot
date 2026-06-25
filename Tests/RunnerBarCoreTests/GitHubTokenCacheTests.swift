// GitHubTokenCacheTests.swift
// RunnerBarCoreTests
//
// ⚠️ ISOLATION REQUIREMENT
// tokenCache is a process-global Mutex(nil) at module scope. Every test that
// calls githubToken() must call invalidateTokenCache() before returning so that
// cache state does not bleed across cases. This is enforced via `defer` at the
// top of each test body below.
//
// Keychain is never touched: token resolution is exercised through environment
// variables only (GH_TOKEN / GITHUB_TOKEN), keeping these tests sandboxing-free
// and safe to run with `swift test`.

import Foundation
import Testing
@testable import RunnerBarCore

// MARK: - Helpers

/// Sets an environment variable for the duration of the given closure, then
/// restores the previous value (or removes it if it was absent).
private func withEnv(_ key: String, value: String, _ body: () -> Void) {
    let previous = ProcessInfo.processInfo.environment[key]
    setenv(key, value, 1)
    body()
    if let previous {
        setenv(key, previous, 1)
    } else {
        unsetenv(key)
    }
}

// MARK: - GitHubTokenCacheTests

@Suite("GitHubTokenCache")
struct GitHubTokenCacheTests {

    // MARK: - githubToken() — nil path

    /// Returns nil when neither env var is set and the Keychain is empty.
    @Test func githubToken_noSource_returnsNil() {
        defer { invalidateTokenCache() }
        // Remove both env vars for this test.
        let prev1 = ProcessInfo.processInfo.environment["GH_TOKEN"]
        let prev2 = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
        unsetenv("GH_TOKEN")
        unsetenv("GITHUB_TOKEN")
        defer {
            if let prev1 { setenv("GH_TOKEN", prev1, 1) } else { unsetenv("GH_TOKEN") }
            if let prev2 { setenv("GITHUB_TOKEN", prev2, 1) } else { unsetenv("GITHUB_TOKEN") }
        }
        #expect(githubToken() == nil)
    }

    // MARK: - githubToken() — GH_TOKEN

    /// Resolves a token from GH_TOKEN when Keychain is empty.
    @Test func githubToken_ghTokenEnvVar_returnsToken() {
        defer { invalidateTokenCache() }
        withEnv("GH_TOKEN", value: "gh-test-token") {
            unsetenv("GITHUB_TOKEN")
            #expect(githubToken() == "gh-test-token")
        }
    }

    // MARK: - githubToken() — GITHUB_TOKEN fallback

    /// Falls back to GITHUB_TOKEN when GH_TOKEN is absent.
    @Test func githubToken_githubTokenEnvVarFallback_returnsToken() {
        defer { invalidateTokenCache() }
        unsetenv("GH_TOKEN")
        withEnv("GITHUB_TOKEN", value: "github-test-token") {
            #expect(githubToken() == "github-test-token")
        }
    }

    /// Prefers GH_TOKEN over GITHUB_TOKEN when both are set.
    @Test func githubToken_bothEnvVarsSet_prefersGhToken() {
        defer { invalidateTokenCache() }
        withEnv("GH_TOKEN", value: "primary-token") {
            withEnv("GITHUB_TOKEN", value: "fallback-token") {
                #expect(githubToken() == "primary-token")
            }
        }
    }

    // MARK: - githubToken() — cache

    /// Returns the cached value on a second call without re-reading the environment.
    @Test func githubToken_secondCall_returnsFromCache() {
        defer { invalidateTokenCache() }
        withEnv("GH_TOKEN", value: "cached-token") {
            let first = githubToken()
            // Remove the env var so a cache miss would return nil.
            unsetenv("GH_TOKEN")
            let second = githubToken()
            #expect(first == "cached-token")
            #expect(second == "cached-token") // still from cache
        }
    }

    // MARK: - invalidateTokenCache()

    /// Clears a populated cache so the next call re-resolves from source.
    @Test func invalidateTokenCache_clearsCache() {
        defer { invalidateTokenCache() }
        withEnv("GH_TOKEN", value: "original-token") {
            _ = githubToken() // populate cache
            invalidateTokenCache()
            unsetenv("GH_TOKEN")
            // Cache cleared — no env var — should now return nil.
            #expect(githubToken() == nil)
        }
    }

    /// Safe to call when the cache is already nil — does not crash.
    @Test func invalidateTokenCache_whenAlreadyNil_isNoop() {
        // Cache is nil by default (no prior calls in this test).
        invalidateTokenCache() // must not crash
        #expect(githubToken() == nil)
        invalidateTokenCache() // clean up
    }
}
