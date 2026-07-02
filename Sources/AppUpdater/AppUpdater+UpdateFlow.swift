// AppUpdater+UpdateFlow.swift
// AppUpdater
import Foundation

// MARK: - Update flow entry points

/// Update-flow entry points: check, rehydrate, and handle available releases.
extension AppUpdater {

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
    /// ## Stale zip purge
    ///
    /// `purgeStaleZips(keeping:)` is called unconditionally at the top of this
    /// function, before the guard, so orphaned zips from the previous session
    /// are swept regardless of whether rehydration succeeds or fails. The
    /// `keepURL` is derived from `UserDefaults` before the guard block so the
    /// live zip (if any) is never deleted even when rehydration returns early.
    ///
    /// REVIEWER: Do NOT move the `purgeStaleZips` call inside the guard's
    /// success branch. The orphans this sweep targets — specifically the open-n
    /// failure path where UserDefaults are cleared before the zip is deleted —
    /// are present precisely when the guard fails (no valid path in UserDefaults).
    /// Moving it inside the success branch would silently miss every orphan.
    ///
    /// Call this before `checkAndHandle` on startup.
    public func rehydrateCachedUpdateIfNewer(state: any UpdateStateProviding) {
        // Derive the live zip URL from UserDefaults before the guard so
        // purgeStaleZips knows which file to preserve regardless of which
        // branch is taken below.
        let liveZipURL = defaults.string(forKey: keys.cachedUpdateZipPath)
            .map { URL(fileURLWithPath: $0) }

        // Purge stale zips unconditionally. Covers:
        // - Normal install cycles (prior version's zip left on disk)
        // - open -n failure path (UserDefaults cleared, zip orphaned)
        // - Any future edge case leaving zips without a UserDefaults pointer
        // The live zip (liveZipURL) is preserved if present.
        purgeStaleZips(keeping: liveZipURL)

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
        // the `downloadUpdate` doc comment in AppUpdater+Download.swift. Summary:
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
}
