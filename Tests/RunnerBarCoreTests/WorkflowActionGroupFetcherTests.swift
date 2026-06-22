// WorkflowActionGroupFetcherTests.swift
// RunnerBarCoreTests
//
// Tests for WorkflowActionGroupFetcher — verifies that the transport injection
// seam works correctly: the fetcher calls transport.apiAsync, not the legacy
// ghAPI free function, so all network I/O is observable and replaceable in tests.
//
// These tests use StubTransport, a minimal GitHubTransportProtocol conformer
// that returns pre-registered Data blobs keyed by endpoint prefix. The stub
// lives in this file rather than TestDoubles.swift because it is specific to
// the transport layer and would not be reused by other test suites without
// significant modification.
import Foundation
import Testing
@testable import RunnerBarCore

// MARK: - Helper

/// A trivial reference-type counter so `StubTransport` can track call counts
/// without making `apiAsync` `mutating` (which would conflict with the
/// `GitHubTransportProtocol` existential `let` in `WorkflowActionGroupFetcher`).
private final class _Counter: @unchecked Sendable {
    var value = 0
}

// MARK: - StubTransport

/// Minimal `GitHubTransportProtocol` stub for `WorkflowActionGroupFetcher` tests.
///
/// Responses are registered as an ordered array of `(prefix, Data)` pairs — the
/// *longest matching prefix* wins, with ties broken by array order. This is
/// deterministic regardless of Swift runtime or platform, unlike `Dictionary`
/// iteration order.
///
/// The array is a `let` property (immutable, set once at init), so it is implicitly
/// `Sendable` and the compiler synthesises conformance for `StubTransport` without
/// any unsafe escape hatch.
struct StubTransport: GitHubTransportProtocol {
    /// Ordered prefix → data pairs. Longest-prefix match wins.
    private let responses: [(prefix: String, data: Data)]

    /// Number of times `apiAsync` was called.
    /// Uses a reference type so `apiAsync` does not need `mutating`.
    private let _callCount = _Counter()
    var callCount: Int { _callCount.value }

    init(responses: [String: Data] = [:]) {
        self.responses = responses.map { (prefix: $0.key, data: $0.value) }
            .sorted { $0.prefix.count > $1.prefix.count }
    }

    func apiAsync(_ endpoint: String, timeout: TimeInterval) async -> Data? {
        _callCount.value += 1
        return responses.first(where: { endpoint.hasPrefix($0.prefix) })?.data
    }

    func apiPaginated(_: String, timeout: TimeInterval) async -> Data? { nil }
    func raw(_: String, timeout: TimeInterval) async -> Data? { nil }
    func post(_: String, body: Data?, timeout: TimeInterval) async -> Data? { nil }
    func put(_: String, body: Data, timeout: TimeInterval) async -> Data? { nil }
    func delete(_: String, timeout: TimeInterval) async -> Bool { false }
    func cancelRun(runID: Int, scope: String) async -> Bool { false }
    func patchRunnerLabels(scope: String, runnerID: Int, labels: [String]) async -> [String]? { nil }
    func fetchRegistrationToken(scope: String) async -> String? { nil }
    func fetchRemovalToken(scope: String) async -> String? { nil }
    func deleteRunnerByID(scope: String, runnerID: Int) async -> Bool { false }
}

// MARK: - JSON fixture helpers

private func runsEnvelope(_ runs: [[String: Any]]) -> Data {
    let envelope: [String: Any] = ["workflow_runs": runs]
    return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
}

private func jobsEnvelope(_ jobs: [[String: Any]]) -> Data {
    let envelope: [String: Any] = ["jobs": jobs]
    return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
}

private func minimalRun(id: Int, sha: String, status: String = "completed",
                        conclusion: String? = "success", name: String = "CI") -> [String: Any] {
    var d: [String: Any] = ["id": id, "head_sha": sha, "status": status, "name": name]
    if let conclusion { d["conclusion"] = conclusion }
    return d
}

private func minimalJob(id: Int, name: String = "build",
                        status: String = "completed",
                        conclusion: String? = "success") -> [String: Any] {
    var d: [String: Any] = ["id": id, "name": name, "status": status]
    if let conclusion { d["conclusion"] = conclusion }
    return d
}

