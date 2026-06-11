// SaveRunnerEditsUseCase.swift
// RunnerBar
// Phase 5 of the Swift 6.2 data model modernisation (#1287, #1300).
import Foundation
import RunnerBarCore

// MARK: - RunnerLabelsService

/// Abstraction over the `patchRunnerLabels` network call.
///
/// Inject a test double in unit tests; use `DefaultRunnerLabelsService` in production.
/// Returns the updated label names on success, `nil` on any failure — matching
/// the underlying `patchRunnerLabels` free function signature.
protocol RunnerLabelsService: Sendable {
    /// Replaces ALL custom labels on the runner identified by `runnerID` within `scope`.
    /// - Returns: The updated label names on success, `nil` on any API failure.
    func patch(scope: String, runnerID: Int, labels: [String]) async -> [String]?
}

// MARK: - DefaultRunnerLabelsService

/// Live conformance that delegates directly to `patchRunnerLabels`.
///
/// Used in production; inject a stub in unit tests instead.
struct DefaultRunnerLabelsService: RunnerLabelsService {
    /// Calls the `patchRunnerLabels` free function from `GitHubURLSessionTransport`.
    func patch(scope: String, runnerID: Int, labels: [String]) async -> [String]? {
        await patchRunnerLabels(scope: scope, runnerID: runnerID, labels: labels)
    }
}

// MARK: - SaveRunnerEditsUseCase

/// Testable, dependency-injected replacement for the `commitRunnerEdit` free function.
///
/// Executes the three-step commit transaction:
/// 1. **Labels** (GitHub API) — aborts the entire commit on API failure.
///    If `agentId` or `gitHubUrl` are unavailable, appends an error and
///    continues to local writes (same behaviour as the old free function).
/// 2. **Runner JSON** — writes `workFolder` + `disableUpdate` via `configStore`.
/// 3. **Proxy files** — writes `.proxy` + `.proxycredentials` via `proxyStore`.
///
/// JSON and proxy errors are accumulated; labels abort early.
///
/// Dependencies are injected at the call site — no singletons are accessed inside
/// `execute(...)`. Use `RunnerConfigStore.shared`, `RunnerProxyStore.shared`,
/// and `DefaultRunnerLabelsService()` for production.
///
/// - Note: Part of Phase 5 of the Swift 6.2 data model modernisation (#1287, #1300).
struct SaveRunnerEditsUseCase: Sendable {

    // MARK: Dependencies

    /// Store for reading and writing the `.runner` JSON config file.
    let configStore: RunnerConfigStore
    /// Store for reading and writing `.proxy` / `.proxycredentials` files.
    let proxyStore: RunnerProxyStore
    /// Service for updating runner labels via the GitHub API.
    let labelsService: any RunnerLabelsService

    // MARK: - execute

    /// Persists all changed fields in `draft` for `runner` as a single transaction.
    ///
    /// - Returns: `.success` when all writes succeed;
    ///   `.failure([String])` with human-readable messages otherwise.
    func execute(
        runner: RunnerModel,
        draft: RunnerEditDraft,
        original: RunnerEditDraft
    ) async -> CommitResult {
        var errors: [String] = []

        // MARK: Step 1 — Labels (GitHub API)
        let labelsChanged = draft.parsedLabels != original.parsedLabels
        if labelsChanged {
            if let agentId = runner.agentId,
               let gitHubUrl = runner.gitHubUrl,
               let scope = scopeFromHtmlUrl(gitHubUrl) {
                log("SaveRunnerEditsUseCase › patching labels runner=\(runner.runnerName) labels=\(draft.parsedLabels)")
                let result = await labelsService.patch(scope: scope, runnerID: agentId, labels: draft.parsedLabels)
                if result == nil {
                    log("SaveRunnerEditsUseCase › labels API failed, aborting")
                    return .failure(["Failed to save labels via GitHub API"])
                }
                log("SaveRunnerEditsUseCase › labels patched ok")
            } else {
                let msg = "Cannot save labels: missing agent ID or GitHub URL"
                log("SaveRunnerEditsUseCase › \(msg)")
                errors.append(msg)
            }
        }

        // MARK: Step 2 — Runner JSON (workFolder + disableUpdate)
        let workFolderChanged = draft.trimmedWorkFolder != original.trimmedWorkFolder
        let autoUpdateChanged = draft.autoUpdate != original.autoUpdate
        if workFolderChanged || autoUpdateChanged {
            guard let installPath = runner.installPath else {
                errors.append("Install path unknown — cannot write runner JSON")
                return errors.isEmpty ? .success : .failure(errors)
            }
            log("SaveRunnerEditsUseCase › saving .runner config installPath=\(installPath)")
            do {
                var config = try await configStore.load(at: installPath)
                config.workFolder = draft.trimmedWorkFolder
                config.disableUpdate = !draft.autoUpdate
                try await configStore.save(config, at: installPath)
                log("SaveRunnerEditsUseCase › .runner config updated ok")
            } catch {
                errors.append("Failed to write runner configuration (.runner JSON)")
                log("SaveRunnerEditsUseCase › .runner config write failed: \(error)")
            }
        }

        // MARK: Step 3 — Proxy files
        let proxyChanged = draft.proxyUrl != original.proxyUrl
            || draft.proxyUser != original.proxyUser
            || draft.proxyPassword != original.proxyPassword
        if proxyChanged {
            guard let installPath = runner.installPath else {
                errors.append("Install path unknown — cannot write proxy files")
                return errors.isEmpty ? .success : .failure(errors)
            }
            log("SaveRunnerEditsUseCase › writing proxy files installPath=\(installPath)")
            let proxyConfig = RunnerProxyConfig(
                url: draft.proxyUrl,
                user: draft.proxyUser,
                password: draft.proxyPassword
            )
            do {
                try await proxyStore.save(proxyConfig, at: installPath)
                log("SaveRunnerEditsUseCase › proxy files updated ok")
            } catch {
                errors.append("Failed to save proxy settings")
                log("SaveRunnerEditsUseCase › proxy write failed: \(error)")
            }
        }

        return errors.isEmpty ? .success : .failure(errors)
    }
}
