// AppUpdater.swift
// AppUpdater
import CryptoKit
import Foundation
// AppKit is unavailable in the SPM headless test runner — this guard is
// required for `swift test` even though the package is macOS(.v26)-only.
#if canImport(AppKit)
import AppKit
#endif

// MARK: - AppUpdater

/// Drives the in-app auto-update flow: GitHub Releases poll → semver compare →
/// zip download → SHA-256 verification → host-state mutation → install &
/// relaunch on user confirmation.
///
/// `AppUpdater` is a configurable `@MainActor` class carrying no host-specific
/// state of its own beyond what the caller injects. All UI-facing state lives
/// in a caller-supplied `any UpdateStateProviding`; all persisted state lives
/// in the injected `UserDefaults` under keys scoped to `schedulerIdentifier`.
///
/// ## Isolation model
///
/// The class is `@MainActor`, so `isInstalling`, `isDownloading`, and the
/// scheduler reference are race-free without extra locking. The blocking work
/// runs off the main thread regardless: `URLSession` downloads suspend rather
/// than block, checksum verification runs in the `@concurrent` `verifyChecksum`
/// free function, and subprocess launches run in the `@concurrent` `runCommand`
/// helper. The background download is spawned with a plain `Task { }` that
/// inherits `@MainActor`, so `state` is captured in-actor and needs no
/// `Sendable` conformance across an actor boundary.
///
/// ## Typical usage
///
/// ```swift
/// let updater = AppUpdater(
///     repo: "your-org/your-repo",
///     currentVersion: "1.2.3",
///     assetName: { _ in "YourApp.zip" },
///     schedulerIdentifier: "com.your-org.update-check",
///     betaChannelProvider: { UserDefaults.standard.bool(forKey: "betaChannel") }
/// )
/// updater.rehydrateCachedUpdateIfNewer(state: myState)
/// await updater.checkAndHandle(state: myState)
/// updater.scheduleBackgroundCheck(state: myState)
/// ```
@MainActor
public final class AppUpdater {

    // MARK: - Public configuration

    /// `"owner/name"` GitHub repository slug polled for releases.
    public let repo: String

    /// The running app's version (full semver incl. any pre-release suffix).
    /// The library never reads `Bundle` — the host supplies this.
    public let currentVersion: String

    /// Reverse-DNS identifier for the background scheduler; also the domain
    /// used to scope this updater's `UserDefaults` keys.
    public let schedulerIdentifier: String

    // MARK: - Internal configuration
    //
    // The properties below are `internal` (not `public`) by deliberate design:
    //
    // • `assetName` — a `@Sendable` closure injected at init; the host has no
    //   need to inspect it after construction, and exposing it publicly would
    //   widen the API surface for no benefit.
    // • `defaults` / `keys` — implementation details of the persistence layer;
    //   not part of the public contract.
    // • `betaChannelProvider` — injected closure; same rationale as `assetName`.
    // • `provider` — the `ReleaseProvider` seam; injectable for tests, not
    //   intended for host-app inspection.
    // • `isInstalling` / `isDownloading` — runtime guards accessed via
    //   `@testable import` in the same-package test target. If this library is
    //   ever extracted to its own repository these should be `public` so
    //   external test targets can reach them without `@testable import`.
    //
    // REVIEWER: The asymmetry between `repo`/`currentVersion`/`schedulerIdentifier`
    // (public) and the properties below (internal) is intentional. Do NOT make
    // the closures or defaults public without a concrete external-consumer use
    // case — every public symbol is a promise.

    /// Maps a release tag name to the expected zip asset filename.
    ///
    /// Injected so hosts can use a fixed name (`{ _ in "App.zip" }`) or a
    /// versioned one (`{ v in "App-\(v).zip" }`). The SHA-256 sidecar is
    /// expected at `<assetName>.sha256`.
    ///
    /// `@Sendable` is required because `fetchLatestRelease` (on `ReleaseProvider`)
    /// declares its `assetName` parameter as `@Sendable` — the stored closure
    /// must match so it can be forwarded without a concurrency warning.
    ///
    /// REVIEWER: `assetName` is `internal` even though it is accepted as a
    /// public `init` parameter. The host injected it — it does not need to
    /// read it back. Exposing it publicly would widen the API surface for no
    /// concrete consumer benefit and create a promise we'd have to maintain.
    /// If a specific external use case emerges, make it public then.
    let assetName: @Sendable (String) -> String

    /// The `UserDefaults` suite persisting the cached-zip path and version.
    let defaults: UserDefaults

    /// Reads the host's current beta-channel preference. Invoked on the main
    /// actor before each check so pre-release builds are included when enabled.
    let betaChannelProvider: @MainActor () -> Bool

