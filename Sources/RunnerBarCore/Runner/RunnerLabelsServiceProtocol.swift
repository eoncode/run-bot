// RunnerLabelsServiceProtocol.swift
// RunnerBarCore
// Phase 5 of the Swift 6.2 data model modernisation (#1287, #1300).
import Foundation

// MARK: - RunnerLabelsService

/// Abstraction over the `patchRunnerLabels` network call.
///
/// Inject a test double in unit tests; use `DefaultRunnerLabelsService` in production.
/// Returns the updated label names on success, `nil` on any failure — matching
/// the underlying `patchRunnerLabels` free function signature.
public protocol RunnerLabelsService: Sendable {
    /// Replaces ALL custom labels on the runner identified by `runnerID` within `scope`.
    /// - Returns: The updated label names on success, `nil` on any API failure.
    func patch(scope: String, runnerID: Int, labels: [String]) async -> [String]?
}
