import Foundation

// MARK: - FailureHookRunner
// #544: Fires the per-scope failure hook command when an ActionGroup transitions to failure.
// #546: Resolves $LOCAL_PATH from ScopeSettingsStore.
//
// Called from RunnerStoreState.buildGroupState when a group is newly completed
// with a failure conclusion. Resolves all $TOKEN variables then shells out fire-and-forget.
//
// TOKEN RESOLUTION CONTRACT:
// ALL tokens are resolved in Swift before the command string is passed to
// /bin/zsh -c. There must be NO shell variables or $() subshells left in the
// command by the time it reaches the shell — special characters in log content,
// branch names, etc. would break shell parsing.
//
// $FAILURE_LOG inlines the log content directly, single-quote-escaped:
//   gemini -p '$FAILURE_LOG' --model=gemini-2.5-flash --approval-mode=yolo

enum FailureHookRunner {

    /// Call this whenever a group transitions to done with a failure conclusion.
    static func fireIfNeeded(group: ActionGroup, scope: String) {
        guard ScopeSettingsStore.failureHookEnabled(for: scope) else { return }
        guard let command = ScopeSettingsStore.failureHookCommand(for: scope),
              !command.isEmpty else {
            log("FailureHookRunner › hook enabled for \(scope) but no command set — skipping")
            return
        }
        guard isFailure(group: group) else { return }

        let resolved = resolveTokens(command, group: group, scope: scope)
        log("FailureHookRunner › firing hook for scope=\(scope) runID=\(group.id) command=\(resolved.prefix(200))")

        DispatchQueue.global(qos: .utility).async {
            Shell.run(resolved, timeout: 300)
        }
    }

    // MARK: - Private

    private static func isFailure(group: ActionGroup) -> Bool {
        let failureConclusions: Set<String> = ["failure", "timed_out", "cancelled", "startup_failure"]
        return group.runs.contains { run in
            guard let conclusion = run.conclusion else { return false }
            return failureConclusions.contains(conclusion.lowercased())
        }
    }

    /// Escapes a string so it is safe to embed between single-quotes in a shell command.
    /// The only character that cannot appear inside single-quotes is a single-quote itself;
    /// we escape it by ending the quoted segment, inserting an escaped quote, then
    /// reopening: '\'' — the surrounding single-quotes are supplied by the user's template.
    private static func singleQuoteEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    private static func buildLogContent(group: ActionGroup, scope: String) -> String {
        var lines: [String] = [
            "RunnerBar Failure Hook",
            "Scope:    \(scope)",
            "Branch:   \(group.headBranch ?? "unknown")",
            "SHA:      \(group.headSha)",
            "Workflow: \(group.title)",
            "---"
        ]
        for run in group.runs {
            if let conclusion = run.conclusion,
               ["failure", "timed_out", "cancelled", "startup_failure"].contains(conclusion.lowercased()) {
                lines.append("FAILED run \(run.id): conclusion=\(conclusion) workflow=\(run.name)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func resolveTokens(_ command: String, group: ActionGroup, scope: String) -> String {
        let localPath   = ScopeSettingsStore.localRepoPath(for: scope) ?? ""
        let branch      = group.headBranch ?? ""
        let sha         = group.headSha
        let workflow    = group.title
        let baseURL     = "https://github.com/\(scope)"
        let branchURL   = "\(baseURL)/tree/\(branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch)"
        let commitURL   = "\(baseURL)/commit/\(sha)"
        let failedRunID = group.runs.first(where: {
            guard let c = $0.conclusion else { return false }
            return ["failure", "timed_out", "cancelled", "startup_failure"].contains(c.lowercased())
        }).map { String($0.id) } ?? group.id
        let runURL      = "\(baseURL)/actions/runs/\(failedRunID)"

        // Build log content in Swift and escape for safe single-quote embedding.
        let logContent  = singleQuoteEscape(buildLogContent(group: group, scope: scope))

        return command
            .replacingOccurrences(of: "$LOCAL_PATH",    with: localPath)
            .replacingOccurrences(of: "$SCOPE",         with: scope)
            .replacingOccurrences(of: "$BRANCH",        with: branch)
            .replacingOccurrences(of: "$RUN_ID",        with: "\(failedRunID)")
            .replacingOccurrences(of: "$COMMIT_SHA",    with: sha)
            .replacingOccurrences(of: "$WORKFLOW_NAME", with: workflow)
            .replacingOccurrences(of: "$FAILURE_LOG",   with: logContent)
            .replacingOccurrences(of: "$RUN_LINK",      with: runURL)
            .replacingOccurrences(of: "$COMMIT_LINK",   with: commitURL)
            .replacingOccurrences(of: "$BRANCH_LINK",   with: branchURL)
            .replacingOccurrences(of: "$REPO_LINK",     with: baseURL)
    }
}
