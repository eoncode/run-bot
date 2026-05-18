import Foundation
import Combine

// MARK: - LocalRunnerStore

@MainActor
final class LocalRunnerStore: ObservableObject {
    static let shared = LocalRunnerStore()
    private init() {}

    @Published var runners: [RunnerModel] = []
    @Published var isScanning: Bool = false

    private let scanner  = LocalRunnerScanner()
    private let enricher = RunnerStatusEnricher.shared

    // MARK: - Refresh

    func refresh() {
        log("LocalRunnerStore > refresh() called \u{2014} isScanning=\(isScanning) runners.count=\(runners.count)")
        guard !isScanning else {
            log("LocalRunnerStore > refresh() SKIPPED \u{2014} already scanning")
            return
        }
        isScanning = true
        log("LocalRunnerStore > refresh() \u{2014} isScanning set to true, dispatching background scan")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            log("LocalRunnerStore > refresh() background \u{2014} starting scanner.scan()")
            let scanned = self.scanner.scan()
            let summary = scanned.map { "\($0.runnerName)(isRunning=\($0.isRunning))" }.joined(separator: ", ")
            log("LocalRunnerStore > refresh() background \u{2014} scanner.scan() returned \(scanned.count) runner(s): [\(summary)]")

            let token = githubToken()
            var enriched = scanned
            if token != nil {
                log("LocalRunnerStore > refresh() background \u{2014} token present, calling enricher")
                enriched = self.enricher.enrich(runners: scanned)
                let enrichedSummary = enriched.map { r -> String in
                    let st = r.githubStatus ?? "nil"
                    let w = r.lifecycleWarning ?? "none"
                    return "\(r.runnerName)(isRunning=\(r.isRunning),status=\(st),warning=\(w))"
                }.joined(separator: ", ")
                log("LocalRunnerStore > refresh() background \u{2014} enricher returned \(enriched.count) runner(s): [\(enrichedSummary)]")
            } else {
                log("LocalRunnerStore > refresh() background \u{2014} no token, skipping enricher")
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                log("LocalRunnerStore > refresh() main \u{2014} assigning \(enriched.count) runner(s) to self.runners (was \(self.runners.count))")
                self.runners = enriched
                self.isScanning = false
                log("LocalRunnerStore > refresh() main \u{2014} done. runners.count=\(self.runners.count) isScanning=\(self.isScanning)")
            }
        }
    }

    // MARK: - Optimistic mutations

    func optimisticallySetRunning(_ runnerName: String, isRunning: Bool) {
        let names = runners.map { $0.runnerName }.joined(separator: ", ")
        log("LocalRunnerStore > optimisticallySetRunning runnerName=\(runnerName) isRunning=\(isRunning) \u{2014} current runners=[\(names)]")
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else {
            log("LocalRunnerStore > optimisticallySetRunning \u{2014} NOT FOUND for \(runnerName)")
            return
        }
        log("LocalRunnerStore > optimisticallySetRunning \u{2014} FOUND at index \(idx), old isRunning=\(runners[idx].isRunning), setting to \(isRunning)")
        runners[idx].isRunning = isRunning
        runners[idx].lifecycleWarning = nil
        log("LocalRunnerStore > optimisticallySetRunning \u{2014} cleared lifecycleWarning for \(runnerName)")
        runners = runners
        log("LocalRunnerStore > optimisticallySetRunning \u{2014} done, runners.count=\(runners.count)")
    }

    func setLifecycleWarning(_ runnerName: String, warning: String?) {
        let w = warning ?? "nil"
        log("LocalRunnerStore > setLifecycleWarning called: runnerName=\(runnerName) warning=\(w)")
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else {
            log("LocalRunnerStore > setLifecycleWarning \u{2014} NOT FOUND for \(runnerName)")
            return
        }
        log("LocalRunnerStore > setLifecycleWarning \u{2014} FOUND at index \(idx), setting warning=\(w) on runner \(runnerName)")
        runners[idx].lifecycleWarning = warning
        runners = runners
        let displayStatus = runners[idx].displayStatus
        log("LocalRunnerStore > setLifecycleWarning \u{2014} done for \(runnerName), displayStatus is now: \(displayStatus)")
    }
}
