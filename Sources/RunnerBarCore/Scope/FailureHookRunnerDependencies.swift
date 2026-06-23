// FailureHookRunnerDependencies.swift
// RunnerBarCore
import Foundation

// MARK: - FailureHookScopePreferencesProtocol

/// Abstracts the subset of `ScopePreferencesStore` that `FailureHookRunnerUseCase` needs,
/// so the use-case can be tested without hitting `UserDefaults` on disk.
///
/// **Intentionally decoupled from `ScopePreferencesStoreProtocol`** (the view-layer protocol
/// introduced in #1540). The two protocols share overlapping method names by design — each
/// serves a different isolation domain:
/// - `ScopePreferencesStoreProtocol` is `@MainActor + AnyObject`, scoped to SwiftUI views.
/// - `FailureHookScopePreferencesProtocol` is `Sendable` and value-type-friendly, so it can
///   be satisfied by actors and background-safe types used in use-case / runner layers.
///
/// A single conformer satisfying **both** protocols must bridge `@MainActor` and `Sendable`
/// explicitly — e.g. by annotating the type `@MainActor` and marking it `Sendable` (which is
/// safe on a main-actor-isolated type). Avoid `@unchecked Sendable` as a shortcut here.
public protocol FailureHookScopePreferencesProtocol: Sendable {
    /// Returns `true` if the failure hook is enabled for the given scope.
    func failureHookEnabled(for scope: String) -> Bool
    /// Returns the custom failure-hook command stored for the given scope, or `nil` if none is set.
    func failureHookCommand(for scope: String) -> String?
    /// Returns the branch filter for the failure hook, or `nil` if all branches should trigger.
    func failureHookBranch(for scope: String) -> String?
    /// Returns the local repository path configured for the given scope, or `nil` if not set.
    func localRepoPath(for scope: String) -> String?
}

// MARK: - TerminalLauncherProtocol

/// Abstracts `TerminalLauncher.open(command:)` so `FailureHookRunnerUseCase` can be
/// tested without spawning an actual Terminal.app window.
///
/// `open(command:)` is `@MainActor` — `NSAppleScript` must run on the main thread.
/// The protocol has no actor-isolation requirement at the type level; only
/// `open(command:)` requires `@MainActor`.
public protocol TerminalLauncherProtocol: Sendable {
    /// Opens a Terminal.app window and runs `command`. Must be called on `@MainActor`.
    @MainActor func open(command: String)
}
