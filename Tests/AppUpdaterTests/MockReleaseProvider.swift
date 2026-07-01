// MockReleaseProvider.swift
// AppUpdaterTests
@testable import AppUpdater

// MARK: - MockReleaseProvider

/// A configurable test double for `ReleaseProvider`.
///
/// `actor` isolation ensures mutation of call-capture properties is safe
/// when tests `await` on recorded values — no `@unchecked Sendable`
/// required (Pillar 6). Zero `DispatchQueue` usage (Pillar 5).
///
/// ## Usage
///
/// ```swift
/// let provider = MockReleaseProvider()
/// provider.fetchResult = .success(AvailableRelease(tagName: "v2.0.0", assets: [], checksumURL: nil))
/// provider.downloadResult = .success(URL(fileURLWithPath: "/tmp/App.zip"))
/// let updater = AppUpdater(
///     repo: "owner/repo",
///     currentVersion: "1.0.0",
///     assetName: { _ in "App.zip" },
///     schedulerIdentifier: "com.test.update",
///     releaseProvider: provider
/// )
/// ```
actor MockReleaseProvider: ReleaseProvider {

    // MARK: - Configuration

    /// Result returned from `fetchLatestRelease`. Defaults to `.success(nil)`
    /// (no update available).
    var fetchResult: Result<AvailableRelease?, Error> = .success(nil)

    /// Result returned from `downloadUpdate`. Defaults to a success with a
    /// placeholder URL — override per test when exercising the download path.
    var downloadResult: Result<URL, Error> = .success(URL(fileURLWithPath: "/tmp/MockUpdate.zip"))

    /// Number of simulated progress steps emitted during `downloadUpdate`.
    /// Each step calls `await Task.yield()` once (Pillar 5 — no DispatchQueue).
    var simulatedSteps: Int = 5

    // MARK: - Call capture

    /// Number of times `fetchLatestRelease` was called.
    private(set) var fetchCallCount: Int = 0

    /// Number of times `downloadUpdate` was called.
    private(set) var downloadCallCount: Int = 0

    /// The `betaChannel` value last passed to `fetchLatestRelease`.
    /// `nil` until the first call.
    private(set) var capturedBetaChannel: Bool?

    /// The `repo` value last passed to `fetchLatestRelease`.
    /// `nil` until the first call.
    private(set) var capturedRepo: String?

    // MARK: - Init

    init() {}

    // MARK: - ReleaseProvider

    /// Records the call arguments and returns `fetchResult`.
    func fetchLatestRelease(
        repo: String,
        betaChannel: Bool,
        assetName: (String) -> String
    ) async throws -> AvailableRelease? {
        fetchCallCount += 1
        capturedRepo = repo
        capturedBetaChannel = betaChannel
        return try fetchResult.get()
    }

    /// Records the call and returns `downloadResult` after emitting
    /// `simulatedSteps` progress yield points.
    func downloadUpdate(
        release: AvailableRelease,
        progressHandler: ((Double) -> Void)?
    ) async throws -> URL {
        downloadCallCount += 1
        for step in 1...max(1, simulatedSteps) {
            await Task.yield()
            progressHandler?(Double(step) / Double(simulatedSteps))
        }
        return try downloadResult.get()
    }
}
