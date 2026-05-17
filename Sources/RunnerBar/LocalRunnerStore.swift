import Combine
import Foundation

// MARK: - LocalRunnerStore

/// An `ObservableObject` that drives the Local Runners section of `SettingsView`.
///
/// Wraps `LocalRunnerScanner` and exposes the result as a published array so
/// SwiftUI views automatically re-render when the scan completes or is refreshed.
///
/// **Threading:** scanning is dispatched to a background queue to avoid blocking
/// the main thread. `runners` is always updated on the main queue.
///
/// **Phase 4:** After the local scan, `RunnerStatusEnricher` is called on the
/// same background thread to enrich each runner with live GitHub API status
/// (online/offline/busy). Enrichment is skipped silently when no GitHub token
/// is present, preserving Phase 1 behaviour for unauthenticated users.
///
/// `@unchecked Sendable`: all mutable state is protected by DispatchQueue
/// serialisation (background queue for reads, main queue for writes to
/// `@Published` properties). Safe to cross actor boundaries.
final class LocalRunnerStore: ObservableObject, @unchecked Sendable {
    // MARK: Shared singleton

    static let shared = LocalRunnerStore()

    // MARK: Published state

    /// The list of locally-discovered runners. Empty until the first scan completes.
    @Published private(set) var runners: [RunnerModel] = []

    /// `true` while a background scan is in progress.
    @Published private(set) var isScanning: Bool = false

    // MARK: Private

    private let scanner = LocalRunnerScanner()
    private let enricher = RunnerStatusEnricher.shared
    private let queue = DispatchQueue(
        label: "dev.eonist.runnerbar.localrunnerstore",
        qos: .userInitiated
    )

    /// Set to `true` when `refresh()` is called while a scan is already in
    /// progress. The in-flight scan checks this flag on completion and
    /// immediately kicks off a second scan so the caller's request is never
    /// silently dropped — even if the 30 s polling timer raced us here.
    private var pendingRefresh: Bool = false

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Triggers a fresh scan on a background thread. The published `runners`
    /// array is **fully reassigned** on the main thread when done so SwiftUI
    /// always sees a new value and re-renders every observer.
    ///
    /// If a scan is already running, sets `pendingRefresh = true` so the
    /// in-flight scan will immediately kick off a second scan on completion
    /// rather than silently dropping the request.
    ///
    /// `@MainActor` enforces the main-thread call-site contract at compile time.
    /// `isScanning = true` is set synchronously before dispatching background
    /// work to close the race window where two rapid calls could both pass the guard.
    ///
    /// ⚠️ REGRESSION GUARD: `isScanning = true` must remain synchronous here.
    @MainActor
    func refresh() {
        log("LocalRunnerStore › refresh() called — isScanning=\(isScanning) pendingRefresh=\(pendingRefresh) runners.count=\(runners.count)")
        guard !isScanning else {
            // Don't drop the request — mark it pending so the in-flight scan
            // will re-run immediately when it finishes.
            pendingRefresh = true
            log("LocalRunnerStore › refresh() DEFERRED — scan in progress, pendingRefresh set to true")
            return
        }
        isScanning = true
        pendingRefresh = false
        log("LocalRunnerStore › refresh() — isScanning=true pendingRefresh=false, dispatching background scan")
        _runScan()
    }

    // MARK: - Private scan implementation

    /// Internal: dispatches the actual scan+enrich work. Must only be called
    /// from the main thread with `isScanning` already set to `true`.
    @MainActor
    private func _runScan() {
        log("LocalRunnerStore › _runScan() — dispatching to background queue")
        queue.async { [weak self] in
            guard let self else {
                log("LocalRunnerStore › _runScan() background — self is nil, aborting")
                return
            }
            log("LocalRunnerStore › _runScan() background — starting scanner.scan()")
            var result = self.scanner.scan()
            log("LocalRunnerStore › _runScan() background — scanner returned \(result.count) runner(s): \(result.map { "\($0.runnerName)(isRunning=\($0.isRunning))" })")
            if githubToken() != nil {
                log("LocalRunnerStore › _runScan() background — token present, calling enricher")
                result = self.enricher.enrich(runners: result)
                log("LocalRunnerStore › _runScan() background — enricher returned \(result.count) runner(s): \(result.map { "\($0.runnerName)(isRunning=\($0.isRunning),status=\($0.displayStatus))" })")
            } else {
                log("LocalRunnerStore › _runScan() background — no token, skipping enricher")
            }
            // Hop back to main for all @Published mutations.
            DispatchQueue.main.async {
                log("LocalRunnerStore › _runScan() main — assigning \(result.count) runner(s) (was \(self.runners.count)) pendingRefresh=\(self.pendingRefresh)")
                // CRITICAL: full array reassignment so @Published fires and SwiftUI re-renders.
                self.runners = result
                self.isScanning = false
                log("LocalRunnerStore › _runScan() main — runners updated, isScanning=false")
                // If another refresh() was requested while we were scanning, run it now.
                if self.pendingRefresh {
                    log("LocalRunnerStore › _runScan() main — pendingRefresh=true, starting follow-up scan immediately")
                    self.pendingRefresh = false
                    self.isScanning = true
                    self._runScan()
                } else {
                    log("LocalRunnerStore › _runScan() main — no pending refresh, scan chain complete")
                }
            }
        }
    }

    /// Optimistically flips a single runner's `isRunning` flag on the main thread
    /// WITHOUT waiting for a full rescan. This makes the dot and status label
    /// update instantly when the user taps Resume or Stop.
    ///
    /// A full `refresh()` should still be called after the svc.sh script
    /// finishes so the state is confirmed from launchctl truth.
    @MainActor
    func optimisticallySetRunning(_ runnerName: String, isRunning: Bool) {
        log("LocalRunnerStore › optimisticallySetRunning runnerName=\(runnerName) isRunning=\(isRunning) — current runners=\(runners.map { $0.runnerName })")
        var updated = runners
        var found = false
        for i in updated.indices {
            if updated[i].runnerName == runnerName {
                log("LocalRunnerStore › optimisticallySetRunning — FOUND at index \(i), old isRunning=\(updated[i].isRunning), setting to \(isRunning)")
                updated[i].isRunning = isRunning
                found = true
            }
        }
        if !found {
            log("LocalRunnerStore › optimisticallySetRunning — WARNING: runner '\(runnerName)' NOT FOUND in runners array (count=\(runners.count))")
        }
        // Reassign the whole array — this is what makes @Published fire and SwiftUI re-render.
        log("LocalRunnerStore › optimisticallySetRunning — reassigning runners array to trigger SwiftUI re-render")
        runners = updated
        log("LocalRunnerStore › optimisticallySetRunning — done, runners.count=\(runners.count)")
    }
}