// MARK: - WorkflowActionGroupFetcherTests

@Suite("WorkflowActionGroupFetcher")
struct WorkflowActionGroupFetcherTests {
// MARK: - Org scope guard

    /// An org-level scope (no `/repo` segment) must be skipped immediately.
    @Test func fetchActionGroups_orgScope_returnsEmpty() async {
        let transport = StubTransport()
        let fetcher = WorkflowActionGroupFetcher(transport: transport)
        let result = await fetcher.fetchActionGroups(for: "myorg")
        #expect(result.isEmpty)
    }

    // MARK: - Empty API responses

    /// When all three status endpoints return an empty run list the result must
    /// be an empty array — not a crash or a group with no SHA.
    @Test func fetchActionGroups_allEndpointsEmpty_returnsEmpty() async {
        let emptyEnvelope = runsEnvelope([])
        let transport = StubTransport(responses: [
            "repos/owner/repo/actions/runs?status=in_progress": emptyEnvelope,
            "repos/owner/repo/actions/runs?status=queued":      emptyEnvelope,
            "repos/owner/repo/actions/runs?status=completed":   emptyEnvelope,
        ])
        let fetcher = WorkflowActionGroupFetcher(transport: transport)
        let result = await fetcher.fetchActionGroups(for: "owner/repo")
        #expect(result.isEmpty)
    }

    /// When the transport returns `nil` for every endpoint the fetcher must
    /// degrade gracefully.
    @Test func fetchActionGroups_nilResponses_returnsEmpty() async {
        let fetcher = WorkflowActionGroupFetcher(transport: StubTransport())
        let result = await fetcher.fetchActionGroups(for: "owner/repo")
        #expect(result.isEmpty)
    }

    // MARK: - Grouping by head_sha

    /// Two runs sharing the same `head_sha` must be collapsed into a single group.
    @Test func fetchActionGroups_twoRunsSameSha_producesOneGroup() async {
        let sha = "abc1234567890"
        let runs = [
            minimalRun(id: 1, sha: sha, status: "in_progress", conclusion: nil, name: "build"),
            minimalRun(id: 2, sha: sha, status: "in_progress", conclusion: nil, name: "test"),
        ]
        let emptyEnvelope = runsEnvelope([])
        let jobsData = jobsEnvelope([minimalJob(id: 101), minimalJob(id: 102)])
        let transport = StubTransport(responses: [
            "repos/owner/repo/actions/runs?status=in_progress": runsEnvelope(runs),
            "repos/owner/repo/actions/runs?status=queued":      emptyEnvelope,
            "repos/owner/repo/actions/runs?status=completed":   emptyEnvelope,
            "repos/owner/repo/actions/runs/1/jobs":             jobsData,
            "repos/owner/repo/actions/runs/2/jobs":             jobsData,
        ])
        let fetcher = WorkflowActionGroupFetcher(transport: transport)
        let result = await fetcher.fetchActionGroups(for: "owner/repo")
        #expect(result.count == 1)
        #expect(result.first?.headSha == sha)
        #expect(result.first?.runs.count == 2)
    }
    /// Two runs with different `head_sha` values must produce two distinct groups.
    @Test func fetchActionGroups_twoRunsDifferentSha_producesTwoGroups() async {
        let sha1 = "aaa111"
        let sha2 = "bbb222"
        let emptyEnvelope = runsEnvelope([])
        let jobsData = jobsEnvelope([])
        let transport = StubTransport(responses: [
            "repos/owner/repo/actions/runs?status=in_progress": runsEnvelope([
                minimalRun(id: 1, sha: sha1, status: "in_progress", conclusion: nil),
                minimalRun(id: 2, sha: sha2, status: "in_progress", conclusion: nil),
            ]),
            "repos/owner/repo/actions/runs?status=queued":      emptyEnvelope,
            "repos/owner/repo/actions/runs?status=completed":   emptyEnvelope,
            "repos/owner/repo/actions/runs/1/jobs":             jobsData,
            "repos/owner/repo/actions/runs/2/jobs":             jobsData,
        ])
        let fetcher = WorkflowActionGroupFetcher(transport: transport)
        let result = await fetcher.fetchActionGroups(for: "owner/repo")
        #expect(result.count == 2)
    }

