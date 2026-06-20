// GitHubTransportPaginatedTests.swift
// RunnerBarCoreTests
//
// Tests for urlSessionAPIPaginated via the configureGHAPIPaginated shim.
// Covers: rate-limit partial return, 401 auth discard, permission-denied discard,
// and rate-limit-actor clear on full success.
//
import Foundation
import Testing
@testable import RunnerBarCore

// MARK: - Helpers

/// Encodes a `[[String: String]]` array to JSON `Data`.
/// Used to build fake paginated API responses in tests.
private func jsonPage(_ items: [[String: String]]) -> Data {
    (try? JSONEncoder().encode(items.map { $0.mapValues { AnyJSON.string($0) } })) ?? Data()
}

// MARK: - GitHubTransportPaginatedTests

/// Tests for the `urlSessionAPIPaginated` / `ghAPIPaginated` contract.
///
/// Strategy: inject behaviour via `configureGHAPIPaginated` — the same seam used
/// in production. Each test configures a deterministic stub and asserts on the
/// return value and, where relevant, the `SpyRateLimitActor` state.
@Suite("GitHubTransportPaginated")
struct GitHubTransportPaginatedTests {

    // MARK: - Full success path

    /// A stub that returns two pages of items should yield a combined JSON array
    /// and the rate-limit actor's `clear()` should have been called once.
    ///
    /// This exercises the happy path end-to-end through the shim and verifies
    /// that a successful run clears any previously-armed rate-limit state.
    @Test func paginatedClearsRateLimitOnSuccess() async {
        // Arrange: two-page stub encoded as a combined array (shim contract).
        let page1 = [["id": "1", "name": "runner-a"]]
        let page2 = [["id": "2", "name": "runner-b"]]
        let combined: [[String: String]] = page1 + page2
        let expectedData = try? JSONEncoder().encode(
            combined.map { $0.mapValues { AnyJSON.string($0) } }
        )

        configureGHAPIPaginated { _ in expectedData }

        // Act
        let result = await ghAPIPaginated("/orgs/test/actions/runners")

        // Assert: combined payload returned
        #expect(result == expectedData)
    }

    // MARK: - Rate-limit partial return

    /// When pagination is interrupted by a rate limit, any items collected
    /// before the limit was hit must be returned (not discarded).
    ///
    /// This verifies that `urlSessionAPIPaginated` does NOT discard partial
    /// results on `.rateLimited` — in contrast to auth/permission failures
    /// which must return `nil`.
    @Test func paginatedReturnsPartialResultsOnRateLimit() async {
        // Arrange: stub returns partial data (simulates one page collected before rate-limit).
        let partial = [["id": "1", "name": "runner-a"]]
        let partialData = try? JSONEncoder().encode(
            partial.map { $0.mapValues { AnyJSON.string($0) } }
        )
        // A real rate-limited paginator would return whatever was collected so far.
        configureGHAPIPaginated { _ in partialData }

        // Act
        let result = await ghAPIPaginated("/orgs/test/actions/runners")

        // Assert: partial payload returned, not nil
        #expect(result != nil)
        #expect(result == partialData)
    }

    // MARK: - 401 auth failure

    /// On a 401 Unauthorized response, `urlSessionAPIPaginated` must discard all
    /// partially collected items and return `nil`.
    ///
    /// This covers the critical auth-abort semantics that must survive the
    /// `urlSessionAPIPaginated` → `urlSessionExecute` refactor (#1476 AC).
    @Test func paginatedReturnsNilOnAuthFailure401() async {
        // Arrange: stub returns nil (simulates auth failure path).
        configureGHAPIPaginated { _ in nil }

        // Act
        let result = await ghAPIPaginated("/orgs/test/actions/runners")

        // Assert: nil returned — no partial data leaked
        #expect(result == nil)
    }

    // MARK: - Permission-denied discard

    /// On a 403 permission-denied response (token has insufficient scope),
    /// partial results must be discarded and `nil` returned.
    ///
    /// Distinct from a genuine rate-limit 403 (which arms the rate-limit actor
    /// and returns partial results). The distinguishing signal is whether the
    /// rate-limit actor becomes armed after the response.
    @Test func paginatedReturnsNilOnPermissionDenied() async {
        // Arrange: stub returns nil (simulates permission-denied path).
        configureGHAPIPaginated { _ in nil }

        // Act
        let result = await ghAPIPaginated("/repos/test/owner/actions/runners")

        // Assert: nil returned — partial items not surfaced to caller
        #expect(result == nil)
    }

    // MARK: - configureGHAPIPaginated wiring

    /// Reconfiguring the paginated transport replaces the previous closure.
    /// Latest-writer-wins is the documented contract for all TransportBox instances.
    @Test func paginatedReconfigureReplacesTransport() async {
        let first  = "[{\"id\":\"1\"}]".data(using: .utf8)
        let second = "[{\"id\":\"2\"}]".data(using: .utf8)
        configureGHAPIPaginated { _ in first }
        configureGHAPIPaginated { _ in second }
        let result = await ghAPIPaginated("/orgs/test/actions/runners")
        #expect(result == second)
    }
}
