import Foundation
import SwiftUI

// MARK: - RunnerModel

/// Represents a locally-installed GitHub Actions self-hosted runner.
/// Discovered by scanning LaunchAgent plists in ~/Library/LaunchAgents.
struct RunnerModel: Identifiable, Equatable {
    // MARK: Stored

    /// String-based ID so LocalRunnerScanner can use runnerName as the dedup key.
    let id: String
    let runnerName: String
    let installPath: String?
    let gitHubUrl: String?
    let agentId: Int?
    let workFolder: String?
    let labels: [String]

    /// Launchctl / process running state. `var` so optimistic UI updates and
    /// the Source-3 live-service check can both mutate it in-place on the array.
    var isRunning: Bool

    /// GitHub API-reported status. `var` — set by RunnerStatusEnricher.
    var githubStatus: String?   // "online" | "offline" | "busy" | nil

    /// GitHub API busy flag. `var` — set by RunnerStatusEnricher.
    var isBusy: Bool

    // MARK: - Init

    init(
        id: String? = nil,
        runnerName: String,
        gitHubUrl: String?,
        agentId: Int?,
        workFolder: String?,
        installPath: String?,
        isRunning: Bool,
        labels: [String] = [],
        githubStatus: String? = nil,
        isBusy: Bool = false
    ) {
        self.id = id ?? runnerName
        self.runnerName = runnerName
        self.gitHubUrl = gitHubUrl
        self.agentId = agentId
        self.workFolder = workFolder
        self.installPath = installPath
        self.isRunning = isRunning
        self.labels = labels
        self.githubStatus = githubStatus
        self.isBusy = isBusy
    }

    // MARK: - Derived display

    /// Human-readable status label shown in the settings runner row.
    var displayStatus: String {
        if isRunning {
            if isBusy || githubStatus == "busy" { return "running" }
            return "running"
        } else {
            switch githubStatus {
            case "online": return "online"
            case "busy":   return "busy"
            default:       return "offline"
            }
        }
    }

    enum StatusColor { case running, busy, idle, offline }

    /// Dot color category used by `SettingsView.localRunnerDotColor(for:)`.
    var statusColor: StatusColor {
        if isRunning {
            if isBusy || githubStatus == "busy" { return .busy }
            return .running
        } else {
            if githubStatus == "online" || githubStatus == "busy" { return .idle }
            return .offline
        }
    }
}