    // MARK: - Sorting: in-progress first

    /// In-progress groups must sort before completed groups.
    @Test func fetchActionGroups_mixedStatuses_inProgressSortsFirst() async {
        let shaInProgress = "inprogress1"
        let shaCompleted  = "completed1"
        let emptyEnvelope = runsEnvelope([])
        let jobsData = jobsEnvelope([minimalJob(id: 1)])
        let transport = StubTransport(responses: [
            "repos/owner/repo/actions/runs?status=in_progress": runsEnvelope([
                minimalRun(id: 1, sha: shaInProgress, status: "in_progress", conclusion: nil),
            ]),
            "repos/owner/repo/actions/runs?status=queued": emptyEnvelope,
            "repos/owner/repo/actions/runs?status=completed": runsEnvelope([
                minimalRun(id: 2, sha: shaCompleted, status: "completed", conclusion: "success"),
            ]),
            "repos/owner/repo/actions/runs/1/jobs": jobsData,
            "repos/owner/repo/actions/runs/2/jobs": jobsData,
        ])
        let fetcher = WorkflowActionGroupFetcher(transport: transport)
        let result = await fetcher.fetchActionGroups(for: "owner/repo")
        #expect(result.count == 2)
        #expect(result.first?.headSha == shaInProgress)
        #expect(result.last?.headSha  == shaCompleted)
    }
    // MARK: - Cache hit

    /// When a cache entry exists for a SHA and all its jobs are concluded with
    /// no in-progress steps, the fetcher must serve the cached jobs without
    /// issuing a `/jobs` API call. The `callCount` assertion makes the regression
    /// signal explicit: only 3 calls (in_progress, queued, completed), no /jobs.
    @Test func fetchActionGroups_concludedCacheEntry_jobsNotRefetched() async {
        let sha = "cachedsha"
        let cachedJob = ActiveJob(
            id: 999, name: "cached-build", htmlUrl: nil,
            status: .completed, conclusion: .success, isDimmed: false,
            runnerName: nil, scope: "owner/repo",
            startedAt: nil, completedAt: Date(), steps: []
        )
        let cachedGroup = WorkflowActionGroup(
            headSha: sha, label: sha, title: "Cached commit",
            headBranch: nil, repo: "owner/repo", runs: [], jobs: [cachedJob],
            firstJobStartedAt: nil, lastJobCompletedAt: nil, createdAt: nil
        )
        let emptyEnvelope = runsEnvelope([])
        // Run status is "completed" so the fixture intent is clear — this run
        // will always take the cache path regardless of future logic changes.
        let transport = StubTransport(responses: [
            "repos/owner/repo/actions/runs?status=in_progress": runsEnvelope([
                minimalRun(id: 1, sha: sha, status: "completed", conclusion: "success"),
            ]),
            "repos/owner/repo/actions/runs?status=queued":    emptyEnvelope,
            "repos/owner/repo/actions/runs?status=completed": emptyEnvelope,
        ])
        let fetcher = WorkflowActionGroupFetcher(transport: transport)
        let result = await fetcher.fetchActionGroups(for: "owner/repo", cache: [sha: cachedGroup])
        #expect(result.count == 1)
        #expect(result.first?.jobs.first?.id == 999)
        #expect(transport.callCount == 3)
    }

    // MARK: - Repo label

    /// Each group must carry the repo scope it was fetched for.
    @Test func fetchActionGroups_singleRun_groupHasCorrectRepoScope() async {
        let sha = "scopecheck"
        let jobsData = jobsEnvelope([])
        let emptyEnvelope = runsEnvelope([])
        let transport = StubTransport(responses: [
            "repos/owner/repo/actions/runs?status=in_progress": runsEnvelope([
                minimalRun(id: 1, sha: sha, status: "in_progress", conclusion: nil),
            ]),
            "repos/owner/repo/actions/runs?status=queued":    emptyEnvelope,
            "repos/owner/repo/actions/runs?status=completed": emptyEnvelope,
            "repos/owner/repo/actions/runs/1/jobs":           jobsData,
        ])
        let fetcher = WorkflowActionGroupFetcher(transport: transport)
        let result = await fetcher.fetchActionGroups(for: "owner/repo")
        #expect(result.first?.repo == "owner/repo")
    }
}
