// CommitRunnerEdit.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - CommitResult

/// The outcome of a `SaveRunnerEditsUseCase.execute` call.
enum CommitResult {
    /// All requested writes succeeded.
    case success
    /// One or more writes failed. `errors` contains human-readable messages.
    case failure([String])
}
