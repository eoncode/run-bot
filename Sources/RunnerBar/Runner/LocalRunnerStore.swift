// LocalRunnerStore.swift
// RunnerBar
import Combine
import Foundation

// MARK: - LocalRunnerStore

/// Owns the list of locally-installed GitHub Actions runner agents.
/// Hydrates from `installPath/.runner` JSON, marks live services via launchctl,
/// then enriches with GitHub API data (status, busy, labels, group).
/// A single refresh cycle runs at a time; `isScanning` reflects in-flight state
/// to views and prevents concurrent refreshes.
@MainActor
final class LocalRunnerStore: ObservableObject {
    // MARK: - Shared singleton
    /// The app-wide singleton. Always accessed on the main actor.
    static let shared = LocalRunnerStore()

    // MARK: - Published state
    /// The current list of locally-installed runners, sorted by name.
    @Published private(set) var runners: [RunnerModel] = []
    /// `true` while a refresh cycle is in flight; prevents concurrent refreshes.
    @Published private(set) var isScanning: Bool = false

    // MARK: - Index persistence
    /// The UserDefaults key used to persist the local runner name → install path index.
    private static let indexKey = "localRunnerIndex"
    /// Maps runnerName → installPath, persisted to UserDefaults.
    private var runnerIndex: [String: String] = [:]

    // MARK: - Init
    /// Initialises the store and loads the persisted runner index from UserDefaults.
    private init() {
        loadIndex()
    }

    // MARK: - Index helpers

    /// Adds or updates the index entry for `name`, mapping it to `installPath`, then persists.
    func register(name: String, installPath: String) {
        runnerIndex[name] = installPath
        persistIndex()
        log("LocalRunnerStore › register — '\(name)' at \(installPath)")
    }

    // MARK: - Convenience API (called by views)

    /// Returns `true` if `runnerName` has an entry in the persisted index.
    func isTracked(runnerName: String) -> Bool {
        runnerIndex[runnerName] != nil
    }

    /// Registers a new runner by name and install path.
    /// Convenience alias for `register(name:installPath:)` with view-friendly parameter labels
    /// so SwiftUI call sites read `store.add(runnerName: x, installPath: y)` naturally.
    func add(runnerName: String, installPath: String) {
        register(name: runnerName, installPath: installPath)
    }

    /// Immediately reflects a start/stop action in the UI before the next refresh cycle.
    /// Already runs on the main actor via @MainActor class isolation.
    func optimisticallySetRunning(_ runnerName: String, isRunning: Bool) {
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else { return }
        runners[idx] = runners[idx].copying(isRunning: isRunning)
    }

    /// Sets or clears the lifecycle warning badge for a runner (e.g. "Failed to connect").
    /// Already runs on the main actor via @MainActor class isolation.
    func setLifecycleWarning(_ runnerName: String, warning: String?) {
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else { return }
        runners[idx] = runners[idx].copying(lifecycleWarning: warning)
    }

    /// Immediately removes `runnerName` from the index and display list without waiting for a refresh.
    /// Already runs on the main actor via @MainActor class isolation.
    func optimisticallyRemove(_ runnerName: String) {
        unregister(name: runnerName)
        runners.removeAll { $0.runnerName == runnerName }
    }

    /// Rolls back an `optimisticallyRemove` by re-registering the runner and restoring it
    /// to the published list. Call this when the underlying removal operation fails.
    /// Already runs on the main actor via @MainActor class isolation.
    ///
    /// - Note: If `runner.installPath` is nil the index entry cannot be restored; the runner
    ///   is still appended to `runners` for immediate UI consistency, but the subsequent
    ///   `refresh()` call in `performRemoval` will drop it again (index is the source of truth).
    ///   In practice every runner that reaches the removal flow has an installPath — this
    ///   guard is a defensive fallback, not an expected code path.
    func optimisticallyRestore(_ runner: RunnerModel) {
        if let installPath = runner.installPath {
            register(name: runner.runnerName, installPath: installPath)
        } else {
            // Cannot restore index entry without installPath — the runner will disappear
            // from the UI again once the subsequent refresh() rebuilds from the index.
            log("LocalRunnerStore › optimisticallyRestore: no installPath for '\(runner.runnerName)' — index entry not restored")
        }
        if !runners.contains(where: { $0.runnerName == runner.runnerName }) {
            runners.append(runner)
        }
    }

