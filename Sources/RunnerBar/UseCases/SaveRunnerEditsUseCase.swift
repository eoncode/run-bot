// SaveRunnerEditsUseCase.swift
// RunnerBar
// Phase 5 of the Swift 6.2 data model modernisation (#1287, #1300).
import Foundation
import RunnerBarCore

// MARK: - RunnerLabelsService

/// Abstraction over the `patchRunnerLabels` network call.
/// Inject a test double in unit tests; use `DefaultRunnerLabelsService` in production.
protocol RunnerLabelsService: Sendable {
    /// Replaces the full label set for a runner.
    /// Returns `true` on success, `false` on any API failure.
    func patch(scope: String, runnerID: Int, labels: [String]) async -> Bool
}

// MARK: - SaveRunnerEditsUseCase

/// Testable, dependency-injected replacement for the `commitRunnerEdit` free function.
///
/// Executes the three-step commit transaction:
/// 1. **Labels** (GitHub API) — aborts on failure.
/// 2. **Runner JSON** — workFolder + disableUpdate.
/// 3. **Proxy files** — `.proxy` and `.proxycredentials`.
///
/// Dependencies are injected at the call site; no singletons are accessed inside
/// `execute(...)`. Use `RunnerConfigStore.shared`, `RunnerProxyStore.shared`,
/// and `DefaultRunnerLabelsService()` for production.
///
/// - Note: Part of Phase 5 of the Swift 6.2 data model modernisation (#1287, #1300).
struct SaveRunnerEditsUseCase: Sendable {

    // MARK: Dependencies

    let configStore: RunnerConfigStore
    let proxyStore: RunnerProxyStore
    let labelsService: any RunnerLabelsService

    // MARK: - execute

    /// Persists all changed fields in `draft` for `runner`.
    ///
    /// - Returns: `.success` when all writes succeed;
    ///   `.failure([String])` with human-readable messages otherwise.
    func execute(
        runner: RunnerModel,
        draft: RunnerEditDraft,
        original: RunnerEditDraft
    ) async -> CommitResult {
        // TODO: Port transaction logic from commitRunnerEdit.
        fatalError("SaveRunnerEditsUseCase.execute — not yet implemented (Phase 5 stub)")
    }
}
