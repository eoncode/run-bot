// RunnerState.swift
// RunBotCore
import Foundation
import Observation

// MARK: - RunnerState

/// Observable read model populated by `RunnerPoller` and consumed by the app layer.
///
/// All mutations happen on the `MainActor`. Views and `AppDelegate` observe this
/// object directly via `withObservationTracking` or `ObservationLoop`.
///
/// The six poll-written properties (`runners`, `jobs`, `actions`, `isRateLimited`,
/// `rateLimitResetDate`, `fetchError`) are `public internal(set)` — only
/// `RunnerPoller.applyFetchResult` (same module) should mutate them.
/// Two additional properties (`localRunners`, `isLocalScanning`) are `public var`
/// because Swift requires the setter to match the accessibility of a `public` protocol
/// `{ get set }` requirement — see `RunnerViewModelProtocol` for the rationale.
/// Only `LocalRunnerStore` (in `RunBotCore`) writes them in practice.
/// `availableUpdate` is likewise `public var`: it is written once on launch by
/// `AppDelegate+PanelSetup` (app layer, different module) — `internal(set)` would
/// block that assignment. In practice only the startup Task writes it.
/// The auto-update download properties (`updateZipURL`, `cachedUpdateVersion`,
/// `updateAssetMissing`, `updateActionFailed`) are `public internal(set)` — only
/// `AutoUpdater` (same `RunBotCore` module) writes them via `await MainActor.run`.
/// Views and app-layer code are read-only consumers of all properties.
@Observable
@MainActor
public final class RunnerState {
    /// The current list of GitHub self-hosted runners for all active scopes.
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
    /// The most recent fetch error, or `nil` if the last fetch succeeded.
    ///
    /// Set by `RunnerPoller.applyError(_:)`; cleared on every successful
    /// `applyFetchResult`. Views read this to show a non-modal error banner.
    ///
    /// Typed `(any Error)?` — the stored value is always a `RunnerPoller.FetchError`,
    /// which is `Sendable`. The property stays `any Error` for display flexibility;
    /// `@MainActor` isolation on `RunnerState` ensures safe cross-actor reads.
    public internal(set) var fetchError: (any Error)?

    // MARK: - Local runner state (pushed by LocalRunnerStore)

    /// Locally-installed runner agents discovered on this Mac.
    ///
    /// Pushed by `LocalRunnerStore` via `await MainActor.run { }` after every refresh cycle.
    ///
    /// Declared `public var` (not `public internal(set) var`) because Swift requires the
    /// setter to be at least as accessible as the protocol requirement when conforming to a
    /// public protocol with a `{ get set }` requirement. `public internal(set)` would restrict
    /// the setter to `RunBotCore` and fail to satisfy the requirement at the module interface.
    /// In practice, only `LocalRunnerStore` (inside `RunBotCore`) ever writes this property;
    /// the `public` setter is a type-system necessity, not an invitation for external mutation.
    public var localRunners: [RunnerModel] = []

    /// `true` while `LocalRunnerStore` is running a refresh cycle.
    ///
    /// Pushed by `LocalRunnerStore` alongside `localRunners`.
    /// See `localRunners` for the access-level rationale.
    public var isLocalScanning: Bool = false

    /// The latest available version string if a newer version exists, or `nil` if
    /// up to date.
    ///
    /// **Read-only for all callers.** Write via `setAvailableUpdate(_:)` below.
    ///
    /// **Why `public private(set)` with a dedicated setter method:**
    /// `private(set)` restricts the synthesised setter to `RunnerState` itself — direct
    /// assignment from outside the type (including from the `RunBot` app module) is a
    /// compile error. Cross-module mutation is intentionally funnelled through the
    /// `public func setAvailableUpdate(_:)` method below, which is the single authorised
    /// write site and keeps ad-hoc mutation visible in code review.
    public private(set) var availableUpdate: String?

    /// Sets `availableUpdate`. Called exactly once, from the startup Task in
    /// `AppDelegate+PanelSetup`, after `UpdateChecker.checkForUpdate` resolves.
    ///
    /// Using an explicit method (rather than direct property assignment) makes the
    /// single authorised write site obvious and prevents ad-hoc mutation elsewhere.
    ///
    /// There is intentionally no `@MainActor` on `availableUpdate` itself: the property
    /// is written here (always called from the main actor in `AppDelegate`) and read by
    /// `SettingsView` (also on main actor via SwiftUI). Marking the storage `@MainActor`
    /// would require callers to `await` on a value that is always dispatched from main,
    /// adding noise without benefit. If a background caller is added in future, annotate
    /// then and migrate the write site to `await MainActor.run { ... }`.
    public func setAvailableUpdate(_ version: String?) {
        availableUpdate = version
    }

    // MARK: - Auto-update download state (pushed by AutoUpdater)

    /// Local file URL of the cached `RunBot-update.zip`, or `nil` while the
    /// download is in progress or has not started yet.
    ///
    /// Set by `AutoUpdater.downloadUpdate` after the zip is verified and moved
    /// to the caches directory. Rehydrated from `UserDefaults` on startup if
    /// the cached version is still newer than the installed version.
    ///
    /// The Install & Relaunch button is shown only when this is non-`nil`.
    public internal(set) var updateZipURL: URL?

    /// Version string of the cached update zip (e.g. `"v0.8.0"`), or `nil`
    /// if no download has been cached yet.
    ///
    /// Used by the startup sequence to skip a redundant re-download when the
    /// same version is already cached locally.
    public internal(set) var cachedUpdateVersion: String?

    /// Rehydrates cached download state from `UserDefaults` on startup.
    ///
    /// Called by `AppDelegate+PanelSetup` after verifying that the cached zip
    /// still exists on disk and the cached version is newer than the installed
    /// app. Using an explicit method (rather than direct property assignment)
    /// keeps both write sites inside `RunBotCore` — `updateZipURL` and
    /// `cachedUpdateVersion` are `public internal(set)` and cannot be set
    /// directly from the `RunBot` app target.
    public func rehydrateCachedUpdate(zipURL: URL, version: String) {
        updateZipURL = zipURL
        cachedUpdateVersion = version
    }

    /// `true` when the latest release exists but its `RunBot.zip` asset is
    /// absent (e.g. a draft or a release that predates asset publishing).
    ///
    /// When `true` the UI falls back to a **Download** button that opens the
    /// releases page in the browser instead of triggering an in-app install.
    public internal(set) var updateAssetMissing: Bool = false

    /// `true` when a download **or** an install attempt has failed.
    ///
    /// A single flag covers both failure modes so the UI branch stays simple:
    /// the Download fallback button is shown whenever
    /// `updateAssetMissing || updateActionFailed`.
    ///
    /// Set in `AutoUpdater.downloadUpdate` (download failure) and in
    /// `AutoUpdater.installAndRelaunch` (install failure).
    public internal(set) var updateActionFailed: Bool = false

    /// The overall connectivity state of the runner fleet, derived from `runners`.
    /// Observed by `AppDelegate`'s `statusIconLoop` via `ObservationLoop`.
    public var aggregateStatus: AggregateStatus {
        AggregateStatus(runners: runners)
    }

    /// Creates an empty `RunnerState`.
    public init() {}
}
