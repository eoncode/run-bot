// WorkflowActionGroupFetcherTests.swift
// RunnerBarCoreTests
import Foundation
import Testing
@testable import RunnerBarCore

// MARK: - Helper
private final class _Counter: @unchecked Sendable {
    var value = 0
}


// MARK: - StubTransport

struct StubTransport: GitHubTransportProtocol {
    private let responses: [(prefix: String, data: Data)]
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
