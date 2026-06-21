// GitHubTransportShim.swift
// RunnerBarCore
//
// Provides module-level `ghAPI`, `ghRaw`, `ghAPIPaginated` symbols
// for RunnerBarCore consumers (WorkflowActionGroupFetch, RunnerStatusEnricher,
// LogFetcher).
//
// These are thin forwarding stubs backed by configurable transport closures so
// that:
//   • RunnerBarCore stays independent of the RunnerBar app target.
//   • Tests can inject a mock transport without touching URLSession.
//   • The app target wires the real GitHubURLSessionTransport at launch.
//
import Foundation
import os

// MARK: - Transport types

/// An async GitHub API fetch returning raw JSON `Data`.
/// Used for standard REST GET endpoints.
public typealias GHAPITransport = @Sendable (_ endpoint: String) async -> Data?

/// An async raw-bytes fetch for GitHub log endpoints.
/// These endpoints 302-redirect to S3; the transport must follow redirects.
public typealias GHRawTransport = @Sendable (_ endpoint: String) async -> Data?

/// An async paginated GitHub API fetch returning concatenated JSON array `Data`.
/// Used for list endpoints that follow `Link: rel="next"` pagination.
/// Returns `nil` on auth failure; may return partial results on rate-limit.
///
/// - Parameters:
///   - endpoint: Relative or absolute URL for the first page.
///   - timeout: Per-request timeout forwarded to `URLSession` **for each page**.
///
/// - Warning: The `timeout` value must be forwarded explicitly into the inner
///   call. The closure signature accepts `timeout` as its second parameter, but
///   Swift’s type-checker will silently accept a `_` wildcard that drops it:
///   ```swift
///   // ⚠️ WRONG — compiles but silently falls back to the 60-second default:
///   configureGHAPIPaginated { endpoint, _ in
///       await urlSessionAPIPaginated(endpoint)
///   }
///   // ✅ CORRECT — forward timeout explicitly:
///   configureGHAPIPaginated { endpoint, timeout in
///       await urlSessionAPIPaginated(endpoint, timeout: timeout)
///   }
///   ```
///   Callers must also account for the fact that a paginated fetch may issue
///   many sequential requests; total wall-clock time can exceed `timeout` by
///   a factor of the page count.
///
/// - Note: `apiCallCounter` counts one call per `ghAPIPaginated()` invocation,
///   not one per page fetched. Real quota consumption for a 40-page list fetch
///   is 40 calls; the counter will record 1. See `APICallCounterRow` tooltip.
public typealias GHAPIPaginatedTransport = @Sendable (_ endpoint: String, _ timeout: TimeInterval) async -> Data?

/// A sync closure that returns the active GitHub personal access token, or `nil`.
public typealias GHTokenProvider = @Sendable () -> String?

// MARK: - TransportBox

/// Thread-safe wrapper around an `OSAllocatedUnfairLock`-guarded closure.
///
/// `OSAllocatedUnfairLock.withLock` accepts a **synchronous** closure only.
/// This is intentional: `os_unfair_lock` must not be held across a suspension
/// point. Transport closures are `async`, so they are *never* called from
/// inside `withLock` — only read out under the lock, then invoked outside it.
private struct TransportBox<T: Sendable> {
    /// The underlying unfair lock guarding the stored value.
    private let lock: OSAllocatedUnfairLock<T>

    /// Creates a box with `initialState` as the starting value.
    init(initialState: T) { lock = .init(initialState: initialState) }

    /// Replaces the stored closure under the lock.
    ///
    /// Safe to call from any thread or actor context; the lock is held only
    /// for the duration of the pointer swap — no async work inside.
    func configure(_ value: T) {
        lock.withLock { $0 = value }
    }

    /// Returns the stored closure under the lock.
    ///
    /// The caller is responsible for invoking the returned closure *outside*
    /// the lock. Never pass an `async` closure into `withLock`.
    func read() -> T { lock.withLock { $0 } }
}

// MARK: - Module-level state

/// Serialises all reads and writes to the active JSON transport closure.
private let transportBox = TransportBox<GHAPITransport>(initialState: { _ in nil })