    /// Removes `name` from the persisted index and writes through to `UserDefaults`.
    func unregister(name: String) {
        runnerIndex.removeValue(forKey: name)
        persistIndex()
        log("LocalRunnerStore › unregister — '\(name)'")
    }

    /// Hydrates `runnerIndex` from `UserDefaults` at init time.
    private func loadIndex() {
        runnerIndex = UserDefaults.standard
            .dictionary(forKey: Self.indexKey) as? [String: String] ?? [:]
        log("LocalRunnerStore › loadIndex — \(runnerIndex.count) entry(ies): \(runnerIndex.keys.sorted())")
    }

    /// Writes the current `runnerIndex` to `UserDefaults`.
    private func persistIndex() {
        UserDefaults.standard.set(runnerIndex, forKey: Self.indexKey)
    }

    // MARK: - Metrics write-back

    /// Applies a CPU/memory snapshot to the matching `RunnerModel` in place.
    ///
    /// Called by `RunnerStore.fetchAndEnrichRunners` after each poll cycle so the
    /// metrics fetched for busy `Runner` objects are reflected in the `RunnerModel`
    /// list that the main-view runner row reads from.
    ///
    /// Matches by `agentId` first (stable across renames), then falls back to `runnerName`.
    /// No-op when no matching runner is found.
    /// Does NOT trigger a full `refresh()` — it is a lightweight in-place `copying(metrics:)`.
    func applyMetrics(_ metrics: RunnerMetrics?, forAgentId agentId: Int?, name: String) {
        log("LocalRunnerStore › applyMetrics — name=\(name) agentId=\(String(describing: agentId)) metrics=\(String(describing: metrics)) runners.count=\(runners.count)")
        guard let idx = runners.firstIndex(where: { runner in
            if let aid = agentId, let rid = runner.agentId { return aid == rid }
            return runner.runnerName == name
        }) else {
            log("LocalRunnerStore › applyMetrics — ⚠️ NO MATCH for name=\(name) agentId=\(String(describing: agentId)) in runners=\(runners.map { "\($0.runnerName)(id=\(String(describing: $0.agentId)))" })")
            return
        }
        let before = runners[idx].metrics
        runners[idx] = runners[idx].copying(metrics: metrics)
        log("LocalRunnerStore › applyMetrics — matched '\(runners[idx].runnerName)' at idx=\(idx) metrics: \(String(describing: before)) → \(String(describing: metrics))")
    }

    // MARK: - Refresh

    /// Hydrates runners from disk, marks live launchctl services, then enriches via GitHub API.
    ///
    /// Called by `RunnerViewModel.reload()`, which is triggered by Combine sinks in
    /// `AppDelegate+PanelSetup` (on `RunnerStore.didUpdate` and `LocalRunnerStore.$runners`).
    /// `LocalRunnerStore` is `@MainActor`-isolated, so the `Task { }` launched here
    /// inherits that isolation. Each `await` releases the main actor during network/disk
    /// work; the continuation returns to `@MainActor` automatically.
    /// `isScanning` guards against concurrent refresh cycles — a new call is a no-op while one
    /// is already in flight.
    func refresh() {
        log("LocalRunnerStore › refresh() called — isScanning=\(isScanning) indexCount=\(runnerIndex.count) runnerIndexKeys=\(runnerIndex.keys.sorted())")
        guard !isScanning else {
            log("LocalRunnerStore › refresh() — SKIPPED (already scanning)")
            return
        }
        isScanning = true
        let index = runnerIndex
        Task { [weak self] in
            guard let self else { return }

            // 1. Hydrate from installPath/.runner JSON
            var hydrated: [RunnerModel] = index.compactMap { runnerModelFromIndex(name: $0.key, installPath: $0.value) }
            log("LocalRunnerStore › refresh() background — hydrated \(hydrated.count) runner(s) from \(index.count) index entries")

            // 2. Mark live services via launchctl.
            // scanLiveServices() is always called here — isRunning is intentionally set to false
            // during JSON parsing (step 1) and updated to its real value only at this point.
            // Do not remove this call or assume isRunning is always false.
            let liveLabels = await self.scanLiveServices()
            log("LocalRunnerStore › refresh() — launchctl liveLabels=\(liveLabels)")
            let isLive: (RunnerModel) -> Bool = { runner in
                liveLabels.contains { $0.contains(runner.runnerName) }
            }
            hydrated = hydrated.map { runner in
                let live = isLive(runner)
                log("LocalRunnerStore › refresh() — '\(runner.runnerName)' isRunning=\(live)")
                return runner.copying(isRunning: live)
            }

            // 3. Enrich via GitHub API (concurrent scope fetches)
            log("LocalRunnerStore › refresh() — enriching \(hydrated.count) runner(s) via GitHub API")
            let enriched = await RunnerStatusEnricher.shared.enrich(runners: hydrated)
            log("LocalRunnerStore › refresh() — enrichment done, \(enriched.count) runner(s) returned")

            self.applyRefreshResults(enriched)
        }
    }

