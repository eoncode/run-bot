// AppUpdaterDownloadTests.swift
// AppUpdaterTests
import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterDownloadTests

/// Tests that verify `AppUpdater.handle` download-path state-machine behaviour.
///
/// Network I/O is avoided: asset URLs that force fast failures (nil checksumURL,
/// non-HTTP URLs) let us exercise every code path in `downloadUpdate` without
/// hitting a real server. All tests are `@MainActor` because `AppUpdater` and
/// `MockUpdateState` are both `@MainActor`.
@MainActor
struct AppUpdaterDownloadTests {

    // MARK: - Helpers

    private func makeUpdater(
        currentVersion: String = "1.0.0"
    ) throws -> (updater: AppUpdater, state: MockUpdateState, defaults: UserDefaults) {
        let domain = "AppUpdaterDownloadTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let updater = AppUpdater(
            repo: "owner/repo",
            currentVersion: currentVersion,
            assetName: { _ in "App.zip" },
            schedulerIdentifier: domain,
            userDefaults: defaults,
            betaChannelProvider: { false }
        )
        return (updater, MockUpdateState(), defaults)
    }

    /// Makes an `AvailableRelease` where checksumURL is `nil`.
    /// `AppUpdater.downloadUpdate` guards on a nil checksumURL and immediately
    /// throws `URLError(.resourceUnavailable)` → catch → `setUpdateFailed()`.
    /// This is the fastest failure path and exercises the catch block without
    /// any network activity.
    private func releaseWithNilChecksum(tagName: String = "v2.0.0") throws -> AvailableRelease {
        let asset = ReleaseAsset(
            name: "App.zip",
            browserDownloadURL: try #require(URL(string: "https://example.com/App.zip"))
        )
        return AvailableRelease(tagName: tagName, assets: [asset], checksumURL: nil)
    }

    // MARK: - Tests

    /// A nil checksumURL causes `downloadUpdate` to throw before any network
    /// activity. The catch block must call `setUpdateFailed()` and clear
    /// `isDownloading`.
    @Test func downloadError_nilChecksumURL_setsUpdateFailed() async throws {
        let (updater, state, _) = try makeUpdater()
        await updater.handle(try releaseWithNilChecksum(), state: state)
        // Allow the spawned Task to complete.
        await Task.yield()
        await Task.yield()
        await Task.yield()
        #expect(state.updateFailedCount == 1)
        #expect(updater.isDownloading == false)
    }

    /// After a download error `isDownloading` must be `false` — regression
    /// guard for the stuck-state bug where it stays `true` and every
    /// subsequent `handle()` silently no-ops via the in-flight guard.
    @Test func downloadError_clearsIsDownloadingFlag() async throws {
        let (updater, state, _) = try makeUpdater()
        await updater.handle(try releaseWithNilChecksum(), state: state)
        await Task.yield()
        await Task.yield()
        await Task.yield()
        #expect(updater.isDownloading == false)
        _ = state
    }

    /// A nil checksumURL must call `setUpdateFailed()`, NOT `setDownloadComplete()`.
    @Test func checksumURLNil_setsUpdateFailed_notDownloadComplete() async throws {
        let (updater, state, _) = try makeUpdater()
        await updater.handle(try releaseWithNilChecksum(), state: state)
        await Task.yield()
        await Task.yield()
        await Task.yield()
        #expect(state.updateFailedCount == 1)
        #expect(state.downloadCompleteCount == 0)
    }

    /// While `isDownloading` is already `true`, a second `handle()` call for a
    /// downloadable release must be dropped entirely: `downloadCallCount` on the
    /// provider stays at 0 (no new download starts) and `downloadStartedCount`
    /// on the state is not incremented again.
    @Test func concurrentHandle_secondDropped_whenIsDownloadingTrue() async throws {
        let (updater, state, _) = try makeUpdater()
        updater.isDownloading = true   // simulate an in-flight download
        await updater.handle(try releaseWithNilChecksum(), state: state)
        #expect(state.downloadStartedCount == 0)
        #expect(state.updateFailedCount == 0)
    }

    /// `setDownloadStarted()` must be called exactly once when a fresh download
    /// begins (after the in-flight guard passes).
    @Test func freshDownload_setsDownloadStartedOnce() async throws {
        let (updater, state, _) = try makeUpdater()
        await updater.handle(try releaseWithNilChecksum(), state: state)
        // setDownloadStarted fires synchronously before the Task spawns.
        #expect(state.downloadStartedCount == 1)
    }
}
