// FailureHookRunner.swift
// RunnerBar
import Foundation

// MARK: - FailureHookRunner

/// Fires the user-configured failure shell hook when a workflow action group fails.
///
/// All methods are `static` — `FailureHookRunner` is a pure namespace with no stored state.
enum FailureHookRunner {

    /// Fires the failure hook if the given action group meets the firing criteria.
    ///
    /// Delegates to `FailureHookRunnerUseCase` for idempotency tracking and
    /// actual hook execution.
    ///
    /// - Parameters:
    ///   - group: The workflow action group to evaluate.
    ///   - scope: The repo/org scope string (e.g. `"owner/repo"`).
    ///   - callsite: A string tag included in log output to identify the call origin.
    static func fireIfNeeded(
        group: WorkflowActionGroup,
        scope: String,
        callsite: String
    ) async {
        let useCase = FailureHookRunnerUseCase(
            preferencesStore: AppPreferencesStore.shared
        )
        await useCase.fireIfNeeded(group: group, scope: scope, callsite: callsite)
    }
}