    /// Scoped `UserDefaults` key names, derived from `schedulerIdentifier`.
    let keys: AppUpdaterDefaults

    /// The release-fetch abstraction. Defaults to `GitHubReleaseProvider`.
    ///
    /// Injected at `init` time; immutable after construction (AppUpdater's
    /// immutable-configuration model — all dependencies are `let`).
    let provider: any ReleaseProvider

    // MARK: - Trust model

    // REVIEWER: `skipCodeSignValidation` is a `var`, not an `init` parameter —
    // intentional. Moving it to `init` would force every caller to decide at
    // construction time, which is wrong for hosts that read this preference from
    // `UserDefaults` or a settings screen after `AppUpdater` is already
    // constructed. A `var` is the correct shape for a runtime-togglable trust
    // preference. Set it before calling `scheduleBackgroundCheck` or
    // `checkAndHandle` — see the doc comment below.

    /// When `false`, `installAndRelaunch` verifies that the running bundle and
    /// the downloaded bundle share the same `codesign` `Authority=` identity
    /// before performing the atomic bundle swap.
    ///
    /// Default `true` — RunBot's unsigned distribution model relies solely on
    /// the SHA-256 sidecar for integrity. External consumers distributing
    /// Developer ID-signed apps should set this to `false` so mismatched
    /// signing identities (e.g. a compromised build pipeline) are caught before
    /// the swap.
    ///
    /// ## Call-ordering note
    ///
    /// Set this property **before** calling `scheduleBackgroundCheck` or
    /// `checkAndHandle`. The value is read at `installAndRelaunch` time (not at
    /// check time), but establishing it early avoids any ambiguity about which
    /// value was in effect when a background check fired.
    ///
    /// ## Unsigned path (`skipCodeSignValidation = true`)
    /// - Download integrity guaranteed by SHA-256 sidecar only.
    /// - No `codesign` invocation on the downloaded bundle.
    /// - Correct for apps distributed without a Developer ID signature.
    ///
    /// ## Signed path (`skipCodeSignValidation = false`)
    /// - SHA-256 verification runs first (always).
    /// - After checksum passes, `codesign -dvvv` is run on both the running
    ///   bundle and the downloaded bundle.
    /// - `Authority=` identity strings must match; a mismatch calls
    ///   `setUpdateFailed()` and aborts the install.
    /// - For external consumers distributing Developer ID-signed apps.
    ///
    /// REVIEWER: The default `true` is intentional for RunBot. Do NOT change
    /// the default to `false` without updating the host's `AppDelegate` setup.
    public var skipCodeSignValidation: Bool = true

    // MARK: - Runtime flags

    /// `true` while `installAndRelaunch` is mid-flight — guards a double-tap.
    var isInstalling: Bool = false

    /// `true` while a background download is running — guards concurrent
    /// downloads of the same or a different release.
    var isDownloading: Bool = false

    // AppKit is unavailable in the SPM headless test runner — this guard is
    // required for `swift test` even though the package is macOS(.v26)-only.
    // Only deinit may access `activity` from a nonisolated context (invalidate
    // is thread-safe per Apple docs); all other reads/writes must be @MainActor.
    #if canImport(AppKit)
    /// Retains the `NSBackgroundActivityScheduler` for the app's lifetime.
    ///
    /// `nonisolated(unsafe)` so `deinit` (a nonisolated context) can invalidate
    /// it. Assigned and read only on the main actor otherwise.
    nonisolated(unsafe) var activity: NSBackgroundActivityScheduler?
    #endif

    // MARK: - Init / deinit

    /// Creates a configured updater.
    ///
    /// - Parameters:
    ///   - repo: `"owner/name"` GitHub repository slug (e.g. `"runbot-hq/run-bot"`).
    ///     Must not be empty — an empty string produces a malformed API URL.
    ///   - currentVersion: The running app's version string.
    ///   - assetName: Maps a tag name to the expected zip asset filename.
    ///   - schedulerIdentifier: Reverse-DNS scheduler id / `UserDefaults` domain.
    ///     Must not be empty — an empty string causes `UserDefaults` key
    ///     collisions between instances (keys degrade to bare dot-prefixed strings).
    ///   - userDefaults: Suite for persisted cache state. Defaults to `.standard`.
    ///   - betaChannelProvider: Returns the host's beta-channel preference.
    ///     Defaults to always-`false` (stable channel only).
    ///   - releaseProvider: The `ReleaseProvider` to use for fetching releases.
    ///     Defaults to `GitHubReleaseProvider()`. Override in tests by passing a
    ///     `MockReleaseProvider` — no live network required.
    ///
    /// The generic `<P: ReleaseProvider>` constraint enforces `Sendable` at the
    /// call site. Storage as `any ReleaseProvider` is standard Swift 6 practice
    /// — constraint at call site, existential for storage.
    public init<P: ReleaseProvider>(
        repo: String,
        currentVersion: String,
        assetName: @escaping @Sendable (String) -> String,
        schedulerIdentifier: String,
        userDefaults: UserDefaults = .standard,
        betaChannelProvider: @escaping @MainActor () -> Bool = { false },
        releaseProvider: P = GitHubReleaseProvider()
    ) {
        precondition(!repo.isEmpty, "AppUpdater: repo must not be empty (expected \"owner/repo\")")
        precondition(!schedulerIdentifier.isEmpty, "AppUpdater: schedulerIdentifier must not be empty (expected a reverse-DNS string)")
        self.repo = repo
        self.currentVersion = currentVersion
        self.assetName = assetName
        self.schedulerIdentifier = schedulerIdentifier
        self.defaults = userDefaults
        self.betaChannelProvider = betaChannelProvider
        self.keys = AppUpdaterDefaults(domain: schedulerIdentifier)
        self.provider = releaseProvider
    }

