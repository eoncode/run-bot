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

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Triggers a fresh scan on a background thread. The published `runners`
    /// array is **fully reassigned** on the main thread when done so SwiftUI
    /// always sees a new value and re-renders every observer.
    ///
    /// `@MainActor` enforces the main-thread call-site contract at compile time.
    /// `isScanning = true` is set synchronously before dispatching background
    /// work to close the race window where two rapid calls could both pass the guard.
    ///
    /// ⚠️ REGRESSION GUARD: `isScanning = true` must remain synchronous here.
    @MainActor
    func refresh() {
        log("LocalRunnerStore › refresh() called — isScanning=\(isScanning) runners.count=\(runners.count)")
        guard !isScanning else {
            log("LocalRunnerStore › refresh() SKIPPED — already scanning")
            return
        }
        isScanning = true
        log("LocalRunnerStore › refresh() — isScanning set to true, dispatching background scan")
        queue.async { [weak self] in
            guard let self else {
                log("LocalRunnerStore › refresh() background — self is nil, aborting")
                return
            }
            log("LocalRunnerStore › refresh() background — starting scanner.scan()")
            // Phase 1: local scan — install paths are derived from LaunchAgent
            // plists (WorkingDirectory key), so no UserDefaults persistence needed.
            // This approach survives app reinstalls since plists live in ~/Library.
            var result = self.scanner.scan()
            log("LocalRunnerStore › refresh() background — scanner.scan() returned \(result.count) runner(s): \(result.map { "\($0.runnerName)(isRunning=\($0.isRunning))" })")
            // Phase 4: enrich with live GitHub API status (skipped if no token)
            if githubToken() != nil {
                log("LocalRunnerStore › refresh() background — token present, calling enricher")
                result = self.enricher.enrich(runners: result)
                log("LocalRunnerStore › refresh() background — enricher returned \(result.count) runner(s): \(result.map { "\($0.runnerName)(isRunning=\($0.isRunning),status=\($0.displayStatus))" })")
            } else {
                log("LocalRunnerStore › refresh() background — no token, skipping enricher")
            }
            // CRITICAL: runners must be reassigned (not mutated in-place) so
            // SwiftUI's @Published diffing fires and all observers re-render.
            // Must be on main thread — @MainActor-isolated properties.
            DispatchQueue.main.async {
                log("LocalRunnerStore › refresh() main — assigning \(result.count) runner(s) to self.runners (was \(self.runners.count))")
                self.runners = result  // full reassignment — SwiftUI WILL diff and re-render
                self.isScanning = false
                log("LocalRunnerStore › refresh() main — done. runners.count=\(self.runners.count) isScanning=false")
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
        // Reassign the whole array — this is what makes @Published fire
        log("LocalRunnerStore › optimisticallySetRunning — reassigning runners array to trigger SwiftUI re-render")
        runners = updated
        log("LocalRunnerStore › optimisticallySetRunning — done, runners.count=\(runners.count)")
    }
}
