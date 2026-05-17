import Foundation
import SwiftUI

// MARK: - RunnerModel

/// Represents a locally-installed GitHub Actions self-hosted runner.
/// Discovered by scanning LaunchAgent plists in ~/Library/LaunchAgents.
struct RunnerModel: Identifiable, Equatable {
    // MARK: Stored
    let id: UUID
    let runnerName: String
    let installPath: String?
    let gitHubUrl: String?
    /// Launchctl / process running state. Mutated by optimistic UI updates and
    /// confirmed on the next full refresh() scan.
    var isRunning: Bool
    /// GitHub API-reported status. Set by RunnerStatusEnricher.
    var githubStatus: String?   // "online" | "offline" | "busy" | nil

    // MARK: - Init
    init(
        id: UUID = UUID(),
        runnerName: String,
        installPath: String?,
        gitHubUrl: String?,
        isRunning: Bool,
        githubStatus: String? = nil
    ) {
        self.id = id
        self.runnerName = runnerName
        self.installPath = installPath
        self.gitHubUrl = gitHubUrl
        self.isRunning = isRunning
        self.githubStatus = githubStatus
    }

    // MARK: - Derived display

    /// Human-readable status label shown in the settings runner row.
    var displayStatus: String {
        if isRunning {
            switch githubStatus {
            case "busy":   return "running"
            case "online": return "online"
            default:       return "running"
            }
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
            if githubStatus == "busy" { return .busy }
            return .running
        } else {
            if githubStatus == "online" || githubStatus == "busy" { return .idle }
            return .offline
        }
    }
}