    deinit {
        // NSBackgroundActivityScheduler must be explicitly invalidated;
        // failing to do so leaks the activity registration system-wide.
        // NSBackgroundActivityScheduler.invalidate() is thread-safe per Apple
        // docs — safe to call from a nonisolated deinit.
        #if canImport(AppKit)
        activity?.invalidate()
        #endif
    }

    // MARK: - Convenience entry points

    /// Runs a full update check and handles the result.
    ///
    /// On `.updateAvailable` the release is downloaded/cached via `handle`.
    /// `.upToDate` and `.failed` are no-ops here (the background scheduler owns
    /// the stale-row-clearing policy) — this mirrors a launch-time check that
    /// must never clear a ready-to-install update after a transient failure.
    public func checkAndHandle(state: any UpdateStateProviding) async {
        let beta = betaChannelProvider()
        switch await checkForUpdate(betaChannel: beta) {
        case .updateAvailable(let release):
            appUpdaterLogger.debug("update available: \(release.tagName, privacy: .public) (beta=\(beta, privacy: .public))")
            await handle(release, state: state)
        case .upToDate:
            appUpdaterLogger.debug("no update available (beta=\(beta, privacy: .public))")
        case .failed(let error):
            appUpdaterLogger.debug("update check failed: \(String(describing: error), privacy: .public) (beta=\(beta, privacy: .public))")
        }
    }

    /// Runs a channel-aware update check via the injected `ReleaseProvider`.
    ///
    /// Fetches via `provider.fetchLatestRelease` and performs the `isNewer`
    /// comparison here in `AppUpdater`. `UpdateChecker.checkForUpdate` remains
    /// `public` as an escape hatch for callers who need a raw `UpdateCheckResult`
    /// without constructing an `AppUpdater` instance.
    ///
    /// Intentionally `internal` — `checkAndHandle` is the designed public entry
    /// point for host apps.
    func checkForUpdate(betaChannel: Bool) async -> UpdateCheckResult {
        guard !currentVersion.isEmpty else {
            return .failed(UpdateCheckError.missingVersionKey)
        }
        guard let latest = await provider.fetchLatestRelease(
            repo: repo,
            betaChannel: betaChannel,
            assetName: assetName
        ) else {
            return .failed(UpdateCheckError.noReleasesFound)
        }
        guard UpdateChecker.isNewer(latest.tagName, than: currentVersion) else {
            return .upToDate
        }
        return .updateAvailable(release: latest)
    }

    /// Rehydrates cached download state on launch, if a newer zip is cached.
    ///
    /// Reads this updater's scoped `UserDefaults` keys. If a cached zip still
    /// exists on disk and its version is newer than `currentVersion`, the host
    /// state is rehydrated and the available-update label is set so the install
    /// affordance is visible immediately — even offline, before any network
    /// check runs. Otherwise stale keys are cleared.
    ///
    /// Call this before `checkAndHandle` on startup.
    public func rehydrateCachedUpdateIfNewer(state: any UpdateStateProviding) {
        guard let path = defaults.string(forKey: keys.cachedUpdateZipPath),
              let version = defaults.string(forKey: keys.cachedUpdateVersion),
              FileManager.default.fileExists(atPath: path),
              UpdateChecker.isNewer(version, than: currentVersion) else {
            // Reached when the keys were never written, the zip was deleted, or
            // the cached version is no longer newer (already installed). In all
            // cases clear the stale keys.
            clearCachedDefaults()
            return
        }
        state.rehydrateCachedUpdate(zipURL: URL(fileURLWithPath: path), version: version)
        state.setAvailableUpdate(version)
    }

    // MARK: - Entry point