/// Serialises all reads and writes to the active raw-bytes transport closure.
private let rawTransportBox = TransportBox<GHRawTransport>(initialState: { _ in nil })

/// Serialises all reads and writes to the active paginated JSON transport closure.
private let paginatedTransportBox = TransportBox<GHAPIPaginatedTransport>(initialState: { _, _ in nil })

/// Serialises all reads and writes to the active token-provider closure.
private let tokenProviderBox = TransportBox<GHTokenProvider>(initialState: { nil })

// MARK: - Configuration

/// Wire up the real (or mock) GitHub JSON transport. Call once at launch.
/// - Parameter transport: Async closure for JSON REST calls; returns `nil` on failure.
public func configureGHAPI(
    _ transport: @escaping GHAPITransport
) {
    transportBox.configure(transport)
}

/// Wire up the raw-bytes transport for log endpoints. Call once at launch.
/// - Parameter rawTransport: Async closure that fetches raw log bytes;
///   must follow 302 redirects, as GitHub log endpoints redirect to S3.
///   Returns `nil` on failure.
public func configureGHRaw(_ rawTransport: @escaping GHRawTransport) {
    rawTransportBox.configure(rawTransport)
}

/// Wire up the real (or mock) paginated JSON transport. Call once at launch.
///
/// - Parameter transport: Async closure for paginated REST calls.
///   **Always forward `timeout` explicitly** — see `GHAPIPaginatedTransport`
///   for the silent-misconfiguration warning.
public func configureGHAPIPaginated(_ transport: @escaping GHAPIPaginatedTransport) {
    paginatedTransportBox.configure(transport)
}

/// Wire up the token provider. Call once at launch.
/// - Parameter provider: Sync closure returning the current GitHub token.
public func configureGHToken(_ provider: @escaping GHTokenProvider) {
    tokenProviderBox.configure(provider)
}

// MARK: - Module-level symbols consumed by RunnerBarCore files

/// Calls the configured GitHub API transport for the given endpoint.
///
/// `apiCallCounter` is incremented via a fire-and-forget `Task` **only when
/// the transport returns non-nil data** — i.e. on a successful dispatch.
/// Stub/unconfigured transports (returning `nil`) and auth failures are
/// therefore not counted, keeping the counter accurate to actual REST calls.
func ghAPI(_ endpoint: String) async -> Data? {
    let transport = transportBox.read()
    let result = await transport(endpoint)
    if result != nil { _ = Task { await apiCallCounter.record() } }
    return result
}

/// Calls the configured raw-bytes transport for the given endpoint.
///
/// Raw log fetches hit S3 and do **not** consume the GitHub REST quota —
/// `apiCallCounter` is intentionally not incremented here.
func ghRaw(_ endpoint: String) async -> Data? {
    let transport = rawTransportBox.read()
    return await transport(endpoint)
}

/// Calls the configured paginated JSON transport for the given endpoint.
///
/// `apiCallCounter` is incremented once per invocation (not per page) via a
/// fire-and-forget `Task` when the transport returns non-nil data.
/// See `GHAPIPaginatedTransport` and `APICallCounterRow` for the undercount caveat.
///
/// - Parameters:
///   - endpoint: Relative or absolute URL for the first page.
///   - timeout: Per-request timeout forwarded to the transport. Defaults to 60s.
///
/// - Important: This function is annotated `@concurrent`, **not**
///   `nonisolated(nonsending)`. `paginatedTransportBox.read()` acquires an
///   `OSAllocatedUnfairLock` before the first suspension point; `@concurrent`
///   guarantees execution on the cooperative thread pool at that point.
///   `nonisolated(nonsending)` is only valid for pure pass-throughs with no
///   pre-suspension work — switching to it would silently remove that
///   guarantee without a compiler error.
@concurrent
public func ghAPIPaginated(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
    let transport = paginatedTransportBox.read()
    let result = await transport(endpoint, timeout)
    if result != nil { _ = Task { await apiCallCounter.record() } }
    return result
}

/// Returns the active GitHub token via the configured provider.
func githubTokenCore() -> String? {
    let provider = tokenProviderBox.read()
    return provider()
}
