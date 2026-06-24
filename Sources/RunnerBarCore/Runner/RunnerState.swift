// RunnerState.swift
// RunnerBarCore
import Foundation
import Observation

// MARK: - RunnerState

/// Observable read model populated by `RunnerPoller` and consumed by the app layer.
///
/// All five poll-written properties are `public internal(set)` — only
/// `RunnerPoller.applyFetchResult` (same module) should mutate them.
/// Views and app-layer code are read-only consumers.
@Observable
@MainActor
public final class RunnerState {
    /// GitHub-hosted and self-hosted runners across all active scopes.
    public internal(set) var runners: [Runner] = []
    /// Active and recently-completed jobs across all active scopes.
    public internal(set) var jobs: [ActiveJob] = []
    /// Workflow action groups (runs) across all active scopes.
    public internal(set) var actions: [WorkflowActionGroup] = []
    /// Whether the GitHub API rate limit has been hit.
    ///
    /// When `true`, polling is paused until `rateLimitResetDate`.
    public internal(set) var isRateLimited = false
    /// The date at which the rate limit resets, if currently rate-limited.
    public internal(set) var rateLimitResetDate: Date?

    /// Creates a new `RunnerState` with all properties at their default values.
    public init() {}
}
