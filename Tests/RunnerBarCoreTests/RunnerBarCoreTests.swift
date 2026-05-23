// RunnerBarCoreTests.swift
// RunnerBarCoreTests
import XCTest
@testable import RunnerBarCore

// MARK: - ActiveJob.elapsed

final class ActiveJobElapsedTests: XCTestCase {

    func test_elapsed_queued_returnsZero() {
        let job = ActiveJob(id: 1, name: "J", status: "queued")
        XCTAssertEqual(job.elapsed, "00:00")
    }

    func test_elapsed_completedWithTimes() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end   = Date(timeIntervalSinceReferenceDate: 125)
        let job = ActiveJob(
            id: 1, name: "J", status: "completed",
            conclusion: "success",
            startedAt: start,
            completedAt: end
        )
        XCTAssertEqual(job.elapsed, "02:05")
    }

    func test_elapsed_completedMissingTimes_returnsDashes() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", conclusion: "success")
        XCTAssertEqual(job.elapsed, "--:--")
    }

    func test_elapsed_inProgress_usesStartedAt() {
        let start = Date(timeIntervalSinceNow: -90)
        let job = ActiveJob(id: 1, name: "J", status: "in_progress", startedAt: start)
        let mins = Int(job.elapsed.prefix(2))!
        let secs = Int(job.elapsed.suffix(2))!
        let total = mins * 60 + secs
        XCTAssertGreaterThanOrEqual(total, 89)
        XCTAssertLessThanOrEqual(total, 95)
    }
}

// MARK: - ActiveJob.isLocalRunner

final class ActiveJobIsLocalRunnerTests: XCTestCase {

    func test_isLocalRunner_nil_whenNoRunnerName() {
        let job = ActiveJob(id: 1, name: "J", status: "queued")
        XCTAssertNil(job.isLocalRunner)
    }

    func test_isLocalRunner_false_forUbuntuHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "ubuntu-latest")
        XCTAssertEqual(job.isLocalRunner, false)
    }

    func test_isLocalRunner_false_forMacOSHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "macos-14")
        XCTAssertEqual(job.isLocalRunner, false)
    }

    func test_isLocalRunner_true_forSelfHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "my-mac-mini")
        XCTAssertEqual(job.isLocalRunner, true)
    }
}

// MARK: - RunnerModel.displayStatus

final class RunnerModelDisplayStatusTests: XCTestCase {

    private func makeRunner(
        isRunning: Bool,
        isBusy: Bool = false,
        githubStatus: String = "online",
        lifecycleWarning: String? = nil
    ) -> RunnerModel {
        RunnerModel(
            runnerName: "test-runner",
            gitHubUrl: nil,
            agentId: nil,
            workFolder: nil,
            installPath: "/tmp/runner",
            isRunning: isRunning,
            githubStatus: githubStatus,
            isBusy: isBusy,
            lifecycleWarning: lifecycleWarning
        )
    }

    func test_displayStatus_running() {
        XCTAssertEqual(makeRunner(isRunning: true).displayStatus, "running")
    }

    func test_displayStatus_busy() {
        XCTAssertEqual(makeRunner(isRunning: true, isBusy: true).displayStatus, "running")
    }

    func test_displayStatus_online() {
        XCTAssertEqual(makeRunner(isRunning: false, githubStatus: "online").displayStatus, "online")
    }

    func test_displayStatus_offline() {
        XCTAssertEqual(makeRunner(isRunning: false, githubStatus: "offline").displayStatus, "offline")
    }

    func test_displayStatus_lifecycleWarningTakesPriority() {
        let runner = makeRunner(isRunning: true, lifecycleWarning: "update required")
        XCTAssertEqual(runner.displayStatus, "update required")
    }
}

// MARK: - RunnerMetrics

final class RunnerMetricsTests: XCTestCase {

    func test_equatable_sameValues() {
        let a = RunnerMetrics(cpu: 12.5, mem: 3.0)
        let b = RunnerMetrics(cpu: 12.5, mem: 3.0)
        XCTAssertEqual(a, b)
    }

    func test_equatable_differentCPU() {
        let a = RunnerMetrics(cpu: 10.0, mem: 3.0)
        let b = RunnerMetrics(cpu: 20.0, mem: 3.0)
        XCTAssertNotEqual(a, b)
    }

