// SaveRunnerEditsUseCaseTests.swift
// RunnerBarTests
// Unit tests for SaveRunnerEditsUseCase — Phase 5 (#1300).
import Foundation
import RunnerBarCore
import Testing

// MARK: - Test doubles

/// Spy conformance for `RunnerLabelsService`.
/// Records calls and returns a configurable result.
final class SpyLabelsService: RunnerLabelsService, @unchecked Sendable {
    var result: [String]? = []
    private(set) var callCount = 0
    private(set) var lastScope: String?
    private(set) var lastRunnerID: Int?
    private(set) var lastLabels: [String]?

    func patch(scope: String, runnerID: Int, labels: [String]) async -> [String]? {
        callCount += 1
        lastScope = scope
        lastRunnerID = runnerID
        lastLabels = labels
        return result
    }
}

/// Spy conformance for `RunnerConfigStore`.
/// Records save calls; `load` returns a configurable `RunnerConfig`.
final class SpyConfigStore: RunnerConfigStoreProtocol, @unchecked Sendable {
    var loadResult: RunnerConfig = RunnerConfig(workFolder: "_work", disableUpdate: false)
    var shouldThrowOnSave = false
    private(set) var saveCalled = false
    private(set) var savedConfig: RunnerConfig?

    func load(at installPath: String) async throws -> RunnerConfig {
        loadResult
    }
    func save(_ config: RunnerConfig, at installPath: String) async throws {
        if shouldThrowOnSave { throw TestError.saveFailed }
        saveCalled = true
        savedConfig = config
    }
}

/// Spy conformance for `RunnerProxyStore`.
/// Records save calls; `load` returns an empty config.
final class SpyProxyStore: RunnerProxyStoreProtocol, @unchecked Sendable {
    var shouldThrowOnSave = false
    private(set) var saveCalled = false
    private(set) var savedConfig: RunnerProxyConfig?

    func load(at installPath: String) async -> RunnerProxyConfig { RunnerProxyConfig() }
    func save(_ config: RunnerProxyConfig, at installPath: String) async throws {
        if shouldThrowOnSave { throw TestError.saveFailed }
        saveCalled = true
        savedConfig = config
    }
}

enum TestError: Error { case saveFailed }

// MARK: - Helpers

/// Minimal `RunnerModel` stub for use in tests.
/// Adjust fields as needed for each scenario.
private func makeRunner(
    runnerName: String = "test-runner",
    agentId: Int? = 42,
    gitHubUrl: String? = "https://github.com/owner/repo",
    installPath: String? = "/tmp/runner"
) -> RunnerModel {
    RunnerModel(
        runnerName: runnerName,
        agentId: agentId,
        gitHubUrl: gitHubUrl,
        installPath: installPath
    )
}

/// Returns a zeroed `RunnerEditDraft` (no labels, default workFolder, autoUpdate=true, empty proxy).
private func makeDraft(runner: RunnerModel) -> RunnerEditDraft {
    RunnerEditDraft(runner: runner)
}

// MARK: - Tests

@Suite("SaveRunnerEditsUseCase")
struct SaveRunnerEditsUseCaseTests {

    // MARK: All-success path

    @Test("returns .success when no fields changed")
    func noChanges() async {
        let runner = makeRunner()
        let draft = makeDraft(runner: runner)
        let original = makeDraft(runner: runner)
        let labels = SpyLabelsService()
        let config = SpyConfigStore()
        let proxy  = SpyProxyStore()
        let useCase = SaveRunnerEditsUseCase(configStore: config, proxyStore: proxy, labelsService: labels)

        let result = await useCase.execute(runner: runner, draft: draft, original: original)

        #expect(result == .success)
        #expect(labels.callCount == 0)
        #expect(!config.saveCalled)
        #expect(!proxy.saveCalled)
    }

    // MARK: Labels abort path

