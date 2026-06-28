// GitHubTransportShimTests.swift
// RunnerBarCoreTests
import Foundation
import Testing

@testable import RunnerBarCore

// MARK: - GitHubTransportShimTests

/// Tests for the module-level configure/read transport shim functions in
/// `GitHubTransportShim.swift`, exercising the `TransportBox`-backed behaviour
/// via the public `configure*` and internal `gh*` entry points.
///
/// `.serialized` is required because all tests share the same module-level
/// `TransportBox` singletons. Without serialization, concurrent tests race to
/// overwrite each other's configured transport, producing non-deterministic
/// failures (e.g. `ghAPICallsConfiguredTransport` reading a 6-byte payload
/// written by `ghAPIReconfigureReplacesTransport`).
@Suite("GitHubTransportShim", .serialized)
struct GitHubTransportShimTests {

  // MARK: - configureGHAPI / ghAPI

  /// Injected `GHAPITransport` is called and its return value propagated.
  /// Verifies that `ghAPI()` routes calls through the transport instance currently registered via `configureGitHubTransport`.
  @Test func ghAPICallsConfiguredTransport() async {
    let expected = "{\"id\":1}".data(using: .utf8)
    configureGHAPI { _ in expected }
    let result = await ghAPI("/repos/test")
    #expect(result == expected)
  }

  /// Reconfiguring `GHAPITransport` replaces the previous closure — latest value wins.
  /// Verifies that calling `configureGitHubTransport` a second time replaces the previous transport so subsequent `ghAPI()` calls use the new instance.
  @Test func ghAPIReconfigureReplacesTransport() async {
    let first = "first".data(using: .utf8)
    let second = "second".data(using: .utf8)
    configureGHAPI { _ in first }
    configureGHAPI { _ in second }
    let result = await ghAPI("/repos/test")
    #expect(result == second)
  }

  // MARK: - configureGHRaw / ghRaw

  /// Injected `GHRawTransport` is called and its return value propagated.
  /// Verifies that `ghRaw()` routes calls through the transport instance currently registered via `configureGitHubTransport`.
  @Test func ghRawCallsConfiguredTransport() async {
    let expected = Data([0x01, 0x02, 0x03])
    configureGHRaw { _ in expected }
    let result = await ghRaw("/logs/123")
    #expect(result == expected)
  }

  /// Reconfiguring `GHRawTransport` replaces the previous closure — latest value wins.
  /// Verifies that calling `configureGitHubTransport` a second time replaces the previous transport so subsequent `ghRaw()` calls use the new instance.
  @Test func ghRawReconfigureReplacesTransport() async {
    let first = Data([0xAA])
    let second = Data([0xBB])
    configureGHRaw { _ in first }
    configureGHRaw { _ in second }
    let result = await ghRaw("/logs/123")
    #expect(result == second)
  }

  // MARK: - configureGHToken / githubTokenCore

  /// Injected `GHTokenProvider` is called and its return value propagated.
  /// Verifies that `githubTokenCore()` returns the token string supplied to `configureGitHubTokenProvider`.
  @Test func githubTokenCoreReturnsConfiguredToken() {
    configureGHToken { "test-token-abc" }
    #expect(githubTokenCore() == "test-token-abc")
  }

  /// Reconfiguring the token provider replaces the previous closure — latest value wins.
  /// Verifies that calling `configureGitHubTokenProvider` a second time replaces the previous provider so `githubTokenCore()` returns the new token.
  @Test func githubTokenCoreReconfigureReplacesProvider() {
    configureGHToken { "old-token" }
    configureGHToken { "new-token" }
    #expect(githubTokenCore() == "new-token")
  }

  /// A token provider returning `nil` propagates `nil` correctly.
  /// Verifies that `githubTokenCore()` returns `nil` when the configured provider returns `nil`.
  @Test func githubTokenCoreReturnsNilWhenProviderReturnsNil() {
    configureGHToken { nil }
    #expect(githubTokenCore() == nil)
  }
}
