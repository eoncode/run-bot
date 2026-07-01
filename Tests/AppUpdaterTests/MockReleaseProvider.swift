// MockReleaseProvider.swift
// AppUpdaterTests
@testable import AppUpdater

// MARK: - MockReleaseProvider

/// A configurable test double for `ReleaseProvider`.
///
/// `actor` isolation ensures mutation of call-capture properties is safe
/// when tests `await provider.capturedBetaChannel` — no `@unchecked Sendable`
/// required (Pillar 6).
///
/// ## Usage
///
/// ```swift
/// let provider = MockReleaseProvider()
/// await provider.set(releaseToReturn: AvailableRelease(tagName: "v2.0.0", assets: [], checksumURL: nil))
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

    /// The release to return from `fetchLatestRelease`.
    /// `nil` simulates a network failure or an empty releases list.
    private var releaseToReturn: AvailableRelease?

    /// Creates a new mock with an optional pre-configured release to return.
    init(releaseToReturn: AvailableRelease? = nil) {
        self.releaseToReturn = releaseToReturn
    }

    /// Updates the release that will be returned by subsequent
    /// `fetchLatestRelease` calls.
    func set(releaseToReturn: AvailableRelease?) {
        self.releaseToReturn = releaseToReturn
    }

    // MARK: - Call capture

    /// Number of times `fetchLatestRelease` was called.
    private(set) var callCount: Int = 0

    /// The `betaChannel` value last passed to `fetchLatestRelease`.
    /// `nil` until the first call — assert this to verify beta wiring.
    private(set) var capturedBetaChannel: Bool?

    /// The `repo` value last passed to `fetchLatestRelease`.
    /// `nil` until the first call.
    private(set) var capturedRepo: String?

    // MARK: - ReleaseProvider

    /// Records the call arguments and returns `releaseToReturn`.
    ///
    /// The `assetName` closure is intentionally ignored — checksum-sidecar
    /// resolution is a production concern that lives in
    /// `GitHubReleaseProvider` / `UpdateChecker.fetchLatestAvailableRelease`.
    /// Tests that need a specific checksum URL should set it directly on the
    /// `AvailableRelease` passed to `releaseToReturn`.
    func fetchLatestRelease(
        repo: String,
        betaChannel: Bool,
        assetName: (String) -> String
    ) async -> AvailableRelease? {
        callCount += 1
        capturedRepo = repo
        capturedBetaChannel = betaChannel
        return releaseToReturn
    }
}