    /// Applies enriched runner data back on the main actor and clears the scanning flag.
    ///
    /// ## Metrics preservation
    /// `RunnerStore.applyMetrics` writes CPU/memory back into `self.runners` after every
    /// poll cycle. If `applyRefreshResults` overwrites `runners` unconditionally those
    /// metrics are silently discarded, causing the badge to blank out on the next refresh.
    ///
    /// Fix: snapshot the metrics from the current `runners` list (keyed by agentId and name)
    /// BEFORE overwriting, then re-apply them to any runner in the incoming enriched list
    /// whose metrics field is still nil (i.e. it is not currently busy and RunnerStore did
    /// not write fresh metrics for it this cycle — carry forward the last known value).
    @MainActor
    private func applyRefreshResults(_ enriched: [RunnerModel]) {
        // Snapshot current metrics before overwriting.
        var metricsByAgentId: [Int: RunnerMetrics] = [:]
        var metricsByName: [String: RunnerMetrics] = [:]
        for runner in runners {
            guard let m = runner.metrics else { continue }
            if let aid = runner.agentId { metricsByAgentId[aid] = m }
            metricsByName[runner.runnerName] = m
        }
        log("LocalRunnerStore › applyRefreshResults — preserving metrics snapshot: agentIds=\(metricsByAgentId.keys.sorted()) names=\(metricsByName.keys.sorted())")

        // Restore metrics for any runner whose enriched copy has nil metrics.
        let restored = enriched.map { runner -> RunnerModel in
            guard runner.metrics == nil else {
                log("LocalRunnerStore › applyRefreshResults — '\(runner.runnerName)' already has metrics, skipping restore")
                return runner
            }
            if let aid = runner.agentId, let m = metricsByAgentId[aid] {
                log("LocalRunnerStore › applyRefreshResults — '\(runner.runnerName)' metrics restored via agentId=\(aid)")
                return runner.copying(metrics: m)
            }
            if let m = metricsByName[runner.runnerName] {
                log("LocalRunnerStore › applyRefreshResults — '\(runner.runnerName)' metrics restored via name")
                return runner.copying(metrics: m)
            }
            log("LocalRunnerStore › applyRefreshResults — '\(runner.runnerName)' no prior metrics to restore")
            return runner
        }
        let restoredCount = zip(enriched, restored).filter { $0.metrics == nil && $1.metrics != nil }.count
        log("LocalRunnerStore › applyRefreshResults — restored metrics for \(restoredCount)/\(enriched.count) runner(s)")

        runners = restored.sorted { $0.runnerName < $1.runnerName }
        isScanning = false
        log("LocalRunnerStore › applyRefreshResults — done. runners.count=\(runners.count) names=\(runners.map(\.runnerName))")
    }

    // MARK: - launchctl scan

    /// Fixed path to the `launchctl` binary used to query live LaunchAgent services.
    nonisolated private static let launchctlURL = URL(fileURLWithPath: "/bin/launchctl") // NOSONAR — fixed OS path

