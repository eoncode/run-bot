// AddRunnerSheet+TokenSection.swift
// RunnerBar

import Foundation

// MARK: - Runner download URL

/// Queries the GitHub API for the latest macOS runner release and returns the `.tar.gz` download URL
/// matching the current CPU architecture (`arm64` or `x64`).
///
/// Uses `URLSession.data(for:)` async/await for the API call — no blocking `Data(contentsOf:)`.
/// Architecture detection uses `ProcessRunner.runAsync` — consistent with the rest of the file
/// and avoids `waitUntilExit()` on the cooperative thread pool.
func fetchRunnerDownloadURL() async -> String? {
    let archResult = await ProcessRunner.runAsync(
        executableURL: URL(fileURLWithPath: GitHubURIs.unamePath),
        arguments: ["-m"],
        timeout: 5
    )
    let arch      = archResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
    let assetArch = (arch == "arm64") ? "arm64" : "x64"
    let assetName = "actions-runner-osx-\(assetArch)"
    log("fetchRunnerDownloadURL \u203a arch=\(arch) assetName=\(assetName)")

    guard let url = URL(string: GitHubURIs.apiRunnerLatest) else {
        log("fetchRunnerDownloadURL \u203a invalid URL")
        return nil
    }
    let data: Data
    do {
        let (responseData, _) = try await URLSession.shared.data(from: url)
        data = responseData
    } catch {
        log("fetchRunnerDownloadURL \u203a network error: \(error.localizedDescription)")
        return nil
    }
    // Minimal GitHub release asset payload.
    struct Asset: Decodable {
        // The asset file name.
        let name: String
        // The direct download URL for this asset.
        let browserDownloadUrl: String
        // Maps snake_case API keys to camelCase Swift properties.
        enum CodingKeys: String, CodingKey {
            // The name coding key.
            case name
            // The browserDownloadUrl coding key.
            case browserDownloadUrl = "browser_download_url"
        }
    }
    // Minimal GitHub release payload — only assets are needed.
    struct Release: Decodable {
        // The list of release assets.
        let assets: [Asset]
    }
    guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
        log("fetchRunnerDownloadURL \u203a decode failed")
        return nil
    }
    let match = release.assets.first {
        $0.name.hasPrefix(assetName) && $0.name.hasSuffix(".tar.gz")
    }
    log("fetchRunnerDownloadURL \u203a match=\(match?.name ?? "nil")")
    return match?.browserDownloadUrl
}

extension AddRunnerSheet {

    // MARK: - Scopes loader

    /// Fetches the user's repos and organisations on a background thread.
    ///
    /// Uses a plain `Task` (not `Task.detached`) because `AddRunnerSheet` has no
    /// `@MainActor` annotation at the type level. The `Task { }` inherits the actor
    /// context of the call site (button action / `onAppear`), which is `@MainActor`,
    /// but `fetchUserRepos()` and `fetchUserOrgs()` immediately suspend to the
    /// cooperative pool via their own `await` boundaries — they do not block the
    /// main actor. The explicit `await MainActor.run { \u2026 }` at the end re-confines
    /// the UI state write to the main actor, which is correct and required.
    func loadScopes() {
        isLoadingScopes = true
        Task(priority: .userInitiated) {
            let fetchedRepos = await fetchUserRepos()
            let fetchedOrgs  = await fetchUserOrgs()
            await MainActor.run {
                repos = fetchedRepos
                orgs  = fetchedOrgs
                if let first = fetchedRepos.first { selectedRepo = first }
                if let first = fetchedOrgs.first  { selectedOrg  = first }
                isLoadingScopes = false
            }
        }
    }

    /// Updates `registrationStep` on the main thread.
    @MainActor func setStep(_ msg: String) {
        registrationStep = msg
    }
}