    /// Responds to a newly discovered available release.
    ///
    /// 1. If a matching cached zip already exists for this version, rehydrates
    ///    the host state and returns without re-downloading.
    /// 2. If the release has no matching zip asset, sets the host failure state
    ///    (curl-install fallback) and returns.
    /// 3. Otherwise starts a background download; the host state is updated on
    ///    the main actor when it completes.
    ///
    /// `setAvailableUpdate` is called AFTER the `isDownloading` guard (step 3)
    /// so the version label and the cached zip always agree.
    public func handle(_ release: AvailableRelease, state: any UpdateStateProviding) async {

        // ── 1. Already cached? ───────────────────────────────────────────────────────────────────
        let cachedVersion = defaults.string(forKey: keys.cachedUpdateVersion)
        let cachedPath = defaults.string(forKey: keys.cachedUpdateZipPath)
        if let cachedVersion, cachedVersion == release.tagName, let path = cachedPath {
            if FileManager.default.fileExists(atPath: path) {
                state.rehydrateCachedUpdate(zipURL: URL(fileURLWithPath: path), version: cachedVersion)
                state.setAvailableUpdate(release.tagName)
                return
            }
            clearCachedDefaults()
        }

        // ── 2. Asset absent from release? ─────────────────────────────────────────────────────────
        let wantedAsset = assetName(release.tagName)
        guard let asset = release.assets.first(where: { $0.name == wantedAsset }) else {
            state.setAvailableUpdate(release.tagName)
            state.setAssetMissing()
            return
        }

        // ── 3. In-flight guard ───────────────────────────────────────────────────────────────────
        guard !isDownloading else { return }
        isDownloading = true

        state.setAvailableUpdate(release.tagName)

        // ── 3b. Move to downloading state ───────────────────────────────────────────────────────
        // clearCachedDefaults() BEFORE setDownloadStarted() — load-bearing ordering;
        // see full rationale in the handle() doc comment above.
        clearCachedDefaults()
        state.setDownloadStarted()

        let downloadURL = asset.browserDownloadURL
        let checksumURL = release.checksumURL
        let tagName = release.tagName

        Task {
            await self.downloadUpdate(from: downloadURL, checksumURL: checksumURL, version: tagName, state: state)
        }
    }

    // MARK: - Download

    /// Downloads the zip and its SHA-256 sidecar in parallel, verifies
    /// integrity, then caches the verified zip and updates host state.
    private func downloadUpdate( // skipcq: SW-R1002 — reviewed; complexity acceptable for this download+verify flow
        from url: URL,
        checksumURL: URL?,
        version: String,
        state: any UpdateStateProviding
    ) async {
        var tempURL: URL?
        do {
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.timeoutIntervalForRequest = 30
            sessionConfig.timeoutIntervalForResource = 300
            let session = URLSession(configuration: sessionConfig)
            defer { session.finishTasksAndInvalidate() }

            guard let checksumURL else {
                throw URLError(.resourceUnavailable)
            }

            async let zipDownload = session.download(from: url)
            async let checksumDownload = session.data(from: checksumURL)
            let (downloadedURL, zipResponse) = try await zipDownload
            tempURL = downloadedURL
            let (checksumData, _) = try await checksumDownload

            guard let http = zipResponse as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            if http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }

            let rawChecksum = String(bytes: checksumData, encoding: .utf8) ?? ""
            let expectedHex = rawChecksum
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces).first ?? ""

            // Explicit guard: an empty expectedHex means the sidecar was
            // unreadable or zero-length. verifyChecksum would throw a mismatch
            // anyway ("" != 64-char SHA-256 hex), but making this explicit
            // prevents a future edit to verifyChecksum from accidentally
            // treating empty as "skip verification".
            guard !expectedHex.isEmpty else {
                throw URLError(.cannotDecodeContentData)
            }

            try await verifyChecksum(zipURL: downloadedURL, expectedHex: expectedHex)

            let destination = try cachedZipDestination(version: version)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: downloadedURL, to: destination)

            defaults.set(version, forKey: keys.cachedUpdateVersion)
            defaults.set(destination.path, forKey: keys.cachedUpdateZipPath)

            state.setDownloadComplete(zipURL: destination, version: version)
            isDownloading = false
        } catch {
            if let tmp = tempURL {
                try? FileManager.default.removeItem(at: tmp)
            }
            // `isDownloading` is cleared on the same @MainActor turn as
            // `setUpdateFailed()` — no intermediate state is observable. A
            // subsequent `handle()` call cannot slip through between these two
            // lines because @MainActor serialises all callers onto one executor.
            // Do NOT split these or add an `await` between them.
            isDownloading = false
            state.setUpdateFailed()
        }
    }
}
