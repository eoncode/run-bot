// AppUpdaterBehaviorTests.swift
// AppUpdater
import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterBehaviorTests

/// Exercises `AppUpdater.handle` decision paths that don't require the network:
/// the already-cached short-circuit and the in-flight download guard.
@MainActor
@Suite("AppUpdater.handle")
struct AppUpdaterBehaviorTests {

    /// Builds an `AppUpdater` bound to an isolated `UserDefaults` suite so the
    /// scoped cache keys never touch `.standard`.
    private func makeUpdater(domain: String, defaults: UserDefaults) -> AppUpdater {
        AppUpdater(
            repo: "example/repo",
            currentVersion: "1.0.0",
            assetName: { _ in "RunBot.zip" },
            schedulerIdentifier: domain,
            userDefaults: defaults,
            betaChannelProvider: { false }
        )
    }

    private func makeAsset(_ name: String) -> ReleaseAsset {
        ReleaseAsset(
            name: name,
            browserDownloadURL: URL(string: "https://example.com/\(name)")!
        )
    }

    // MARK: - Cache hit

    /// When a cached zip for the discovered version already exists on disk,
    /// `handle` rehydrates host state and starts NO download.
    @Test func cacheHitRehydratesWithoutDownloading() async throws {
        let domain = "test.cachehit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }

        // Write a real temp file and point the scoped cache keys at it.
        let keys = AppUpdaterDefaults(domain: domain)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cachehit-\(UUID().uuidString).zip")
        try Data("zip".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        defaults.set("v9.9.9", forKey: keys.cachedUpdateVersion)
        defaults.set(tmp.path, forKey: keys.cachedUpdateZipPath)

        let updater = makeUpdater(domain: domain, defaults: defaults)
        let state = MockUpdateState()
        let release = AvailableRelease(tagName: "v9.9.9", assets: [], checksumURL: nil)

        await updater.handle(release, state: state)

        #expect(state.rehydrateCount == 1)
        #expect(state.downloadStartedCount == 0)
        #expect(state.updateZipURL == tmp)
        #expect(updater.isDownloading == false)
    }

    // MARK: - In-flight guard

    /// While a download is already running, a second `handle` for a downloadable
    /// release is dropped: no new "download started" transition occurs.
    @Test func inFlightDownloadGuardDropsSecondHandle() async {
        let domain = "test.inflight.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }

        let updater = makeUpdater(domain: domain, defaults: defaults)
        updater.isDownloading = true // simulate an in-flight download

        let state = MockUpdateState()
        let release = AvailableRelease(
            tagName: "v2.0.0",
            assets: [makeAsset("RunBot.zip")],
            checksumURL: URL(string: "https://example.com/RunBot.zip.sha256")
        )

        await updater.handle(release, state: state)

        // The available-update label is still set, but the download path is guarded.
        #expect(state.availableUpdates == ["v2.0.0"])
        #expect(state.downloadStartedCount == 0)
        #expect(state.updateZipURL == nil)
    }

    // MARK: - Missing asset

    /// A release with no matching zip asset flips the host failure state (browser
    /// fallback) and starts no download.
    @Test func missingAssetFailsWithoutDownloading() async {
        let domain = "test.noasset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }

        let updater = makeUpdater(domain: domain, defaults: defaults)
        let state = MockUpdateState()
        let release = AvailableRelease(
            tagName: "v2.0.0",
            assets: [makeAsset("SomethingElse.zip")],
            checksumURL: nil
        )

        await updater.handle(release, state: state)

        #expect(state.updateFailedCount == 1)
        #expect(state.downloadStartedCount == 0)
        #expect(updater.isDownloading == false)
    }
}
