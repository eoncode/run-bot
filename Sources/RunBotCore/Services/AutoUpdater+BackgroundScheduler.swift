// AutoUpdater+BackgroundScheduler.swift
// RunBotCore
import AppKit
import Foundation

/// Background-scheduling logic for ``AutoUpdater``.
extension AutoUpdater {

    // MARK: - Background scheduler

    /// Retains the `NSBackgroundActivityScheduler` for the lifetime of the app.
    ///
    /// `NSBackgroundActivityScheduler` is **not** retained by the system after
    /// `schedule { }` is called — unlike `Timer`, the caller must hold a strong
    /// reference. Without this property the scheduler is deallocated immediately
    /// after `scheduleBackgroundCheck` returns and the background check silently
    /// never fires.
    ///
    /// `@MainActor` matches `scheduleBackgroundCheck`'s isolation so the
    /// assignment is data-race free under Swift 6 strict concurrency.
    @MainActor static var backgroundScheduler: NSBackgroundActivityScheduler?

    /// Registers an `NSBackgroundActivityScheduler` that fires a full
    /// update check every `AutoUpdaterDefaults.checkInterval` seconds.
    ///
    /// Call once from `AppDelegate` after the startup sequence completes.
    /// The scheduler is stored in `backgroundScheduler` above so it is not
    /// deallocated before it fires; it runs on a background queue and bridges
    /// back to `MainActor` for any `RunnerState` mutations.
    ///
    /// - Parameter state: The shared `RunnerState` instance to update.
    @MainActor
    public static func scheduleBackgroundCheck(state: RunnerState) {
        let scheduler = NSBackgroundActivityScheduler(
            identifier: "io.github.runbot-hq.update-check"
        )
        scheduler.repeats = true
        scheduler.interval = AutoUpdaterDefaults.checkInterval
        // Allow the system up to 20 % of the interval as tolerance so it can
        // coalesce with other background work and save power.
        scheduler.tolerance = AutoUpdaterDefaults.checkInterval * 0.2
        scheduler.qualityOfService = .background

        // `NSBackgroundActivityScheduler` is not `Sendable`. Capture a
        // `nonisolated(unsafe) let` copy before the closure so the capture is
        // on a Sendable-annotated binding, silencing the Swift 6
        // SendableClosureCaptures diagnostic (P17 / Pillar 6,
        // docs/architecture/concurrency-overview.md).
        //
        // `weak` is not used here: `backgroundScheduler` already retains the
        // scheduler for the app's lifetime, so a weak reference would add no
        // safety and would trigger [#WeakMutability] because the binding is
        // never reassigned. Reading `scheduler.shouldDefer` via a `let` copy
        // is safe — AppKit guarantees this callback fires on the same
        // background serial queue that owns the scheduler.
        nonisolated(unsafe) let schedulerRef = scheduler
        scheduler.schedule { completion in
            // Honour the system's power-saving signal. `schedulerRef.shouldDefer`
            // returns true when macOS is asking background tasks to pause (e.g.
            // low battery, high CPU load). Calling `.deferred` tells the scheduler
            // to retry at the next interval rather than proceeding now. This is
            // the documented pattern for NSBackgroundActivityScheduler (see #1794
            // Architecture notes, Pillar 5).
            guard schedulerRef.shouldDefer == false else {
                completion(.deferred)
                return
            }
            // Tell the scheduler this invocation is done *before* spawning the
            // async work. This is required because `NSBackgroundActivityScheduler`
            // mandates that `completion` is called on the same GCD serial queue it
            // dispatched the closure on. Calling it from inside a `Task { }` would
            // invoke it on the Swift concurrency cooperative thread pool instead —
            // an API contract violation that could cause missed intervals or
            // double-fires on future OS releases.
            //
            // This is safe: the scheduler only needs to know when *this scheduler
            // slot* is finished, not when the update check or download completes.
            // The Task below is fully fire-and-forget from the scheduler's
            // perspective — it runs independently of the scheduler's rescheduling
            // cycle.
            completion(.finished)

            // This unstructured `Task` has no actor context (it inherits the
            // GCD background queue's context, not `@MainActor`). The `await`
            // on `AppPreferencesStore.shared.betaChannel` is therefore required
            // and correct: `AppPreferencesStore` is `@MainActor @Observable`,
            // so reading any property from a non-`@MainActor` context requires
            // an actor hop. This is NOT a data race — it is the Swift concurrency
            // system enforcing safe cross-actor access at compile time.
            Task {
                let beta = await AppPreferencesStore.shared.betaChannel
                let result = await UpdateChecker.checkForUpdate(betaChannel: beta)
                await MainActor.run {
                    if case .updateAvailable(let release) = result {
                        state.setAvailableUpdate(release.tagName)
                        Task { await AutoUpdater.handle(release, state: state) }
                    }
                }
            }
        }

        // Retain the scheduler so it is not deallocated before it fires.
        // NSBackgroundActivityScheduler is not system-owned after schedule { };
        // releasing it here would cause the background check to silently stop.
        backgroundScheduler = scheduler
    }
}
