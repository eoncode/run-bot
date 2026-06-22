// WorkflowActionGroupFetcher.swift
// RunnerBarCore
import Foundation

// MARK: - WorkflowActionGroupFetcher

/// Thin injectable wrapper around the `fetchActionGroups` free function.
///
/// Wrapping the free function in a class allows `RunnerStore` to accept a
/// test double at init time (dependency injection) rather than calling the
/// production free function directly from inside the actor body.
///
/// Production callers pass `WorkflowActionGroupFetcher()` (the default);
/// unit tests substitute a subclass or a protocol-conforming fake.
///
/// - Note: `final` is intentional. The DI seam is subclassing-based for now
///   (override `fetch(for:cache:)` in a test double). A follow-up issue will
///   extract a `WorkflowActionGroupFetcherProtocol` to align with the
///   protocol-oriented DI pattern used by every other injected dependency
///   in this codebase (Principle 7).
public final class WorkflowActionGroupFetcher {

    /// Creates a new fetcher instance.
    public init() {}

    /// Fetches active workflow-action groups for `scope`, merging results
    /// with the supplied `cache`.
    ///
    /// Delegates directly to the `fetchActionGroups` free function defined
    /// in `WorkflowActionGroupFetch.swift`.
    ///
    /// - Parameters:
    ///   - scope: A `owner/repo` slug.
    ///   - cache: SHA-keyed group cache from the previous poll.
    /// - Returns: Sorted array of `WorkflowActionGroup` values.
    public func fetch(for scope: String, cache: [String: WorkflowActionGroup] = [:]) async -> [WorkflowActionGroup] {
        await fetchActionGroups(for: scope, cache: cache)
    }
}
