// ScopePreferences.swift
// RunnerBarCore
import Foundation

// MARK: - ScopePreferences

/// Typed, `Codable` snapshot of all per-scope user preferences.
///
/// Replaces the raw `UserDefaults` string-key API on `ScopePreferencesStore`
/// as the unit of read and write. A full snapshot is always read or written
/// atomically — no partial-save window between individual field writes.
///
/// `nil` fields mean "use the global setting" (same semantics as before).
public struct ScopePreferences: Codable, Sendable, Equatable {

    // MARK: - Fields

    /// Human-readable alias for the scope. `nil` = display raw scope string.
    public var alias: String?

    /// Per-scope polling interval in seconds. `nil` = use global.
    public var pollingInterval: Int?

    /// Per-scope notify-on-success override. `nil` = use global.
    public var notifyOnSuccess: Bool?

    /// Per-scope notify-on-failure override. `nil` = use global.
    public var notifyOnFailure: Bool?

    /// Whether the failure hook is enabled for this scope.
    public var failureHookEnabled: Bool

    /// Shell command to run on failure. `nil` = no command set.
    public var failureHookCommand: String?

    /// Local filesystem path to the repo for this scope. `nil` = not set.
    public var localRepoPath: String?

    /// Branch filter for the failure hook. `nil` = fire for all branches.
    public var failureHookBranch: String?

    // MARK: - Init

    public init(
        alias: String? = nil,
        pollingInterval: Int? = nil,
        notifyOnSuccess: Bool? = nil,
        notifyOnFailure: Bool? = nil,
        failureHookEnabled: Bool = false,
        failureHookCommand: String? = nil,
        localRepoPath: String? = nil,
        failureHookBranch: String? = nil
    ) {
        self.alias = alias
        self.pollingInterval = pollingInterval
        self.notifyOnSuccess = notifyOnSuccess
        self.notifyOnFailure = notifyOnFailure
        self.failureHookEnabled = failureHookEnabled
        self.failureHookCommand = failureHookCommand
        self.localRepoPath = localRepoPath
        self.failureHookBranch = failureHookBranch
    }

    // MARK: - Default

    /// All-`nil` / `false` sentinel used when no preferences have been persisted for a scope.
    public static let `default` = ScopePreferences()
}
