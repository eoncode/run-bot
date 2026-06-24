// RunnerViewModelProtocol.swift
// RunnerBarCore
import Foundation

// MARK: - RunnerViewModelProtocol

/// Push-receiver interface through which `RunnerStore` and `LocalRunnerStore` deliver
/// their computed snapshots to the main-actor presentation layer.
///
/// Declaring the protocol in `RunnerBarCore` (rather than the app target) achieves two goals:
/// 1. `RunnerStore` and `LocalRunnerStore` can reference it without importing AppKit or SwiftUI.
/// 2. Test doubles (`MockRunnerViewModel`) can be defined inside `RunnerBarCoreTests` and
///    passed into the actors without any app-target dependency.
///
/// **Direction of data flow:** stores *push* into the receiver; the receiver never pulls.
/// All mutations arrive on `@MainActor` via `await MainActor.run { }`.
@MainActor
public protocol RunnerViewModelProtocol: AnyObject, Sendable {
    // MARK: Pushed by RunnerStore

    /// GitHub API-backed runners for the authenticated user's repos and orgs.
    var runners: [Runner] { get set }
    /// Active jobs across all monitored workflow runs.
    var jobs: [ActiveJob] { get set }
    /// Grouped workflow actions surfaced in the panel popover.
    var actions: [WorkflowActionGroup] { get set }
    /// Whether the GitHub API is currently rate-limited.
    var isRateLimited: Bool { get set }
    /// When the current rate-limit window resets, if known.
    var rateLimitResetDate: Date? { get set }

    // MARK: Pushed by LocalRunnerStore

    /// Locally-installed runner agents discovered on this Mac.
    var localRunners: [RunnerModel] { get set }
    /// `true` while `LocalRunnerStore` is running a refresh cycle.
    var isLocalScanning: Bool { get set }
}
