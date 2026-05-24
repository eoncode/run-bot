// LocalRunnerStore.swift
// RunnerBar
import Combine
import Foundation
import RunnerBarCore

// MARK: - LocalRunnerStore

/// Main-actor observable store for locally installed GitHub Actions runners.
/// Discovers runners via `LocalRunnerScanner`, optionally enriches them with
/// GitHub API status via `RunnerStatusEnricher`, and attaches per-runner
/// CPU/MEM metrics for busy runners.
/// Use the `shared` singleton from the main thread only.
@MainActor
final class LocalRunnerStore: ObservableObject {
    /// The process-wide singleton. All access must be on the main actor.
    static let shared = LocalRunnerStore()
    /// Private initialiser — use `shared`.
    private init() {
        // Singleton — no custom initialisation needed; default property values are sufficient.
    }

    /// The current list of discovered (and optionally enriched) local runners.
    @Published var runners: [RunnerModel] = []
    /// True while a background scan is in progress; prevents overlapping scans.
    @Published var isScanning: Bool = false

    /// Responsible for enumerating `.runner` install directories on disk.
    private let scanner = LocalRunnerScanner()
    /// Enriches scanned runners with GitHub API-reported status and lifecycle warnings.
    private let enricher = RunnerStatusEnricher.shared

    // MARK: - Refresh

    /// Initiates a background scan of local runner directories, optionally enriching
    /// results with GitHub API status when a token is available.
    /// No-ops if a scan is already in progress (`isScanning == true`).
    func refresh() {
        log("LocalRunnerStore > refresh() called — isScanning=\(isScanning) runners.count=\(runners.count)")
        guard !isScanning else {
            log("LocalRunnerStore > refresh() SKIPPED — already scanning")
            return
        }
        isScanning = true
        log("LocalRunnerStore > refresh() — isScanning set to true, dispatching background scan")
        // Capture enricher before entering the Sendable background closure so the
        // compiler does not see a main-actor-isolated property reference inside async.
        let enricher = self.enricher
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            log("LocalRunnerStore > refresh() background — starting scanner.scan()")
            let scanned = self.scanner.scan()
            let summary = scanned.map { "\($0.runnerName)(isRunning=\($0.isRunning))" }.joined(separator: ", ")
            log("LocalRunnerStore > refresh() background — scanner.scan() returned \(scanned.count) runner(s): [\(summary)]")

            let token = githubToken()
            var enriched = scanned
            if token != nil {
                log("LocalRunnerStore > refresh() background — token present, calling enricher")
                enriched = enricher.enrich(runners: scanned)
                let enrichedSummary = enriched.map { r -> String in
                    let st = r.githubStatus ?? "nil"
                    let w = r.lifecycleWarning ?? "none"
                    return "\(r.runnerName)(isRunning=\(r.isRunning),status=\(st),warning=\(w))"
                }.joined(separator: ", ")
                log("LocalRunnerStore > refresh() background — enricher returned \(enriched.count) runner(s): [\(enrichedSummary)]")
            } else {
                log("LocalRunnerStore > refresh() background — no token, skipping enricher")
            }

            // Phase 3 (#591): enrich each busy runner with per-runner CPU/MEM metrics.
            // Matched by installPath so each runner gets its own process metrics, not slot-index.
            for idx in enriched.indices {
                guard enriched[idx].isBusy, let installPath = enriched[idx].installPath else { continue }
                enriched[idx].metrics = metricsForRunner(installPath: installPath)
                log("LocalRunnerStore > refresh() background — metrics for \(enriched[idx].runnerName): \(String(describing: enriched[idx].metrics))")
            }

            DispatchQueue.main.async { [weak self, enriched] in
                guard let self else { return }
                log("LocalRunnerStore > refresh() main — assigning \(enriched.count) runner(s) to self.runners (was \(self.runners.count))")
                self.runners = enriched
                self.isScanning = false
                log("LocalRunnerStore > refresh() main — done. runners.count=\(self.runners.count) isScanning=\(self.isScanning)")
            }
        }
    }

    // MARK: - Optimistic mutations

    /// Immediately removes the runner with the given name from `runners` without waiting
    /// for the next `refresh()` cycle. Used after a successful uninstall to update the UI instantly.
    func optimisticallyRemove(_ runnerName: String) {
        log("LocalRunnerStore > optimisticallyRemove — runnerName=\(runnerName) runners.count was \(runners.count)")
        runners.removeAll { $0.runnerName == runnerName }
        log("LocalRunnerStore > optimisticallyRemove — done, runners.count=\(runners.count)")
    }

    /// Immediately updates the `isRunning` flag for the named runner and clears any
    /// `lifecycleWarning` without waiting for the next `refresh()` cycle.
    /// Used after a start/stop action to reflect the new state in the UI instantly.
    func optimisticallySetRunning(_ runnerName: String, isRunning: Bool) {
        let names = runners.map { $0.runnerName }.joined(separator: ", ")
        log("LocalRunnerStore > optimisticallySetRunning runnerName=\(runnerName) isRunning=\(isRunning) — current runners=[\(names)]")
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else {
            log("LocalRunnerStore > optimisticallySetRunning — NOT FOUND for \(runnerName)")
            return
        }
        log("LocalRunnerStore > optimisticallySetRunning — FOUND at index \(idx), old isRunning=\(runners[idx].isRunning), setting to \(isRunning)")
        runners[idx].isRunning = isRunning
        runners[idx].lifecycleWarning = nil
        log("LocalRunnerStore > optimisticallySetRunning — cleared lifecycleWarning for \(runnerName)")
        objectWillChange.send()
        log("LocalRunnerStore > optimisticallySetRunning — done, runners.count=\(runners.count)")
    }

    /// Sets or clears a `lifecycleWarning` string on the named runner and triggers
    /// an `objectWillChange` notification so the UI refreshes immediately.
    /// Pass `nil` to clear an existing warning.
    func setLifecycleWarning(_ runnerName: String, warning: String?) {
        let w = warning ?? "nil"
        log("LocalRunnerStore > setLifecycleWarning called: runnerName=\(runnerName) warning=\(w)")
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else {
            log("LocalRunnerStore > setLifecycleWarning — NOT FOUND for \(runnerName)")
            return
        }
        log("LocalRunnerStore > setLifecycleWarning — FOUND at index \(idx), setting warning=\(w) on runner \(runnerName)")
        runners[idx].lifecycleWarning = warning
        objectWillChange.send()
        let displayStatus = runners[idx].displayStatus
        log("LocalRunnerStore > setLifecycleWarning — done for \(runnerName), displayStatus is now: \(displayStatus)")
    }
}
