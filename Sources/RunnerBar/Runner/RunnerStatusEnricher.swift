// swiftlint:disable type_body_length function_parameter_count
import Foundation

// MARK: - RunnerStatusEnricher

final class RunnerStatusEnricher {
    static let shared = RunnerStatusEnricher()
    private init() {}

    func enrich(runners: [RunnerModel]) -> [RunnerModel] {
        var result = runners
        for idx in result.indices {
            let runner = result[idx]
            guard let url = runner.gitHubUrl else { continue }
            if let enriched = fetchStatus(for: runner, url: url) {
                result[idx] = enriched
            }
        }
        return result
    }

    private func fetchStatus(for runner: RunnerModel, url: String) -> RunnerModel? {
        // Determine scope type and fetch runner status from GitHub API.
        let parts = url
            .replacingOccurrences(of: "https://github.com/", with: "")
            .split(separator: "/")
            .map(String.init)
        guard !parts.isEmpty else { return nil }

        if parts.count >= 2 {
            // repo scope
            return fetchRepoRunnerStatus(runner: runner, owner: parts[0], repo: parts[1])
        } else {
            // org scope
            return fetchOrgRunnerStatus(runner: runner, org: parts[0])
        }
    }

    private func fetchRepoRunnerStatus(
        runner: RunnerModel,
        owner: String,
        repo: String
    ) -> RunnerModel? {
        guard let token = githubToken() else { return nil }
        let urlString = "https://api.github.com/repos/\(owner)/\(repo)/actions/runners"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return performRunnerLookup(runner: runner, request: request)
    }

    private func fetchOrgRunnerStatus(
        runner: RunnerModel,
        org: String
    ) -> RunnerModel? {
        guard let token = githubToken() else { return nil }
        let urlString = "https://api.github.com/orgs/\(org)/actions/runners"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return performRunnerLookup(runner: runner, request: request)
    }

    private func performRunnerLookup(runner: RunnerModel, request: URLRequest) -> RunnerModel? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: RunnerModel?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let apiRunners = json["runners"] as? [[String: Any]] else { return }
            for apiRunner in apiRunners {
                guard let name = apiRunner["name"] as? String,
                      name == runner.runnerName else { continue }
                let status = apiRunner["status"] as? String
                let busy = apiRunner["busy"] as? Bool ?? false
                let groupName = (apiRunner["runner_group_name"] as? String)
                let labelNames = (apiRunner["labels"] as? [[String: Any]])?
                    .compactMap { $0["name"] as? String } ?? []
                var updated = runner
                updated.githubStatus = status
                updated.isBusy = busy
                updated.runnerGroup = groupName
                if !labelNames.isEmpty {
                    updated = RunnerModel(
                        id: runner.id,
                        runnerName: runner.runnerName,
                        gitHubUrl: runner.gitHubUrl,
                        agentId: runner.agentId,
                        workFolder: runner.workFolder,
                        installPath: runner.installPath,
                        isRunning: runner.isRunning,
                        labels: labelNames,
                        githubStatus: status,
                        isBusy: busy,
                        lifecycleWarning: runner.lifecycleWarning,
                        platform: runner.platform,
                        platformArchitecture: runner.platformArchitecture,
                        agentVersion: runner.agentVersion,
                        isEphemeral: runner.isEphemeral,
                        runnerGroup: groupName,
                        metrics: runner.metrics
                    )
                }
                result = updated
                break
            }
        }.resume()
        semaphore.wait()
        return result
    }
}
// swiftlint:enable type_body_length function_parameter_count
