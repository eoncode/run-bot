// FailureHookRunnerUseCaseTests.swift
// RunnerBarCoreTests
import Foundation
import Testing
@testable import RunnerBarCore

// MARK: - FailureHookRunnerUseCaseTests

@Suite("FailureHookRunnerUseCase")
struct FailureHookRunnerUseCaseTests {

    // MARK: - fireIfNeeded — gate checks

    /// Hook disabled → terminal must not open regardless of group conclusion.
    @Test func fireIfNeeded_hookDisabled_doesNotOpenTerminal() async {
        let spy = SpyTerminalLauncher()
        let sut = FailureHookRunnerUseCase(
            preferencesStore: MockScopePreferencesStore(hookEnabled: false),
            terminalLauncher: spy
        )
        await sut.fireIfNeeded(group: .fixture(conclusion: .failure), scope: "owner/repo")
        await MainActor.run { #expect(spy.openCallCount == 0) }
    }

    /// Hook enabled but group did not fail → terminal must not open.
    @Test func fireIfNeeded_hookEnabled_groupNotFailed_doesNotOpenTerminal() async {
        let spy = SpyTerminalLauncher()
        let sut = FailureHookRunnerUseCase(
            preferencesStore: MockScopePreferencesStore(hookEnabled: true),
            terminalLauncher: spy
        )
        await sut.fireIfNeeded(group: .fixture(conclusion: .success), scope: "owner/repo")
        await MainActor.run { #expect(spy.openCallCount == 0) }
    }

    /// Branch filter set, group branch does not match → terminal must not open.
    @Test func fireIfNeeded_branchFilterMismatch_doesNotOpenTerminal() async {
        let spy = SpyTerminalLauncher()
        let sut = FailureHookRunnerUseCase(
            preferencesStore: MockScopePreferencesStore(hookEnabled: true, branch: "main"),
            terminalLauncher: spy
        )
        await sut.fireIfNeeded(
            group: .fixture(conclusion: .failure, branch: "feature/x"),
            scope: "owner/repo"
        )
        await MainActor.run { #expect(spy.openCallCount == 0) }
    }

    /// All gates pass (hook enabled, group failed, branch matches) → terminal opens exactly once.
    /// `fetchFailedJobs` calls `ghAPI` which returns nil in CI (no token); jobs comes back empty.
    /// Terminal still opens once because all guards cleared before the network call.
    @Test func fireIfNeeded_allGatesPass_opensTerminalOnce() async {
        let spy = SpyTerminalLauncher()
        let sut = FailureHookRunnerUseCase(
            preferencesStore: MockScopePreferencesStore(hookEnabled: true, branch: "main"),
            terminalLauncher: spy
        )
        await sut.fireIfNeeded(
            group: .fixture(conclusion: .failure, branch: "main"),
            scope: "owner/repo"
        )
        await MainActor.run { #expect(spy.openCallCount == 1) }
    }

    // MARK: - resolveTokens — pure, no network

    /// `$LOCAL_PATH` is replaced with the supplied path.
    @Test func resolveTokens_substitutesLocalPath() {
        let cmd = FailureHookRunnerUseCase.resolveTokens(
            "cd '$LOCAL_PATH'",
            group: .fixture(),
            scope: "owner/repo",
            jobs: [],
            localRepoPath: "/Users/andre/code/myrepo"
        )
        #expect(cmd == "cd '/Users/andre/code/myrepo'")
    }

    /// A single-quote inside a path value is escaped as `'\''`.
    @Test func resolveTokens_singleQuoteInPath_isEscaped() {
        let cmd = FailureHookRunnerUseCase.resolveTokens(
            "cd '$LOCAL_PATH'",
            group: .fixture(),
            scope: "owner/repo",
            jobs: [],
            localRepoPath: "/Users/o'brien/code"
        )
        #expect(cmd == "cd '/Users/o'\\''brien/code'")
    }

    /// A single-quote inside `$WORKFLOW_NAME` is correctly escaped.
    @Test func resolveTokens_singleQuoteInWorkflowName_isEscaped() {
        let cmd = FailureHookRunnerUseCase.resolveTokens(
            "echo '$WORKFLOW_NAME'",
            group: .fixture(workflowName: "CI: O'Brien's job"),
            scope: "owner/repo",
            jobs: []
        )
        #expect(cmd == "echo 'CI: O'\\''Brien'\\''s job'")
    }

    /// Single-quote content inside `$FAILURE_LOG` is correctly escaped end-to-end.
    @Test func resolveTokens_singleQuoteInFailureLog_isEscaped() {
        let cmd = FailureHookRunnerUseCase.resolveTokens(
            "gemini -p '$FAILURE_LOG'",
            group: .fixture(conclusion: .failure, workflowName: "O'Brien CI"),
            scope: "owner/repo",
            jobs: []
        )
        #expect(!cmd.contains("workflow=O'Brien"))
        #expect(cmd.contains("workflow=O'\\''Brien"))
    }

    /// After resolution, none of the 11 placeholder tokens remain in the output.
    @Test func resolveTokens_allTokensPresent_noLiteralsRemain() {
        let template = "$LOCAL_PATH $SCOPE $BRANCH $COMMIT_SHA $RUN_ID $WORKFLOW_NAME $RUN_LINK $COMMIT_LINK $BRANCH_LINK $REPO_LINK $FAILURE_LOG"
        let result = FailureHookRunnerUseCase.resolveTokens(
            template,
            group: .fixture(),
            scope: "owner/repo",
            jobs: [],
            localRepoPath: "/tmp"
        )
        #expect(!result.contains("$LOCAL_PATH"))
        #expect(!result.contains("$SCOPE"))
        #expect(!result.contains("$BRANCH"))
        #expect(!result.contains("$COMMIT_SHA"))
        #expect(!result.contains("$RUN_ID"))
        #expect(!result.contains("$WORKFLOW_NAME"))
        #expect(!result.contains("$FAILURE_LOG"))
        #expect(!result.contains("$RUN_LINK"))
        #expect(!result.contains("$COMMIT_LINK"))
        #expect(!result.contains("$BRANCH_LINK"))
        #expect(!result.contains("$REPO_LINK"))
    }

    // MARK: - buildLogContent

    /// When no jobs are supplied the fallback contains a FAILED run summary line.
    @Test func buildLogContent_noJobs_returnsFallbackSummary() {
        let result = FailureHookRunnerUseCase.buildLogContent(
            group: .fixture(conclusion: .failure),
            scope: "owner/repo",
            jobs: []
        )
        #expect(result.contains("FAILED run"))
    }

    /// When all runs have a non-hook conclusion the fallback is empty.
    @Test func buildLogContent_noFailedRuns_returnsEmpty() {
        let result = FailureHookRunnerUseCase.buildLogContent(
            group: .fixture(conclusion: .success),
            scope: "owner/repo",
            jobs: []
        )
        #expect(result.isEmpty)
    }
}
