import Foundation

@MainActor
final class LocalRunnerStore: ObservableObject {
    static let shared = LocalRunnerStore()
    // Singleton — no custom initialisation needed; default property values are sufficient.
    private init() {}

    @Published var runners: [RunnerModel] = []
    @Published var isScanning: Bool = false

    private let scanner = LocalRunnerScanner()
    private let enricher = RunnerStatusEnricher.shared

    // MARK: - Refresh

    /// Triggers a background scan + enrichment pass.
    /// Safe to call from the main thread — all heavy work runs on a global queue.
    func refresh() {
        guard !isScanning else {
            log("LocalRunnerStore > refresh() — already scanning, skipping")
            return
        }
        isScanning = true
        log("LocalRunnerStore > refresh() — starting background scan")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let scanned = self.scanner.scan()
            let summary = scanned.map { "\($0.runnerName)(isRunning=\($0.isRunning))" }.joined(separator: ", ")
            log("LocalRunnerStore > refresh() background — scanner.scan() returned \(scanned.count) runner(s): [\(summary)]")
            let token = githubToken()
            var enriched = scanned
            if token != nil {
                log("LocalRunnerStore > refresh() background — token present, running enricher")
                enriched = self.enricher.enrich(runners: scanned)
                let enrichedSummary = enriched.map {
                    "\($0.runnerName)(status=\(String(describing: $0.status)) isBusy=\($0.isBusy))"
                }.joined(separator: ", ")
                log("LocalRunnerStore > refresh() background — enricher returned: [\(enrichedSummary)]")
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
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                log("LocalRunnerStore > refresh() main — assigning \(enriched.count) runner(s) to self.runners (was \(self.runners.count))")
                self.runners = enriched
                self.isScanning = false
                log("LocalRunnerStore > refresh() main — done")
            }
        }
    }

    // MARK: - Optimistic mutations

    func optimisticallyRemove(_ runnerName: String) {
        log("LocalRunnerStore > optimisticallyRemove — runnerName=\(runnerName) runners.count was \(runners.count)")
        runners.removeAll { $0.runnerName == runnerName }
        log("LocalRunnerStore > optimisticallyRemove — done, runners.count=\(runners.count)")
    }

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
