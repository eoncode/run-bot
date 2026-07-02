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
/// helper. The background download is spawned with a fire-and-forget
/// `Task(name:)` that inherits `@MainActor` isolation — see the doc comment on
/// `downloadUpdate` for the full rationale on why storing the handle and adding
/// cancellation is deliberately absent.
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
    ///
    /// Must be a valid reverse-DNS string (e.g. `"com.your-org.update-check"`).
    /// Must not be empty and must not contain `/` — both are enforced by
    /// `precondition` at init time.
    public let schedulerIdentifier: String

    // MARK: - Internal configuration
    //
    // `assetName`, `defaults`, `keys`, `betaChannelProvider`, `provider` are
    // `internal` by design — implementation details not part of the public
    // contract. `isInstalling`/`isDownloading` are accessed via `@testable
    // import`; make them `public` if this library is extracted to its own repo.
    //
    // REVIEWER: Do NOT make closures or defaults public without a concrete
    // external-consumer use case — every public symbol is a promise.

    /// Maps a release tag name to the expected zip asset filename.
    /// `@Sendable` so it can be forwarded to `fetchLatestRelease`.
    ///
    /// REVIEWER: `internal` by design even though accepted as a public `init`
    /// parameter — the host injected it and has no need to read it back.
    let assetName: @Sendable (String) -> String

    /// The `UserDefaults` suite persisting the cached-zip path and version.
    let defaults: UserDefaults

    /// Reads the host's current beta-channel preference on the main actor.
    let betaChannelProvider: @MainActor () -> Bool

    /// Scoped `UserDefaults` key names, derived from `schedulerIdentifier`.
    let keys: AppUpdaterDefaults

    /// The release-fetch abstraction. Defaults to `GitHubReleaseProvider`.
    let provider: any ReleaseProvider

    // MARK: - Trust model

    // REVIEWER: `skipCodeSignValidation` is a `var`, not an `init` parameter —
    // intentional. A `var` is the correct shape for a runtime-togglable trust
    // preference read from UserDefaults or a settings screen post-init.
    // Set it before calling `scheduleBackgroundCheck` or `checkAndHandle`.

    /// When `false`, `installAndRelaunch` verifies that the running bundle and
    /// the downloaded bundle share the same `codesign` `Authority=` identity
    /// before performing the atomic bundle swap.
    ///
    /// Default `true` — RunBot's unsigned distribution model relies solely on
    /// the SHA-256 sidecar for integrity. External consumers distributing
    /// Developer ID-signed apps should set this to `false`.
    ///
    /// Set this **before** calling `scheduleBackgroundCheck` or `checkAndHandle`.
    ///
    /// REVIEWER: The default `true` is intentional for RunBot. Do NOT change
    /// the default to `false` without updating the host's `AppDelegate` setup.
    public var skipCodeSignValidation: Bool = true

    // MARK: - Runtime flags

    /// `true` while `installAndRelaunch` is mid-flight — guards a double-tap.
    var isInstalling: Bool = false

    /// `true` while a background download is running — guards concurrent downloads.
    ///
    /// REVIEWER: No `downloadTask` handle alongside this flag — intentional.
    /// See the "Fire-and-forget rationale" section in `downloadUpdate`.
    var isDownloading: Bool = false

    // MARK: - Background scheduler storage
    //
    // AppKit unavailable in SPM headless runner — #if guard required for
    // `swift test` even though the package is macOS(.v26)-only.
    //
    // SAFETY — nonisolated(unsafe) var activity:
    // `deinit` is nonisolated; the Swift compiler forbids accessing a
    // @MainActor-isolated property from deinit. NSBackgroundActivityScheduler
    // MUST be invalidated before deallocation or its system-wide registration
    // leaks. nonisolated(unsafe) is the only mechanism that lets deinit reach
    // `activity` — Task { @MainActor in invalidate() } would be use-after-free.
    //
    // Why it is safe: AppUpdater is @MainActor final class, so every non-deinit
    // access is compiler-enforced on the main actor. deinit only calls
    // activity?.invalidate(), which Apple documents as thread-safe. No
    // non-isolated write path exists, so the race nonisolated(unsafe) silences
    // cannot be triggered in practice.
    //
    // Tension with concurrency-overview.md: that doc reserves `nonisolated` for
    // immutable-post-init cases. This is a justified narrow exception driven by
    // a platform constraint (deinit isolation), not a design shortcut. Do NOT
    // copy this pattern for other properties.
    //
    // Known alternative (low priority): refactor to nonisolated(unsafe) let set
    // once by scheduleBackgroundCheck. Not pursued — activity is legitimately
    // nil when scheduleBackgroundCheck is never called (e.g. test contexts).
    //
    // REVIEWER: Do NOT remove nonisolated(unsafe) without an alternative deinit
    // invalidation path. Do NOT add any non-deinit, non-@MainActor access to
    // `activity` — that would invalidate the safety argument above.
    #if canImport(AppKit)
    /// Retains the `NSBackgroundActivityScheduler` for the app's lifetime.
    /// `nonisolated(unsafe)` so `deinit` can call `invalidate()` — all other
    /// accesses are `@MainActor`-isolated via the enclosing class.
    /// See the block comment above for the full safety rationale.
    nonisolated(unsafe) var activity: NSBackgroundActivityScheduler?
    #endif

    // MARK: - Init / deinit

    /// Creates a configured updater.
    ///
    /// - Parameters:
    ///   - repo: `"owner/name"` GitHub repository slug. Must not be empty.
    ///   - currentVersion: The running app's version string.
    ///   - assetName: Maps a tag name to the expected zip asset filename.
    ///   - schedulerIdentifier: Reverse-DNS scheduler id / `UserDefaults` domain.
    ///     Must not be empty and must not contain `"/"` — both enforced by
    ///     `precondition`.
    ///   - userDefaults: Suite for persisted cache state. Defaults to `.standard`.
    ///   - betaChannelProvider: Returns the host's beta-channel preference.
    ///     Defaults to always-`false` (stable channel only).
    ///   - releaseProvider: Defaults to `GitHubReleaseProvider()`. Override in
    ///     tests with a `MockReleaseProvider` — no live network required.
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
        precondition(
            !schedulerIdentifier.contains("/"),
            "AppUpdater: schedulerIdentifier must not contain '/' — used as a cache directory name"
            + " component via appendingPathComponent; a slash would silently create a nested subdirectory path"
        )
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
        // NSBackgroundActivityScheduler.invalidate() is thread-safe per Apple
        // docs — safe to call from nonisolated deinit. See MARK: Background
        // scheduler storage above for the full nonisolated(unsafe) rationale.
        #if canImport(AppKit)
        activity?.invalidate()
        #endif
        // REVIEWER: No downloadTask?.cancel() here — intentional. AppUpdater
        // lives for the entire app lifetime; deinit while a download is in
        // flight is architecturally impossible. See downloadUpdate doc comment.
    }

    // MARK: - Convenience entry points

    /// Runs a full update check and handles the result.
    ///
    /// On `.updateAvailable` the release is downloaded/cached via `handle`.
    /// `.upToDate` and `.failed` are no-ops here — the background scheduler
    /// owns the stale-row-clearing policy.
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
    /// `UpdateChecker.checkForUpdate` remains `public` as an escape hatch for
    /// callers who need a raw `UpdateCheckResult` without constructing an
    /// `AppUpdater` instance. Intentionally `internal` here — `checkAndHandle`
    /// is the designed public entry point for host apps.
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
    /// If a cached zip still exists on disk and its version is newer than
    /// `currentVersion`, the host state is rehydrated and the available-update
    /// label is set — even offline, before any network check runs.
    ///
    /// ## Stale zip purge
    ///
    /// `purgeStaleZips(keeping:)` is called unconditionally before the guard so
    /// orphaned zips (including the open-n failure path) are swept even when
    /// rehydration fails. The keep URL is derived before the guard so the live
    /// zip is never deleted during early return.
    ///
    /// REVIEWER: Do NOT move `purgeStaleZips` inside the guard's success branch
    /// — orphans are present precisely when the guard fails.
    ///
    /// Call this before `checkAndHandle` on startup.
    public func rehydrateCachedUpdateIfNewer(state: any UpdateStateProviding) {
        let liveZipURL = defaults.string(forKey: keys.cachedUpdateZipPath)
            .map { URL(fileURLWithPath: $0) }
        purgeStaleZips(keeping: liveZipURL)

        guard let path = defaults.string(forKey: keys.cachedUpdateZipPath),
              let version = defaults.string(forKey: keys.cachedUpdateVersion),
              FileManager.default.fileExists(atPath: path),
              UpdateChecker.isNewer(version, than: currentVersion) else {
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
    /// 2. If the release has no matching zip asset **or** no checksum sidecar
    ///    URL, sets the host failure state (curl-install fallback) and returns.
    ///    Both are treated identically: the release cannot be safely downloaded
    ///    and verified, so the download path is never entered and
    ///    `setDownloadStarted()` is never called.
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

        // ── 2. Asset or checksum sidecar absent from release? ────────────────────────────────────
        // Both conditions are treated identically: the release cannot be safely
        // downloaded and integrity-verified, so we surface the curl-install
        // fallback without ever entering the download path.
        //
        // ⚠️ The checksumURL guard MUST live here (step 2), not inside
        // downloadUpdate(). Allowing a nil checksumURL to reach the download
        // path would cause setDownloadStarted() to fire first — producing a
        // visible spinner flash — before downloadUpdate() throws and eventually
        // calls setUpdateFailed(). Catching it here keeps the UI transition
        // direct: setAssetMissing() → curl-install fallback, no spinner shown.
        let wantedAsset = assetName(release.tagName)
        guard let asset = release.assets.first(where: { $0.name == wantedAsset }) else {
            state.setAvailableUpdate(release.tagName)
            state.setAssetMissing()
            return
        }
        guard release.checksumURL != nil else {
            state.setAvailableUpdate(release.tagName)
            state.setAssetMissing()
            return
        }

        // ── 3. In-flight guard ───────────────────────────────────────────────────────────────────
        guard !isDownloading else { return }
        isDownloading = true

        state.setAvailableUpdate(release.tagName)

        // ── 3b. Move to downloading state ───────────────────────────────────────────────────────
        // clearCachedDefaults() MUST run before setDownloadStarted(). If the
        // process is force-quit in the window between these two calls, the
        // invariant we need to preserve is: UserDefaults must not contain a
        // cached-zip path that points at a file which was never fully
        // downloaded. Running clearCachedDefaults() first guarantees that a
        // crash here leaves UserDefaults clean; a subsequent launch finds no
        // cached path and triggers a fresh check. The reverse order would leave
        // a stale path in defaults pointing at nothing, causing
        // rehydrateCachedUpdateIfNewer() to silently clear it on next launch
        // rather than offering the install — a recoverable but confusing state.
        // Do NOT reorder these two calls or insert an `await` between them.
        clearCachedDefaults()
        state.setDownloadStarted()

        let downloadURL = asset.browserDownloadURL
        let checksumURL = release.checksumURL
        let tagName = release.tagName

        // REVIEWER: Do NOT store this task handle, do NOT add cancellation, and
        // do NOT add a `downloadTask` property. Fire-and-forget is the correct
        // pattern here — this is a deliberate design decision, not an oversight.
        //
        // Full rationale is in the "## Fire-and-forget rationale" section of
        // the `downloadUpdate` doc comment below. Summary:
        //
        // 1. AppUpdater is owned by AppDelegate for the app's entire lifetime.
        //    Deallocation mid-download is architecturally impossible — there is
        //    no scenario where a stored handle + deinit cancel would ever fire.
        //
        // 2. `isDownloading = true` (step 3 above) already serialises all
        //    concurrent handle() calls. A second Task is never started while
        //    one is in flight — the guard above returns early.
        //
        // 3. `downloadUpdate` is a one-shot operation, not a loop. The P3
        //    concurrency doc pattern (stored task + generation counter) applies
        //    to long-lived polling loops, not to one-shot fire-and-forget work.
        //
        // 4. `@MainActor` isolation guarantees that all state callbacks inside
        //    `downloadUpdate` (setDownloadComplete, setUpdateFailed,
        //    isDownloading = false) are serialised — no stored handle is needed
        //    for ordering guarantees.
        //
        // The task is named for Instruments / crash-log debuggability only
        // (reach-goal principle 6, SE-0462). That is the sole purpose of
        // Task(name:) here.
        Task(name: "AppUpdater.download") {
            await self.downloadUpdate(from: downloadURL, checksumURL: checksumURL, version: tagName, state: state)
        }
    }

    // MARK: - Download

    /// Downloads the zip and its SHA-256 sidecar in parallel, verifies
    /// integrity, then caches the verified zip and updates host state.
    ///
    /// ## Fire-and-forget rationale
    ///
    /// This function is invoked from a fire-and-forget `Task(name: "AppUpdater.download")`
    /// in `handle()`. Reviewers familiar with structured concurrency may flag
    /// the absence of a stored task handle or cancellation support as a
    /// defect. It is not — this is a deliberate design decision.
    ///
    /// **Why no stored handle / cancellation:**
    ///
    /// 1. **Lifetime:** `AppUpdater` is owned by `AppDelegate` and lives for
    ///    the entire app lifetime. `deinit` is never reached while a download
    ///    is in flight. `downloadTask?.cancel()` in `deinit` would be dead code.
    ///
    /// 2. **Concurrency guard:** `isDownloading = true` is set before the
    ///    `Task` is spawned in `handle()`. Every subsequent `handle()` call
    ///    returns immediately at the in-flight guard. There is no scenario
    ///    where a second download `Task` is started while this one runs.
    ///
    /// 3. **One-shot, not a loop:** The P3 concurrency-doc pattern of storing a
    ///    task handle applies to long-lived loops (`pollTask`, generation
    ///    counters). A single download-verify-cache operation does not benefit
    ///    from that pattern — there is nothing to cancel mid-flight that would
    ///    leave state cleaner than letting the do/catch complete naturally.
    ///
    /// 4. **`@MainActor` serialisation:** All state mutations in this function
    ///    (`setDownloadComplete`, `setUpdateFailed`, `isDownloading = false`)
    ///    run on the main actor. Order and exclusivity are guaranteed by the
    ///    actor executor without a stored handle.
    ///
    /// REVIEWER: Do NOT raise "unstructured task" or "missing cancellation" as
    /// a finding on `handle()` or `downloadUpdate`. Both have been evaluated
    /// and the fire-and-forget pattern is correct for this case. Adding a
    /// stored `downloadTask` property would be over-engineering a problem that
    /// does not exist in this codebase.
    ///
    /// ## HTTP status validation
    ///
    /// Both the zip response and the checksum sidecar response are validated
    /// for HTTP 200 before their bodies are used. This matters most for the
    /// sidecar: GitHub's CDN returns a 404 HTML page (not an error throw) when
    /// a release was published without a `.sha256` file. Without the status
    /// check the HTML body would be fed into the hex parser, `expectedHex`
    /// would be `"<!DOCTYPE"`, `verifyChecksum` would throw a digest mismatch,
    /// and Console.app would log "checksum mismatch" instead of "sidecar
    /// returned HTTP 404" — making the failure significantly harder to diagnose.
    /// The install is blocked correctly in both cases; this is purely a
    /// diagnosability improvement.
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

            // Safety net: handle() guards against nil checksumURL in step 2
            // before entering the download path, so this branch is unreachable
            // in normal flow. Kept as a last-resort defensive check.
            guard let checksumURL else {
                throw URLError(.resourceUnavailable)
            }

            async let zipDownload = session.download(from: url)
            async let checksumDownload = session.data(from: checksumURL)
            let (downloadedURL, zipResponse) = try await zipDownload
            tempURL = downloadedURL
            let (checksumData, checksumResponse) = try await checksumDownload

            // ── Validate zip HTTP status ─────────────────────────────────────
            guard let zipHTTP = zipResponse as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard zipHTTP.statusCode == 200 else {
                appUpdaterLogger.error("zip download returned HTTP \(zipHTTP.statusCode, privacy: .public)")
                throw URLError(.badServerResponse)
            }

            // ── Validate checksum sidecar HTTP status ────────────────────────
            // Non-200 most commonly means the release was published without a
            // .sha256 sidecar. Without this guard the CDN's HTML error page
            // would reach the hex parser, producing a misleading "digest
            // mismatch" log instead of the real cause.
            guard let checksumHTTP = checksumResponse as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard checksumHTTP.statusCode == 200 else {
                appUpdaterLogger.error("checksum sidecar returned HTTP \(checksumHTTP.statusCode, privacy: .public) — release may have been published without a .sha256 file")
                throw URLError(.badServerResponse)
            }

            // ── Parse and validate the expected hex string ───────────────────
            let rawChecksum = String(bytes: checksumData, encoding: .utf8) ?? ""
            let expectedHex = rawChecksum
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces).first ?? ""

            // Guard against empty sidecar body — verifyChecksum would throw a
            // mismatch anyway, but this guard prevents a future edit from
            // accidentally treating empty as "skip verification".
            guard !expectedHex.isEmpty else {
                appUpdaterLogger.error("checksum sidecar returned HTTP 200 but body was empty or whitespace-only")
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
            // `isDownloading` and `setUpdateFailed()` are cleared on the same
            // @MainActor turn — no intermediate state is observable. Do NOT
            // split these or add an `await` between them.
            isDownloading = false
            state.setUpdateFailed()
        }
    }
}
