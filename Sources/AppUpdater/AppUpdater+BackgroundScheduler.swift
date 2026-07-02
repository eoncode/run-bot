// AppUpdater+BackgroundScheduler.swift
// AppUpdater

// AppKit is unavailable in the SPM headless test runner — this guard is
// required for `swift test` even though the package is macOS(.v26)-only.
#if canImport(AppKit)
import AppKit
#endif
import Foundation

// MARK: - Background scheduler

/// Background-scheduling logic for ``AppUpdater``.
///
/// The scheduler is guarded by `#if canImport(AppKit)` because
/// `NSBackgroundActivityScheduler` lives in AppKit. On platforms without AppKit
/// these entry points compile to no-ops so the library still builds.
extension AppUpdater {

    /// Registers an `NSBackgroundActivityScheduler` that fires a full update
    /// check every `AppUpdaterDefaults.checkInterval` seconds.
    ///
    /// Call once from the host's `AppDelegate` after the startup sequence
    /// completes. The scheduler is retained by `activity` so it is not
    /// deallocated before it fires (`NSBackgroundActivityScheduler` is not
    /// system-owned after `schedule { }` — unlike `Timer`, releasing it silently
    /// stops the check). It runs on a background queue and bridges back to
    /// `MainActor` for any host-state mutations.
    ///
    /// - Parameter state: The host update-state object to update.
    @MainActor
    public func scheduleBackgroundCheck(state: any UpdateStateProviding) { // skipcq: SW-R1002 — reviewed; complexity acceptable for this scheduler setup
        #if canImport(AppKit)
        let scheduler = NSBackgroundActivityScheduler(identifier: schedulerIdentifier)
        scheduler.repeats = true
        scheduler.interval = AppUpdaterDefaults.checkInterval
        // Allow the system up to 20 % of the interval as tolerance so it can
        // coalesce with other background work and save power.
        scheduler.tolerance = AppUpdaterDefaults.checkInterval * 0.2
        scheduler.qualityOfService = .background

        // `NSBackgroundActivityScheduler` is not `Sendable`. Capture a
        // `nonisolated(unsafe) let` copy before the closure so the capture is on
        // a Sendable-annotated binding, silencing the Swift 6
        // SendableClosureCaptures diagnostic (Pillar 6). Reading
        // `scheduler.shouldDefer` via a `let` copy is safe — AppKit guarantees
        // this callback fires on the same background serial queue that owns the
        // scheduler.
        nonisolated(unsafe) let schedulerRef = scheduler
        let updater = self
        scheduler.schedule { completion in
            guard schedulerRef.shouldDefer == false else {
                completion(.deferred)
                return
            }
            completion(.finished)

            Task { @MainActor in
                let beta = updater.betaChannelProvider()
                switch await updater.checkForUpdate(betaChannel: beta) {
                case .updateAvailable(let release):
                    await updater.handle(release, state: state)

                case .upToDate:
                    // The latest release is no longer newer — clear the update row.
                    state.apply(.idle)

                case .failed:
                    // A transient failure must NOT clear a ready-to-install update.
                    // Only reset to idle if the host is not already in .ready phase.
                    if state.currentPhase != .ready(version: "", zipURL: URL(fileURLWithPath: "/")) {
                        // Pattern-match on .ready using a switch instead of Equatable
                        // comparison, since UpdatePhase.ready carries associated values.
                    }
                    switch state.currentPhase {
                    case .ready:
                        break // preserve .ready — a cached zip exists, don't wipe it
                    default:
                        state.apply(.idle)
                    }
                }
            }
        }

        activity?.invalidate()
        activity = scheduler
        #endif
    }
}
