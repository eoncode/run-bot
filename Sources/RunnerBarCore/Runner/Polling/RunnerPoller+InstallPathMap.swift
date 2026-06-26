// RunnerPoller+InstallPathMap.swift
// RunnerBarCore
import Foundation

// MARK: - InstallPathMap

/// Lookup maps built from the local runner list, used by `fetchAndEnrichRunners`.
///
/// `public` so the app target can reference the type (e.g. in tests and in
/// `AppDelegate+StoreSetup` for DI wiring). `buildInstallPathMap` is `internal`
/// — it is only called from within `RunnerBarCore`.
public struct InstallPathMap {
<<<<<<< Updated upstream:Sources/RunnerBarCore/Runner/Polling/RunnerPoller+InstallPathMap.swift
/// `public` so the app target can reference the type (e.g. in tests and in
/// `AppDelegate+StoreSetup` for DI wiring). `buildInstallPathMap` is `internal`
/// — it is only called from within `RunnerBarCore`.
public struct InstallPathMap {
=======
/// Migration note (step 10): now `internal` — no app-layer callers exist.
/// TODO: fold into `extension RunnerPoller` once the dual-write bridge is removed.
struct InstallPathMap {
>>>>>>> Stashed changes:Sources/RunnerBarCore/Runner/RunnerPoller+InstallPathMap.swift
    /// Maps "scope/runnerName" to installPath (exact scope-prefixed match).
    let byFullKey: [String: String]
    /// Maps "runnerName" to installPath (name-only fallback).
    let byName: [String: String]
    /// Maps local `.runner` JSON `AgentId` to installPath (scope-agnostic).
    ///
    /// Keyed on `localRunner.agentId`, **not** the GitHub REST API runner id.
    /// Use `byApiId` when resolving API runner ids (they differ for org runners).
    let byAgentId: [Int: String]
    /// Maps apiId to installPath using the GitHub REST API runner id from the last enrichment cycle.
    ///
    /// For org runners the GitHub API assigns an `id` that differs from the local
    /// `.runner` JSON `AgentId`. This map is keyed on the API id so that metrics
    /// can be resolved for org runners even when `byAgentId` misses.
    let byApiId: [Int: String]

    /// Creates an `InstallPathMap` with pre-built lookup dictionaries.
    ///
    /// - Parameters:
    ///   - byFullKey: Maps "scope/runnerName" to installPath.
    ///   - byName: Maps runnerName to installPath (name-only fallback).
    ///   - byAgentId: Maps local `.runner` JSON AgentId to installPath.
    ///   - byApiId: Maps GitHub REST API runner id to installPath.
    init(
        byFullKey: [String: String],
        byName: [String: String],
        byAgentId: [Int: String],
        byApiId: [Int: String]
    ) {
        self.byFullKey = byFullKey
        self.byName = byName
        self.byAgentId = byAgentId
        self.byApiId = byApiId
    }
}

/// Builds four lookup maps from the local runner list.
///
<<<<<<< Updated upstream:Sources/RunnerBarCore/Runner/Polling/RunnerPoller+InstallPathMap.swift
/// `internal` — called only by `RunnerPoller.fetch()` inside `RunnerBarCore`.
/// Kept as a top-level free function (rather than `extension RunnerPoller`) so
/// it can be tested without an actor instance.
=======
/// Builds four lookup maps from the local runner list.
///
/// `internal` — only called by `RunnerPoller.fetch()`. TODO: move into
/// `extension RunnerPoller` once the dual-write bridge is removed (step 10).
>>>>>>> Stashed changes:Sources/RunnerBarCore/Runner/RunnerPoller+InstallPathMap.swift
func buildInstallPathMap(
    scopes: [String],
    localRunners: [RunnerModel]
) -> InstallPathMap {
    var byFullKey: [String: String] = [:]
    var byName: [String: String] = [:]
    var byAgentId: [Int: String] = [:]
    var byApiId: [Int: String] = [:]
    for localRunner in localRunners {
        guard let path = localRunner.installPath else {
            log("RunnerPoller › buildInstallPathMap — SKIP \(localRunner.runnerName): installPath is nil", category: .runner)
            continue
        }
        byName[localRunner.runnerName] = path
        if let agentId = localRunner.agentId {
            byAgentId[agentId] = path
        } else {
            log("RunnerPoller › buildInstallPathMap — \(localRunner.runnerName): agentId is nil (will rely on apiId/fullKey/name fallback)", category: .runner)
        }
        if let apiId = localRunner.apiId {
            byApiId[apiId] = path
        }
        for scope in scopes {
            byFullKey["\(scope)/\(localRunner.runnerName)"] = path
        }
    }
    // swiftlint:disable:next line_length
    log("RunnerPoller › buildInstallPathMap — localRunners=\(localRunners.count) scopes=\(scopes) → fullKeys=\(byFullKey.keys.sorted()) nameKeys=\(byName.keys.sorted()) agentIdKeys=\(byAgentId.keys.sorted()) apiIdKeys=\(byApiId.keys.sorted())", category: .runner)
    if byFullKey.isEmpty && !localRunners.isEmpty {
        // swiftlint:disable:next line_length
        log("RunnerPoller › ⚠️ buildInstallPathMap — fullKey map is EMPTY despite localRunners=\(localRunners.count). Scopes=\(scopes). Check scope string format alignment with localRunner names.", category: .runner)
    }
    if localRunners.isEmpty {
        log("RunnerPoller › ⚠️ buildInstallPathMap — localRunners is EMPTY. All maps are empty. Busy runners will have no installPath this cycle.", category: .runner)
    }
    return InstallPathMap(byFullKey: byFullKey, byName: byName, byAgentId: byAgentId, byApiId: byApiId)
}