    func test_equatable_differentMem() {
        let a = RunnerMetrics(cpu: 10.0, mem: 1.0)
        let b = RunnerMetrics(cpu: 10.0, mem: 2.0)
        XCTAssertNotEqual(a, b)
    }
}

// MARK: - AggregateStatus

final class AggregateStatusTests: XCTestCase {

    func test_dot_allOnline() {
        XCTAssertEqual(AggregateStatus.allOnline.dot, "🟢")
    }

    func test_dot_someOffline() {
        XCTAssertEqual(AggregateStatus.someOffline.dot, "🟡")
    }

    func test_dot_allOffline() {
        XCTAssertEqual(AggregateStatus.allOffline.dot, "⚫")
    }

    func test_symbolName_allOnline() {
        XCTAssertEqual(AggregateStatus.allOnline.symbolName, "circle.fill")
    }

    func test_symbolName_someOffline() {
        XCTAssertEqual(AggregateStatus.someOffline.symbolName, "circle.lefthalf.filled")
    }

    func test_symbolName_allOffline() {
        XCTAssertEqual(AggregateStatus.allOffline.symbolName, "circle")
    }
}

// MARK: - PollResultBuilder (pure logic)

final class PollResultBuilderTests: XCTestCase {

    // MARK: trimJobCache

    func test_trimJobCache_removesOldestWhenOverLimit() {
        var cache: [Int: ActiveJob] = [
            1: ActiveJob(id: 1, name: "A", status: "completed", completedAt: Date(timeIntervalSinceReferenceDate: 100)),
            2: ActiveJob(id: 2, name: "B", status: "completed", completedAt: Date(timeIntervalSinceReferenceDate: 200)),
            3: ActiveJob(id: 3, name: "C", status: "completed", completedAt: Date(timeIntervalSinceReferenceDate: 300)),
            4: ActiveJob(id: 4, name: "D", status: "completed", completedAt: Date(timeIntervalSinceReferenceDate: 400)),
        ]
        PollResultBuilder.trimJobCache(&cache, limit: 3)
        XCTAssertEqual(cache.count, 3)
        XCTAssertNil(cache[1], "Oldest entry should be evicted")
    }

    func test_trimJobCache_noopWhenUnderLimit() {
        var cache: [Int: ActiveJob] = [
            1: ActiveJob(id: 1, name: "A", status: "completed"),
            2: ActiveJob(id: 2, name: "B", status: "completed"),
        ]
        PollResultBuilder.trimJobCache(&cache, limit: 3)
        XCTAssertEqual(cache.count, 2)
    }

    // MARK: buildJobDisplay

    func test_buildJobDisplay_liveJobsFirst() {
        let live: [ActiveJob] = [
            ActiveJob(id: 10, name: "Live", status: "in_progress")
        ]
        let cache: [Int: ActiveJob] = [
            20: ActiveJob(id: 20, name: "Done", status: "completed", conclusion: "success")
        ]
        let display = PollResultBuilder.buildJobDisplay(live: live, cache: cache)
        XCTAssertEqual(display.first?.id, 10)
        XCTAssertTrue(display.contains(where: { $0.id == 20 }))
    }

    func test_buildJobDisplay_emptyLiveAndCache_isEmpty() {
        let display = PollResultBuilder.buildJobDisplay(live: [], cache: [:])
        XCTAssertTrue(display.isEmpty)
    }

    // MARK: buildJobState

    func test_buildJobState_liveJobAppearsInDisplay() {
        let liveJob = ActiveJob(id: 99, name: "CI", status: "in_progress")
        let result = PollResultBuilder.buildJobState(
            snapPrev: [:],
            snapCache: [:],
            fetchJobs: { [liveJob] },
            backfill: { _ in }
        )
        XCTAssertTrue(result.display.contains(where: { $0.id == 99 }))
    }

    func test_buildJobState_completedJobMovesToCache() {
        let doneJob = ActiveJob(id: 42, name: "Deploy", status: "completed", conclusion: "success")
        let result = PollResultBuilder.buildJobState(
            snapPrev: [:],
            snapCache: [:],
            fetchJobs: { [doneJob] },
            backfill: { _ in }
        )
        XCTAssertTrue(result.newCache.keys.contains(42))
        XCTAssertEqual(result.newCache[42]?.isDimmed, true)
    }
}
