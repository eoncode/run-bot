// FailureHookRunnerAdapters.swift
// RunnerBar
//
// Lightweight production adapters that bridge the static-only
// `ScopePreferencesStore` and `TerminalLauncher` singletons to the
// instance-based protocols expected by `FailureHookRunnerUseCase`.
import Foundation
import RunnerBarCore

// MARK: - DefaultScopePreferencesStore

/// Forwards all calls to the static `ScopePreferencesStore` methods.
/// Used as the production dependency for `FailureHookRunnerUseCase`.
public struct DefaultScopePreferencesStore: ScopePreferencesStoreProtocol {
    /// Creates a store backed by the static `ScopePreferencesStore` singleton.
    public init() {}

    /// Forwards to `ScopePreferencesStore.failureHookEnabled(for:)`.
    public func failureHookEnabled(for scope: String) -> Bool {
        ScopePreferencesStore.failureHookEnabled(for: scope)
    }
    /// Forwards to `ScopePreferencesStore.failureHookCommand(for:)`.
    public func failureHookCommand(for scope: String) -> String? {
        ScopePreferencesStore.failureHookCommand(for: scope)
    }
    /// Forwards to `ScopePreferencesStore.failureHookBranch(for:)`.
    public func failureHookBranch(for scope: String) -> String? {
        ScopePreferencesStore.failureHookBranch(for: scope)
    }
    /// Forwards to `ScopePreferencesStore.localRepoPath(for:)`.
    public func localRepoPath(for scope: String) -> String? {
        ScopePreferencesStore.localRepoPath(for: scope)
    }
}

// MARK: - DefaultTerminalLauncher

/// Forwards `open(command:)` to `TerminalLauncher.open(command:)`.
/// Used as the production dependency for `FailureHookRunnerUseCase`.
public struct DefaultTerminalLauncher: TerminalLauncherProtocol {
    /// Creates a launcher backed by `TerminalLauncher.open(command:)`.
    public init() {}

    /// Forwards to `TerminalLauncher.open(command:)`. Must be called on `@MainActor`.
    @MainActor
    public func open(command: String) {
        TerminalLauncher.open(command: command)
    }
}