    @Test("aborts entire commit when labels API returns nil")
    func labelsAPIFailureAborts() async {
        let runner = makeRunner()
        var draft    = makeDraft(runner: runner)
        let original = makeDraft(runner: runner)
        draft.labelsText = "ci, fast"

        let labels = SpyLabelsService()
        labels.result = nil  // simulate API failure
        let config = SpyConfigStore()
        let proxy  = SpyProxyStore()
        let useCase = SaveRunnerEditsUseCase(configStore: config, proxyStore: proxy, labelsService: labels)

        let result = await useCase.execute(runner: runner, draft: draft, original: original)

        guard case .failure(let msgs) = result else {
            Issue.record("expected .failure, got .success")
            return
        }
        #expect(msgs.count == 1)
        #expect(msgs[0].contains("GitHub API"))
        // JSON and proxy must NOT have been called after labels abort
        #expect(!config.saveCalled)
        #expect(!proxy.saveCalled)
    }

    // MARK: JSON-fail-continues path

    @Test("accumulates JSON error but continues to proxy step")
    func jsonWriteFailureContinues() async {
        let runner = makeRunner()
        var draft    = makeDraft(runner: runner)
        let original = makeDraft(runner: runner)
        // Change workFolder to trigger JSON write
        draft.workFolder = "custom_work"
        // Change proxy URL to trigger proxy write
        draft.proxyUrl = "http://proxy.example.com"

        let labels = SpyLabelsService()
        let config = SpyConfigStore()
        config.shouldThrowOnSave = true  // make JSON step fail
        let proxy = SpyProxyStore()
        let useCase = SaveRunnerEditsUseCase(configStore: config, proxyStore: proxy, labelsService: labels)

        let result = await useCase.execute(runner: runner, draft: draft, original: original)

        guard case .failure(let msgs) = result else {
            Issue.record("expected .failure, got .success")
            return
        }
        // JSON error accumulated
        #expect(msgs.contains(where: { $0.contains(".runner JSON") }))
        // Proxy step still ran
        #expect(proxy.saveCalled)
    }

    // MARK: Proxy-fail-continues path

    @Test("accumulates proxy error independently of JSON success")
    func proxyWriteFailureAccumulated() async {
        let runner = makeRunner()
        var draft    = makeDraft(runner: runner)
        let original = makeDraft(runner: runner)
        draft.proxyUrl = "http://proxy.example.com"

        let labels = SpyLabelsService()
        let config = SpyConfigStore()
        let proxy  = SpyProxyStore()
        proxy.shouldThrowOnSave = true  // make proxy step fail
        let useCase = SaveRunnerEditsUseCase(configStore: config, proxyStore: proxy, labelsService: labels)

        let result = await useCase.execute(runner: runner, draft: draft, original: original)

        guard case .failure(let msgs) = result else {
            Issue.record("expected .failure, got .success")
            return
        }
        #expect(msgs.contains(where: { $0.contains("proxy") }))
    }

    // MARK: Labels success path

    @Test("calls labelsService with correct scope and runnerID when labels changed")
    func labelsCalledWithCorrectArgs() async {
        let runner = makeRunner(agentId: 99, gitHubUrl: "https://github.com/myorg/myrepo")
        var draft    = makeDraft(runner: runner)
        let original = makeDraft(runner: runner)
        draft.labelsText = "gpu, large"

        let labels = SpyLabelsService()
        labels.result = ["gpu", "large"]
        let useCase = SaveRunnerEditsUseCase(
            configStore: SpyConfigStore(),
            proxyStore: SpyProxyStore(),
            labelsService: labels
        )

        let result = await useCase.execute(runner: runner, draft: draft, original: original)

        #expect(result == .success)
        #expect(labels.callCount == 1)
        #expect(labels.lastScope == "myorg/myrepo")
        #expect(labels.lastRunnerID == 99)
        #expect(labels.lastLabels == ["gpu", "large"])
    }

    // MARK: Missing installPath guard

    @Test("returns failure immediately when installPath is nil and JSON changes pending")
    func missingInstallPathForJSON() async {
        let runner = makeRunner(installPath: nil)
        var draft    = makeDraft(runner: runner)
        let original = makeDraft(runner: runner)
        draft.workFolder = "other"

        let useCase = SaveRunnerEditsUseCase(
            configStore: SpyConfigStore(),
            proxyStore: SpyProxyStore(),
            labelsService: SpyLabelsService()
        )

        let result = await useCase.execute(runner: runner, draft: draft, original: original)

        guard case .failure(let msgs) = result else {
            Issue.record("expected .failure")
            return
        }
        #expect(msgs.contains(where: { $0.contains("Install path") }))
    }
}
