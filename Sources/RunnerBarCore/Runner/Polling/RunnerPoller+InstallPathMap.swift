// RunnerPoller+InstallPathMap.swift
// RunnerBarCore
import Foundation

// MARK: - InstallPathMap

/// Lookup maps built from the local runner list, used by `fetchAndEnrichRunners`.
public struct InstallPathMap {
    public let byFullKey: [String: String]
    public let byName: [String: String]
    public let byAgentId: [Int: String]
    public let byApiId: [Int: String]

    public init(
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
        log("RunnerPoller › ⚠️ buildInstallPathMap — fullKey map is EMPTY despite localRunners=\(localRunners.count). Scopes=\(scopes). Check scope string format alignment with localRunner names.", category: .runner)
    }
    if localRunners.isEmpty {
        log("RunnerPoller › ⚠️ buildInstallPathMap — localRunners is EMPTY. All maps are empty. Busy runners will have no installPath this cycle.", category: .runner)
    }
    return InstallPathMap(byFullKey: byFullKey, byName: byName, byAgentId: byAgentId, byApiId: byApiId)
}
