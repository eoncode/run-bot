// FailureHookRunner.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - FailureHookRunner

/// Production shim for `FailureHookRunnerUseCase`.
///
/// Creates the use-case with the concrete production adapters and delegates
/// `fireIfNeeded` to it. All business logic lives in `FailureHookRunnerUseCase`;
/// this type exists only to maintain the existing call-site API.
enum FailureHookRunner {

    /// Default command forwarded from `FailureHookRunnerUseCase.defaultCommand`.
    static let defaultCommand = FailureHookRunnerUseCase.defaultCommand

    /// Forwards to `FailureHookRunnerUseCase` wired with production dependencies.
    static func fireIfNeeded(
        group: WorkflowActionGroup,
        scope: String,
        callsite: String = "unknown"
    ) async {
        let useCase = FailureHookRunnerUseCase(
            preferencesStore: DefaultScopePreferencesStore(),
            terminalLauncher: DefaultTerminalLauncher(),
            jobFetcher: { grp, scp in
                await Self.fetchFailedJobs(group: grp, scope: scp)
            }
        )
        await useCase.fireIfNeeded(group: group, scope: scope, callsite: callsite)
    }

    // MARK: - Network implementation (lives in RunnerBar where ghAPI/LogFetcher are defined)

    /// Fetches the failed jobs (and their log tails) for every failure-triggering run in `group`.
    private static func fetchFailedJobs(
        group: WorkflowActionGroup,
        scope: String
    ) async -> [FailureHookRunnerUseCase.FailedJobResult] {
        var result: [FailureHookRunnerUseCase.FailedJobResult] = []
        var seenIDs = Set<Int>()
        for run in group.runs {
            guard run.conclusion?.isHookConclusion == true else { continue }
            guard let data = await ghAPI("repos/\(scope)/actions/runs/\(run.id)/jobs?per_page=\(GitHubConstants.maxPageSize)") else { continue }
            guard let resp = try? JSONDecoder().decode(JobsResponse.self, from: data) else { continue }
            for job in resp.jobs where seenIDs.insert(job.id).inserted {
                guard let jobConclusion = job.conclusion, jobConclusion.isHookConclusion else { continue }
                let tail: String?
                if let fullLog = await LogFetcher().fetchJobLog(jobID: job.id, scope: scope) {
                    let lines = fullLog.components(separatedBy: "\n")
                    tail = lines.suffix(150).joined(separator: "\n")
                } else {
                    tail = nil
                }
                result.append(FailureHookRunnerUseCase.FailedJobResult(job: job, logTail: tail))
            }
        }
        return result
    }
}
