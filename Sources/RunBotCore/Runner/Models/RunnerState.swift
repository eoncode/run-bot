// RunnerState.swift
// RunBotCore
import Foundation
import Observation

// MARK: - RunnerState

/// Observable model that holds all mutable runner-related state for the app layer.
///
/// **Access level rationale for mutable properties:**
/// The `runners`, `localRunners`, and `isLocalScanning` properties are `public var`
/// because Swift requires the setter to match the accessibility of a `public` protocol
/// `{ get set }` requirement — see `RunnerViewModelProtocol` for the rationale.
/// Only `LocalRunnerStore` (in `RunBotCore`) writes them in practice.
/// `availableUpdate` is `public private(set)` — cross-module mutation is
/// funnelled through `setAvailableUpdate(_:)` so all write sites are visible
/// in code review. It is set by `AutoUpdater.handle()` on every update-available
/// result and cleared by `scheduleBackgroundCheck` on `.upToDate` / `.failed`.
/// The auto-update download properties (`updateZipURL`, `cachedUpdateVersion`,
/// `updateAssetMissing`, `updateActionFailed`) are `public internal(set)` — only
/// `AutoUpdater` (same `RunBotCore` module) writes them via `await MainActor.run`.
/// Views and app-layer code are read-only consumers of all properties.
@Observable
@MainActor
public final class RunnerState {

    // MARK: - Runner list state

    /// The live list of GitHub-hosted runners fetched by `RunnerPoller`.
    ///
    /// `public var` is required by `RunnerViewModelProtocol { get set }` — see
    /// the protocol definition for the full access-level rationale.
    public var runners: [Runner] = []

    /// The list of locally installed self-hosted runners discovered by
    /// `LocalRunnerStore`.
    ///
    /// See `runners` for the access-level rationale.
    public var localRunners: [LocalRunner] = []

    /// `true` while `LocalRunnerStore` is performing an async scan for locally
    /// installed runner services.
    ///
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

    /// Sets `availableUpdate`.
    ///
    /// Called from `AutoUpdater.handle(_:state:)` on every `.updateAvailable` result
    /// (including the launch-time check in `AppDelegate+PanelSetup`) and from
    /// `AutoUpdater.scheduleBackgroundCheck` to clear a stale row on `.upToDate`
    /// or `.failed` results (when no zip is cached).
    ///
    /// Using an explicit method (rather than direct property assignment) keeps
    /// every write site visible in code review and prevents ad-hoc mutation elsewhere.
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

    // MARK: - Init

    /// Public memberwise-style initialiser required so that `RunnerPollerProtocol`
    /// can use `RunnerState()` as a default argument value from another module
    /// (`RunBot` app target). Without an explicit `public init()`, the
    /// `@Observable`-synthesised initialiser is `internal` and the cross-module
    /// default argument fails to compile.
    public init() {}

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
}