    /// Runs `launchctl list` and returns lines containing `actions.runner`.
    ///
    /// Called inside `refresh()` (step 2), immediately after disk hydration.
    /// Each returned line is matched against `runnerName` to set `RunnerModel.isRunning`.
    ///
    /// - Note: `isRunning` is **not** set during JSON parsing in `runnerModelFromIndex` — it is
    ///   always initialised to `false` there and updated here via launchctl. Do not assume
    ///   `isRunning` is dead or always-false — the wiring is refresh() → scanLiveServices() → isRunning.
    ///
    /// Uses `ProcessRunner.runAsync` so the cooperative thread pool is not
    /// blocked while `launchctl` runs. If the enclosing `Task` is cancelled
    /// (e.g. because `start()` was called again), `launchctl` is terminated
    /// immediately via the cancellation handler wired inside `runAsync`.
    private nonisolated func scanLiveServices() async -> [String] {
        let result = await ProcessRunner.runAsync(
            executableURL: Self.launchctlURL,
            arguments: ["list"],
            timeout: 5
        )
        guard let data = result.data,
              let output = String(data: data, encoding: .utf8) else {
            log("LocalRunnerStore › scanLiveServices — ⚠️ launchctl returned no data or failed to decode")
            return []
        }
        let lines = output.components(separatedBy: "\n").filter { $0.contains("actions.runner") }
        log("LocalRunnerStore › scanLiveServices — found \(lines.count) live runner service(s)")
        return lines
    }
}

// MARK: - .runner JSON parser

/// Reads `installPath/.runner` JSON and builds a RunnerModel.
/// Returns nil if the file is missing — runner may have been uninstalled outside the app.
///
/// The GitHub Actions runner agent writes .runner files with a UTF-8 BOM (0xEF 0xBB 0xBF).
/// Swift's JSONDecoder does not strip BOMs and silently returns nil for the entire decode.
/// We strip the BOM from the raw Data before passing it to the decoder.
///
/// The agent also writes "gitHubUrl" in camelCase; the CodingKey must match exactly
/// since JSONDecoder is case-sensitive.
private func runnerModelFromIndex(name: String, installPath: String) -> RunnerModel? {
    let jsonURL = URL(fileURLWithPath: installPath).appendingPathComponent(".runner")
    guard var data = try? Data(contentsOf: jsonURL) else {
        log("LocalRunnerStore › runnerModelFromIndex — no .runner at \(installPath), skipping \(name)")
        return nil
    }

    // Strip UTF-8 BOM (0xEF 0xBB 0xBF) — runner agent writes BOM-prefixed JSON on all platforms.
    let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    if data.prefix(3).elementsEqual(bom) {
        data = data.dropFirst(3)
        log("LocalRunnerStore › runnerModelFromIndex — stripped UTF-8 BOM from \(name)")
    }
    struct RunnerJSON: Decodable {
        let gitHubUrl: String?
        let agentId: Int?
        let workFolder: String?
        let platform: String?
        let platformArchitecture: String?
        let agentVersion: String?
        let ephemeral: Bool?
        enum CodingKeys: String, CodingKey {
            case gitHubUrl            = "gitHubUrl"           // camelCase — matches runner agent output
            case agentId              = "AgentId"
            case workFolder           = "WorkFolder"
            case platform             = "Platform"
            case platformArchitecture = "PlatformArchitecture"
            case agentVersion         = "AgentVersion"
            case ephemeral            = "Ephemeral"
        }
    }
    let json = try? JSONDecoder().decode(RunnerJSON.self, from: data)
    if json == nil {
        log("LocalRunnerStore › runnerModelFromIndex — ⚠️ JSON decode failed for \(name) at \(installPath)")
    } else {
        log("LocalRunnerStore › runnerModelFromIndex — parsed \(name): agentId=\(String(describing: json?.agentId)) gitHubUrl=\(String(describing: json?.gitHubUrl)) ephemeral=\(String(describing: json?.ephemeral))")
    }
    return RunnerModel(
        runnerName: name,
        gitHubUrl: json?.gitHubUrl,
        agentId: json?.agentId,
        workFolder: json?.workFolder,
        installPath: installPath,
        isRunning: false,
        platform: json?.platform,
        platformArchitecture: json?.platformArchitecture,
        agentVersion: json?.agentVersion,
        isEphemeral: json?.ephemeral ?? false
    )
}
