import Combine
import Foundation

// MARK: - LocalRunnerStore

/// Observable store for locally-installed GitHub Actions runners.
/// Discovered via LocalRunnerScanner, optionally enriched with GitHub API status.
@MainActor
final class LocalRunnerStore: ObservableObject {
    static let shared = LocalRunnerStore()
    private init() {}

    @Published var runners: [RunnerModel] = []
    @Published var isScanning: Bool = false

    private let scanner  = LocalRunnerScanner()
    private let enricher = RunnerStatusEnricher()

    // MARK: - Refresh

    func refresh() {
        log("LocalRunnerStore › refresh() called isScanning=\(isScanning) runners.count=\(runners.count)")
        guard !isScanning else {
            log("LocalRunnerStore › refresh() SKIPPED — already scanning")
            return
        }
        isScanning = true
        log("LocalRunnerStore › refresh() isScanning set to true, dispatching background scan")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            log("LocalRunnerStore › refresh() background starting scanner.scan")
            let scanned = self.scanner.scan()
            let summary = scanned.map { "\($0.runnerName)=isRunning:\($0.isRunning)" }.joined(separator: ", ")
            log("LocalRunnerStore › refresh() background scanner.scan returned \(scanned.count) runners \(summary)")

            let token = githubToken()
            var enriched = scanned
            if token != nil {
                log("LocalRunnerStore › refresh() background token present, calling enricher")
                enriched = self.enricher.enrich(runners: scanned)
                let enrichedSummary = enriched.map { "\($0.runnerName)=isRunning:\($0.isRunning),status:\($0.githubStatus ?? \"nil\")" }.joined(separator: ", ")
                log("LocalRunnerStore › refresh() background enricher returned \(enriched.count) runners \(enrichedSummary)")
            } else {
                log("LocalRunnerStore › refresh() background no token — skipping enricher")
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                log("LocalRunnerStore › refresh() main assigning \(enriched.count) runners to self.runners was \(self.runners.count)")
                self.runners = enriched
                self.isScanning = false
                log("LocalRunnerStore › refresh() main done. runners.count=\(self.runners.count) isScanning=\(self.isScanning)")
            }
        }
    }

    // MARK: - Optimistic mutations

    /// Flips `isRunning` on the named runner immediately and reassigns the
    /// array so `@Published` fires and SwiftUI re-renders without waiting for
    /// the next refresh() cycle.
    func optimisticallySetRunning(_ runnerName: String, isRunning: Bool) {
        log("LocalRunnerStore › optimisticallySetRunning runnerName=\(runnerName) isRunning=\(isRunning) current runners=\(runners.map(\.runnerName).joined(separator: ", "))")
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else {
            log("LocalRunnerStore › optimisticallySetRunning NOT FOUND for \(runnerName)")
            return
        }
        log("LocalRunnerStore › optimisticallySetRunning FOUND at index \(idx), old isRunning=\(runners[idx].isRunning), setting to \(isRunning)")
        runners[idx].isRunning = isRunning
        // Also clear any stale warning when user explicitly tries to flip state
        runners[idx].lifecycleWarning = nil
        log("LocalRunnerStore › optimisticallySetRunning reassigning runners array to trigger SwiftUI re-render")
        runners = runners
        log("LocalRunnerStore › optimisticallySetRunning done, runners.count=\(runners.count)")
    }

    /// Stamps a lifecycle warning onto the named runner so `displayStatus`
    /// surfaces it in the row label immediately.
    func setLifecycleWarning(_ runnerName: String, warning: String?) {
        log("LocalRunnerStore › setLifecycleWarning runnerName=\(runnerName) warning=\(warning ?? \"nil\")")
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else {
            log("LocalRunnerStore › setLifecycleWarning NOT FOUND for \(runnerName)")
            return
        }
        runners[idx].lifecycleWarning = warning
        runners = runners
        log("LocalRunnerStore › setLifecycleWarning done for \(runnerName)")
    }
}
