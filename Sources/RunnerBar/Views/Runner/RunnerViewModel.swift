// RunnerViewModel.swift
// RunnerBar
import Foundation
import Observation

// MARK: - RunnerViewModel

/// Bridges `RunnerStore` and `LocalRunnerStore` into observable properties consumed by SwiftUI views.
///
/// `reload()` is triggered by Combine sinks in `AppDelegate+PanelSetup` — one on
/// `RunnerStore.didUpdate` and one on `LocalRunnerStore.$runners` — so the view model
/// stays in sync whenever either store publishes new data.
/// The entire class is `@MainActor` because all property mutations and reads must happen
/// on the main thread to satisfy SwiftUI's rendering requirements.
@MainActor
@Observable
final class RunnerViewModel {
    /// The app-wide singleton. `RunnerStore` writes into this instance.
    ///
    /// Declared `@MainActor` so the initialiser runs on the main actor, satisfying
    /// Swift 6 strict concurrency. `RunnerStore` captures it by reference; all
    /// mutations go through `await MainActor.run { }`.
    @MainActor static let shared = RunnerViewModel()

    // MARK: - Observable state
    /// GitHub API-backed runners for the authenticated user's repos and orgs.
    var runners: [Runner] = []
    /// Active jobs across all monitored workflow runs.
    var jobs: [ActiveJob] = []
    /// Grouped workflow actions surfaced in the panel popover.
    var actions: [WorkflowActionGroup] = []
    /// Locally-installed runner agents discovered on this Mac.
    var localRunners: [RunnerModel] = []
    /// Whether the GitHub API is currently rate-limited.
    var isRateLimited: Bool = false
    /// When the current rate-limit window resets, if known.
    var rateLimitResetDate: Date?

    // MARK: - Dependency injection (for tests)
    /// Override to inject a test double instead of `LocalRunnerStore.shared`.
    /// `nil` in production — `reload()` falls back to `LocalRunnerStore.shared` when this is `nil`.
    /// Tests **must** set this to avoid leaking into the shared production store.
    /// - Note: Because the class is `@MainActor`, this property must be set from a `@MainActor`
    ///   context in tests (e.g. `@MainActor func testFoo()` or `await MainActor.run { ... }`).
    /// - Note: `RunnerStore` has no equivalent DI seam — `reload()` always reads `RunnerStore.shared`
    ///   directly. Tests that need to stub GitHub API state must use the real singleton or a
    ///   separate integration-test approach.
    var localRunnerStore: LocalRunnerStore?

    // MARK: - Reload

    /// Copies the latest state from `RunnerStore` and `LocalRunnerStore` into the published properties.
    ///
    /// Called by Combine sinks in `AppDelegate+PanelSetup` — one on `RunnerStore.didUpdate`
    /// and one on `LocalRunnerStore.$runners`. Also called eagerly in `AppDelegate.openPanel()`
    /// to seed state on first panel open, since the Combine sinks only fire on store changes,
    /// not on initial subscription.
    ///
    /// IMPORTANT: Do NOT call localStore.refresh() here. reload() is a read-only bridge.
    /// Calling refresh() from here creates an infinite loop:
    ///   LocalRunnerStore.$runners publishes
    ///   → reload() is called (via AppDelegate+PanelSetup sink)
    ///   → refresh() runs and completes
    ///   → sets runners, publishes $runners again
    ///   → reload() is called again, forever.
    /// isScanning only prevents concurrent cycles — not sequential ones.
    /// Callers that need a fresh scan (SettingsView, PanelMainView, lifecycle actions)
    /// call LocalRunnerStore.shared.refresh() directly at their own call sites.
    /// Refreshes `localRunners` from `LocalRunnerStore`.
    ///
    /// `runners`, `jobs`, `actions`, `isRateLimited`, and `rateLimitResetDate` are now
    /// **pushed** directly by `RunnerStore.applyFetchResult` via `MainActor.run { }`
    /// after every poll cycle — they must not be pulled here. Pulling stale values
    /// from the actor would require an `await` (breaking the synchronous SwiftUI path)
    /// and would in any case race against the push that already happened.
    ///
    /// Callers that previously relied on `reload()` to seed RunnerStore state on first
    /// panel open no longer need to do so — `RunnerStore` pushes on every completed cycle.
    func reload() {
        let localStore = localRunnerStore ?? LocalRunnerStore.shared
        log("RunnerViewModel › reload — localRunners=\(localStore.runners.count)")
        localRunners = localStore.runners
    }
}
