// RunnerPoller+FetchAndEnrich.swift
// RunnerBarCore

// swiftlint:disable:next missing_docs
extension RunnerPoller {

    // MARK: - fetchAndEnrichRunners

    /// Fetches runners for the given scopes, resolves install paths, and enriches with metrics.
    ///
    /// `internal` — `fetch()` is the public entry point; this method is an implementation
    /// detail not intended for direct external calls.
    ///
    /// **Phase 0** derives extra org scopes from local runners whose `gitHubUrl` points to a
    /// single-path-component URL (org-only, not repo). This handles runners registered against
    /// an org that the user hasn't explicitly added as a scope in ScopeStore — their org is
    /// inferred from the local runner's URL so those runners continue to appear in the panel.
    ///
    /// **Phase 1** fans out concurrent scope fetches via `withTaskGroup`. Task completion order
    /// is non-deterministic; views sort runners for display independently.
    ///
    /// **Phase 2** enriches each busy runner with system metrics concurrently.
    ///
    /// **Install-path lookup priority** (matches the original `RunnerStore`):
    /// `byApiId ?? byAgentId ?? byFullKey ?? byName`
    /// `byFullKey` ("scope/name" composite) ranks above `byName` so runners sharing
    /// a name across different scopes resolve to the correct install path.
    ///
    /// - Parameters:
    ///   - scopes: The active scopes to fetch runners for.
    ///   - localRunners: The current local-runner snapshot (used for org-scope derivation).
    ///   - installPathMap: Pre-built lookup maps from `buildInstallPathMap`.
    func fetchAndEnrichRunners(
        scopes: [String],
        localRunners: [RunnerModel],
        installPathMap: InstallPathMap
    ) async -> [Runner] {
        log("RunnerPoller › fetchAndEnrichRunners ENTER — scopes=\(scopes)", category: .runner)

        // MARK: Phase 0 — Extra org-scope derivation from local runner URLs
        // Delegates to `scopeFromUrl(_:)` in GitHubURLHelpers (F-52).
        // Only org-scoped URLs produce a scope string without a "/"; repo-scoped
        // URLs ("owner/repo") are filtered out by the `!contains("/")` guard below.
        let configuredScopeSet = Set(scopes)
        var extraOrgScopes: [String] = []
        for localRunner in localRunners {
            guard let url = localRunner.gitHubUrl,
                  let derivedScope = scopeFromUrl(url),
                  !derivedScope.contains("/") else { continue }
            let orgScope = derivedScope
            guard !configuredScopeSet.contains(orgScope),
                  !extraOrgScopes.contains(orgScope)
            else { continue }
            extraOrgScopes.append(orgScope)
            log("RunnerPoller › fetchAndEnrichRunners — derived extra org scope '\(orgScope)' from local runner '\(localRunner.runnerName)'", category: .runner)
        }
        if !extraOrgScopes.isEmpty {
            log("RunnerPoller › fetchAndEnrichRunners — extra org scopes to fetch: \(extraOrgScopes)", category: .runner)
        }

        let allScopes = scopes + extraOrgScopes

        // MARK: Phase 1 — Fetch raw runners for all scopes concurrently
        var indexed: [IndexedScopedRunner] = []
        await withTaskGroup(of: (String, [Runner]).self) { group in
            for scope in allScopes {
                group.addTask {
                    let fetched = await fetchRunners(for: scope, decoder: self.decoder)
                    return (scope, fetched)
                }
            }
            for await (scope, fetched) in group {
                indexed.append(contentsOf: fetched.map { IndexedScopedRunner(scope: scope, runner: $0) })
            }
        }

        // MARK: Phase 2 — Enrich each busy runner with system metrics concurrently
        // Lookup priority: byApiId ?? byAgentId ?? byFullKey ?? byName
        let busyIndices = indexed.indices.filter { indexed[$0].runner.busy }
        if !busyIndices.isEmpty {
            let metricsResults: [(Int, RunnerMetrics?)] = await withTaskGroup(
                of: (Int, RunnerMetrics?).self
            ) { group in
                for i in busyIndices {
                    let runner = indexed[i].runner
                    let scope = indexed[i].scope
                    let installPath = installPathMap.byApiId[runner.id]
                        ?? installPathMap.byAgentId[runner.id]
                        ?? installPathMap.byFullKey["\(scope)/\(runner.name)"]
                        ?? installPathMap.byName[runner.name]
                    guard let path = installPath else {
                        log("RunnerPoller › fetchAndEnrichRunners — no installPath for \(runner.name) id=\(runner.id) scope=\(scope)", category: .runner)
                        continue
                    }
                    group.addTask {
                        let metrics = await metricsForRunner(installPath: path)
                        return (i, metrics)
                    }
                }
                var results: [(Int, RunnerMetrics?)] = []
                for await pair in group { results.append(pair) }
                return results
            }
            for (i, metrics) in metricsResults {
                indexed[i].runner = indexed[i].runner.copying(metrics: metrics)
            }
        }

        let metricsUpdates = indexed.filter { $0.runner.busy && $0.runner.metrics != nil }
        if !metricsUpdates.isEmpty {
            for entry in metricsUpdates {
#if DEBUG
                // swiftlint:disable:next line_length
                log("RunnerPoller › fetchAndEnrichRunners — applyMetrics: \(entry.runner.name) id=\(entry.runner.id) busy=\(entry.runner.busy) metrics=\(String(describing: entry.runner.metrics))", category: .runner)
#endif
                await applyMetrics(entry.runner.metrics, entry.runner.id, entry.runner.name)
            }
        }

        let result = indexed.map(\.runner)
        log("RunnerPoller › fetchAndEnrichRunners EXIT — returning \(result.count) runner(s)", category: .runner)
        return result
    }
}
